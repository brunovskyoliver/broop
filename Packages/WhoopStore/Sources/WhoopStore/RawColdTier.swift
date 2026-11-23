import Foundation
import GRDB

/// The cold tier of the seven dense per-second streams.
///
/// The row tables (`hrSample`, ...) stay the hot tier and their writers are unchanged. Hours that closed
/// more than `sealAgeSeconds` ago are packed into one `rawChunk` row per (stream, device, hour) by the seal
/// pass in `runStorageMaintenance`. An hour is either all hot or all cold at every commit: a BEFORE INSERT /
/// UPDATE trigger on each hot table refuses a row for a sealed hour, and every writer first moves the
/// hours it touches back to the hot table (`unseal`). So the union of the two never holds a key twice.
///
/// Readers see the union through `RawStream.union`, which joins the hot table to an eponymous virtual
/// table (`hrSampleCold`, ...) that decodes chunks on demand. That table must be registered on every
/// connection (`RawColdTier.register`, run from `prepareDatabase`); a connection without it fails loudly
/// with "no such table", never silently with fewer rows.
public enum RawColdTier {
    /// Hours that ended at least this long ago are sealed. Live data and the latest offload land in rows.
    public static let sealAgeSeconds = 6 * 3600
    /// Hours sealed per transaction, so a first pass over a large store never holds one huge transaction.
    static let hoursPerTransaction = 24
    /// Without a charger, a pass seals at most this many hours per stream, so the first pass on an existing
    /// store is spread over several days instead of keeping writers waiting at launch.
    static let hoursPerPassWithoutCharger = 48
}

extension RawStream {
    /// The eponymous virtual table holding this stream's sealed rows.
    public var coldTable: String { table + "Cold" }

    var allColumns: [String] { ["deviceId", "ts"] + columns.map(\.name) }

    /// Hot rows and sealed rows as one table, with the hot table's columns. Use in place of the table name.
    public var union: String {
        let cols = allColumns.joined(separator: ", ")
        return "(SELECT \(cols) FROM \(table) UNION ALL SELECT \(cols) FROM \(coldTable))"
    }

    /// Sealed row count as a scalar SQL expression; cheaper than counting through `union`.
    var coldCount: String { "(SELECT COALESCE(SUM(n), 0) FROM rawChunk WHERE stream = \(rawValue))" }

    /// `COUNT(*)` over every row, hot and sealed.
    var totalCount: String { "((SELECT COUNT(*) FROM \(table)) + \(coldCount))" }

    /// `MAX(ts)` over every row, hot and sealed; NULL when there are none.
    func maxTs(deviceFilter: String = "") -> String {
        let hot = deviceFilter.isEmpty ? "" : "WHERE deviceId = \(deviceFilter)"
        let cold = deviceFilter.isEmpty ? "" : "AND deviceId = \(deviceFilter)"
        return """
            (SELECT MAX(m) FROM (SELECT (SELECT MAX(ts) FROM \(table) \(hot)) AS m
             UNION ALL SELECT (SELECT MAX(maxTs) FROM rawChunk WHERE stream = \(rawValue) \(cold))))
            """
    }

    /// The sealed part of [from, to] (inclusive) split into whole hours, which `rawChunk` answers without
    /// decoding, and at most two edge ranges inside partly covered hours, which the cold table decodes.
    /// Chunks hold only ts >= 0, so the split starts at 0.
    private func coldSplit(from: Int, to: Int) -> (hours: String, edges: [(Int, Int)]) {
        let lo = max(from, 0), hi = min(to, Int.max - 7200)
        guard lo <= hi else { return ("0", []) }
        let firstFull = (lo + 3599) / 3600 * 3600
        let lastFull = (hi + 1) / 3600 * 3600 - 3600  // start of the last hour that ends inside the window
        guard firstFull <= lastFull else { return ("0", [(lo, hi)]) }
        var edges: [(Int, Int)] = []
        if lo < firstFull { edges.append((lo, firstFull - 1)) }
        if hi >= lastFull + 3600 { edges.append((lastFull + 3600, hi)) }
        return ("hourStart >= \(firstFull) AND hourStart <= \(lastFull)", edges)
    }

    /// `COUNT(*)` and `MAX(ts)` (NULL when empty) of one device's rows with ts in [from, to], hot and sealed,
    /// as scalar SQL. `device` is a placeholder or literal for the device id. Same answers as the union.
    func windowCountMax(device: String, from: Int, to: Int) -> (count: String, max: String) {
        let hot = "FROM \(table) WHERE deviceId = \(device) AND ts >= \(from) AND ts <= \(to)"
        let (hours, edges) = coldSplit(from: from, to: to)
        let chunks = "FROM rawChunk WHERE stream = \(rawValue) AND deviceId = \(device) AND \(hours)"
        let edge = edges.map { "FROM \(coldTable) WHERE deviceId = \(device) AND ts >= \($0.0) AND ts <= \($0.1)" }
        let count = (["(SELECT COUNT(*) \(hot))", "(SELECT COALESCE(SUM(n), 0) \(chunks))"]
            + edge.map { "(SELECT COUNT(*) \($0))" }).joined(separator: " + ")
        let max = (["SELECT MAX(ts) AS m \(hot)", "SELECT MAX(maxTs) \(chunks)"]
            + edge.map { "SELECT MAX(ts) \($0)" }).joined(separator: " UNION ALL ")
        return ("(\(count))", "(SELECT MAX(m) FROM (\(max)))")
    }

    /// `(deviceId, n)` rows whose per-device sum is the row count with ts in [from, to], hot and sealed.
    func windowCountsByDevice(from: Int, to: Int) -> String {
        let (hours, edges) = coldSplit(from: from, to: to)
        return ([
            "SELECT deviceId, COUNT(*) AS n FROM \(table) WHERE ts >= \(from) AND ts <= \(to) GROUP BY deviceId",
            "SELECT deviceId, SUM(n) AS n FROM rawChunk WHERE stream = \(rawValue) AND \(hours) GROUP BY deviceId",
        ] + edges.map {
            "SELECT deviceId, COUNT(*) AS n FROM \(coldTable) WHERE ts >= \($0.0) AND ts <= \($0.1) GROUP BY deviceId"
        }).joined(separator: " UNION ALL ")
    }

    fileprivate var hotInsertSQL: String {
        "INSERT INTO \(table) (\(allColumns.joined(separator: ", "))) VALUES (\(allColumns.map { _ in "?" }.joined(separator: ", ")))"
    }
}

// MARK: - Schema

extension RawColdTier {
    /// `v52-raw-chunk`. `maxTs` lets a frontier read skip decoding; `n` lets a count skip it.
    static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE rawChunk (
                stream INTEGER NOT NULL, deviceId TEXT NOT NULL, hourStart INTEGER NOT NULL,
                n INTEGER NOT NULL, maxTs INTEGER NOT NULL, data BLOB NOT NULL,
                PRIMARY KEY (stream, deviceId, hourStart)) WITHOUT ROWID
            """)
        for stream in RawStream.allCases {
            let sealed = """
                NEW.ts >= 0 AND EXISTS (SELECT 1 FROM rawChunk WHERE stream = \(stream.rawValue)
                    AND deviceId = NEW.deviceId AND hourStart = NEW.ts / 3600 * 3600)
                """
            let refuse = "BEGIN SELECT RAISE(ABORT, 'rawChunk: hour is sealed, unseal it before writing'); END"
            try db.execute(sql: "CREATE TRIGGER rawChunk_guard_\(stream.table)_INSERT BEFORE INSERT ON \(stream.table) WHEN \(sealed) \(refuse)")
            try db.execute(sql: "CREATE TRIGGER rawChunk_guard_\(stream.table)_UPDATE BEFORE UPDATE OF deviceId, ts ON \(stream.table) WHEN \(sealed) \(refuse)")
        }
    }
}

// MARK: - Seal and unseal

extension RawColdTier {
    /// Seal up to `hourBudget` closed hours of `stream`, `hoursPerTransaction` per transaction. Returns how
    /// many hours were visited (sealed or skipped). Stops between transactions when `shouldContinue` is false.
    /// `now` is unix seconds; an hour is closed once it ended `sealAgeSeconds` before it.
    static func seal(_ stream: RawStream, now: Int, hourBudget: Int, writer: any DatabaseWriter,
                     shouldContinue: () -> Bool) throws -> Int {
        let sealBefore = (now - sealAgeSeconds) / 3600 * 3600
        guard sealBefore > 0 else { return 0 }
        // Walk devices in order and each device's unsealed hours in order. A sealed hour has no hot rows,
        // so `MIN(ts)` lands on the next hour that still needs work. Negative (corrupt) timestamps stay hot.
        var lastDevice = ""
        var current: String?
        var ts = 0
        var visited = 0
        while visited < hourBudget, shouldContinue() {
            let batch: Int = try writer.write { db in
                var work: [Int] = []
                var workDevice: String?
                while work.count < min(hoursPerTransaction, hourBudget - visited) {
                    if current == nil {
                        current = try String.fetchOne(db, sql: "SELECT MIN(deviceId) FROM \(stream.table) WHERE deviceId > ?",
                                                      arguments: [lastDevice])
                        ts = 0
                        guard let c = current else { break }
                        lastDevice = c
                    }
                    guard let dev = current else { break }
                    // One transaction seals one device, so the revision snapshot is per device.
                    if let w = workDevice, w != dev { break }
                    guard let next = try Int.fetchOne(db, sql: """
                        SELECT MIN(ts) FROM \(stream.table) WHERE deviceId = ? AND ts >= ? AND ts < ?
                        """, arguments: [dev, ts, sealBefore]) else {
                        current = nil
                        continue
                    }
                    let hour = next / 3600 * 3600
                    ts = hour + 3600
                    work.append(hour)
                    workDevice = dev
                }
                guard let dev = workDevice else { return 0 }
                try preservingRevisions(db, deviceId: dev, days: Set(work.map { $0 / 86_400 })) {
                    for hour in work { try sealHour(db, stream: stream, deviceId: dev, hourStart: hour) }
                }
                return work.count
            }
            if batch == 0 { break }
            visited += batch
        }
        return visited
    }

    /// Pack one hour's hot rows into its chunk and delete them. Returns false, leaving the rows hot, when a
    /// value has a storage class the column does not declare: such a row could not come back bit-identical.
    @discardableResult
    static func sealHour(_ db: Database, stream: RawStream, deviceId: String, hourStart: Int) throws -> Bool {
        let order = (["ts"] + stream.extraKeyColumns.map { stream.columns[$0].name }).joined(separator: ", ")
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(stream.allColumns.joined(separator: ", ")) FROM \(stream.table)
            WHERE deviceId = ? AND ts >= ? AND ts < ? ORDER BY \(order)
            """, arguments: [deviceId, hourStart, hourStart + 3600])
        guard !rows.isEmpty, let chunk = chunkRows(rows, stream: stream) else { return false }
        let blob = RawChunkCodec.encode(chunk, stream: stream)
        // Lossless is the contract, so the blob is proven before any row is deleted.
        guard try RawChunkCodec.decode(blob, stream: stream) == chunk else {
            throw RawChunkCodecError.malformed("\(stream.table) \(deviceId) \(hourStart) did not round-trip")
        }
        try db.execute(sql: "DELETE FROM \(stream.table) WHERE deviceId = ? AND ts >= ? AND ts < ?",
                       arguments: [deviceId, hourStart, hourStart + 3600])
        guard db.changesCount == rows.count else {
            throw RawChunkCodecError.malformed("\(stream.table) \(deviceId) \(hourStart) changed while sealing")
        }
        try db.execute(sql: """
            INSERT INTO rawChunk (stream, deviceId, hourStart, n, maxTs, data) VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [stream.rawValue, deviceId, hourStart, chunk.count, chunk.ts.max()!, Data(blob)])
        return true
    }

    /// Column-major copy of `rows`, or nil when any value's storage class does not match its column.
    static func chunkRows(_ rows: [Row], stream: RawStream) -> RawChunkRows? {
        var ts: [Int64] = []
        ts.reserveCapacity(rows.count)
        for row in rows {
            guard case .int64(let t) = (row[1] as DatabaseValue).storage else { return nil }
            ts.append(t)
        }
        var columns: [RawColumnValues] = []
        for (index, (_, kind)) in stream.columns.enumerated() {
            if kind == .blob {
                var blobs: [[UInt8]] = []
                for row in rows {
                    guard case .blob(let d) = (row[index + 2] as DatabaseValue).storage else { return nil }
                    blobs.append([UInt8](d))
                }
                columns.append(RawColumnValues(blobs: blobs))
                continue
            }
            var values: [Int64] = []
            var nulls: [Bool] = []
            values.reserveCapacity(rows.count)
            for row in rows {
                switch ((row[index + 2] as DatabaseValue).storage, kind) {
                case (.null, .optionalInt), (.null, .optionalReal):
                    values.append(0); nulls.append(true)
                case (.int64(let v), .int), (.int64(let v), .optionalInt):
                    values.append(v); nulls.append(false)
                case (.double(let d), .real), (.double(let d), .optionalReal):
                    values.append(Int64(bitPattern: d.bitPattern)); nulls.append(false)
                default:
                    return nil
                }
            }
            columns.append(RawColumnValues(values: values, isNull: kind.isOptional ? nulls : nil))
        }
        return RawChunkRows(ts: ts, columns: columns)
    }

    /// Move sealed hours back to the hot table, so a write or a delete runs against rows exactly as before
    /// sealing. The move itself leaves `analysisRevision` as it was; the next seal pass packs them again.
    /// `deviceId` nil means every device.
    static func unseal(_ db: Database, stream: RawStream, deviceId: String?, range: ClosedRange<Int>) throws {
        var sql = "SELECT deviceId, hourStart FROM rawChunk WHERE stream = ? AND hourStart >= ? AND hourStart <= ?"
        var args: StatementArguments = [stream.rawValue, range.lowerBound, range.upperBound]
        if let deviceId { sql += " AND deviceId = ?"; args += [deviceId] }
        let keys = try Row.fetchAll(db, sql: sql, arguments: args).map { ($0[0] as String, $0[1] as Int) }
        try unseal(db, stream: stream, keys: keys)
    }

    /// Unseal exactly the hours that hold one of `timestamps` for `deviceId`.
    static func unseal(_ db: Database, stream: RawStream, deviceId: String, timestamps: [Int]) throws {
        let hours = Set(timestamps.lazy.filter { $0 >= 0 }.map { $0 / 3600 * 3600 })
        guard let lo = hours.min(), let hi = hours.max() else { return }
        let sealed = try Int.fetchAll(db, sql: """
            SELECT hourStart FROM rawChunk WHERE stream = ? AND deviceId = ? AND hourStart >= ? AND hourStart <= ?
            """, arguments: [stream.rawValue, deviceId, lo, hi])
        try unseal(db, stream: stream, keys: sealed.filter(hours.contains).map { (deviceId, $0) })
    }

    /// Every sealed hour of `deviceId`, in every stream.
    static func unsealDevice(_ db: Database, deviceId: String) throws {
        for stream in RawStream.allCases {
            try unseal(db, stream: stream, deviceId: deviceId, range: Int.min...Int.max)
        }
    }

    private static func unseal(_ db: Database, stream: RawStream, keys: [(String, Int)]) throws {
        guard !keys.isEmpty else { return }
        for (deviceId, hours) in Dictionary(grouping: keys, by: \.0) {
            try preservingRevisions(db, deviceId: deviceId, days: Set(hours.map { $0.1 / 86_400 })) {
                let insert = try db.cachedStatement(sql: stream.hotInsertSQL)
                for (_, hour) in hours {
                    guard let blob = try Data.fetchOne(db, sql: """
                        SELECT data FROM rawChunk WHERE stream = ? AND deviceId = ? AND hourStart = ?
                        """, arguments: [stream.rawValue, deviceId, hour]) else { continue }
                    let chunk = try blob.withUnsafeBytes { try RawChunkCodec.decode($0, stream: stream) }
                    // The chunk goes first: the guard trigger refuses rows for an hour that is still sealed.
                    try db.execute(sql: "DELETE FROM rawChunk WHERE stream = ? AND deviceId = ? AND hourStart = ?",
                                   arguments: [stream.rawValue, deviceId, hour])
                    for i in 0..<chunk.count {
                        var args: [DatabaseValueConvertible?] = [deviceId, chunk.ts[i]]
                        for (c, (_, kind)) in zip(chunk.columns, stream.columns) {
                            if c.isNull?[i] == true { args.append(nil); continue }
                            if let blobs = c.blobs { args.append(Data(blobs[i])); continue }
                            args.append(kind.isReal ? Double(bitPattern: UInt64(bitPattern: c.values[i])) as DatabaseValueConvertible
                                                    : c.values[i])
                        }
                        try insert.execute(arguments: StatementArguments(args))
                    }
                }
            }
        }
    }

    /// Delete the chunks matching `predicate`, counting their rows into `analysisRevision` the way the
    /// hot table's delete trigger would have counted them one by one.
    static func deleteChunks(_ db: Database, stream: RawStream, predicate: String, arguments: StatementArguments = []) throws {
        try db.execute(sql: """
            INSERT INTO analysisRevision (deviceId, day, revision)
            SELECT deviceId, hourStart / 86400, SUM(n) FROM rawChunk WHERE stream = \(stream.rawValue) AND (\(predicate))
            GROUP BY deviceId, hourStart / 86400
            ON CONFLICT(deviceId, day) DO UPDATE SET revision = revision + excluded.revision
            """, arguments: arguments)
        try db.execute(sql: "DELETE FROM rawChunk WHERE stream = \(stream.rawValue) AND (\(predicate))",
                       arguments: arguments)
    }

    /// Run `body` and put `analysisRevision` back as it was for `days` of `deviceId`. Moving rows between
    /// tiers fires the hot table's revision triggers but changes no data, so it must not look like a change.
    static func preservingRevisions(_ db: Database, deviceId: String, days: Set<Int>, _ body: () throws -> Void) throws {
        guard !days.isEmpty else { return try body() }
        let list = days.map(String.init).joined(separator: ",")
        let saved = try Row.fetchAll(db, sql: """
            SELECT day, revision FROM analysisRevision WHERE deviceId = ? AND day IN (\(list))
            """, arguments: [deviceId])
        try body()
        try db.execute(sql: "DELETE FROM analysisRevision WHERE deviceId = ? AND day IN (\(list))", arguments: [deviceId])
        for row in saved {
            try db.execute(sql: "INSERT INTO analysisRevision (deviceId, day, revision) VALUES (?, ?, ?)",
                           arguments: [deviceId, row[0] as Int, row[1] as Int64])
        }
    }
}

// MARK: - Virtual table

extension RawColdTier {
    /// Registers `<table>Cold` for every stream on `db`. Run once per connection, from `prepareDatabase`.
    public static func register(_ db: Database) throws {
        for stream in RawStream.allCases {
            let rc = sqlite3_create_module_v2(db.sqliteConnection, stream.coldTable, coldModule,
                                              UnsafeMutableRawPointer(bitPattern: stream.rawValue), nil)
            guard rc == SQLITE_OK else { throw DatabaseError(resultCode: ResultCode(rawValue: rc)) }
        }
    }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

/// Per-connection state of one stream's cold table. SQLite drives a connection from one thread at a time.
private final class ColdTable {
    let stream: RawStream
    let db: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]
    /// The last few decoded chunks with the blob they came from. A correlated probe ("is there heart rate
    /// at this second") asks the same hour thousands of times; the blob comparison keeps it exact.
    private var cache: [String: (blob: [UInt8], rows: RawChunkRows)] = [:]

    init(stream: RawStream, db: OpaquePointer) { self.stream = stream; self.db = db }

    deinit { for s in statements.values { sqlite3_finalize(s) } }

    func statement(_ sql: String) throws -> OpaquePointer {
        if let s = statements[sql] { return s }
        var s: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &s, nil)
        guard rc == SQLITE_OK, let s else { throw RawChunkCodecError.malformed(String(cString: sqlite3_errmsg(db))) }
        statements[sql] = s
        return s
    }

    /// Chunk keys overlapping [lo, hi], in iteration order.
    func keys(device: String?, lo: Int64, hi: Int64, descending: Bool) throws -> [(String, Int64)] {
        let dir = descending ? "DESC" : "ASC"
        let s = try statement(device == nil
            ? "SELECT deviceId, hourStart FROM rawChunk WHERE stream = ?1 AND hourStart >= ?2 AND hourStart <= ?3 ORDER BY deviceId \(dir), hourStart \(dir)"
            : "SELECT deviceId, hourStart FROM rawChunk WHERE stream = ?1 AND hourStart >= ?2 AND hourStart <= ?3 AND deviceId = ?4 ORDER BY hourStart \(dir)")
        defer { sqlite3_reset(s); sqlite3_clear_bindings(s) }
        sqlite3_bind_int64(s, 1, Int64(stream.rawValue))
        sqlite3_bind_int64(s, 2, lo < Int64.min + 3599 ? Int64.min : lo - 3599)
        sqlite3_bind_int64(s, 3, hi)
        if let device { sqlite3_bind_text(s, 4, device, -1, SQLITE_TRANSIENT_DESTRUCTOR) }
        var out: [(String, Int64)] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { return out }
            guard rc == SQLITE_ROW else { throw RawChunkCodecError.malformed(String(cString: sqlite3_errmsg(db))) }
            out.append((String(cString: sqlite3_column_text(s, 0)), sqlite3_column_int64(s, 1)))
        }
    }

    func rows(device: String, hourStart: Int64) throws -> RawChunkRows? {
        let s = try statement("SELECT data FROM rawChunk WHERE stream = ?1 AND deviceId = ?2 AND hourStart = ?3")
        defer { sqlite3_reset(s); sqlite3_clear_bindings(s) }
        sqlite3_bind_int64(s, 1, Int64(stream.rawValue))
        sqlite3_bind_text(s, 2, device, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int64(s, 3, hourStart)
        let rc = sqlite3_step(s)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw RawChunkCodecError.malformed(String(cString: sqlite3_errmsg(db))) }
        let blob = UnsafeRawBufferPointer(start: sqlite3_column_blob(s, 0), count: Int(sqlite3_column_bytes(s, 0)))
        let key = "\(device)\u{0}\(hourStart)"
        if let hit = cache[key], hit.blob.elementsEqual(blob) { return hit.rows }
        let decoded = try RawChunkCodec.decode(blob, stream: stream)
        if cache.count >= 4 { cache.removeAll() }
        cache[key] = (Array(blob), decoded)
        return decoded
    }
}

/// One scan over a cold table.
private final class ColdCursor {
    let table: ColdTable
    var keys: [(String, Int64)] = []
    var keyIndex = -1
    var device = ""
    var deviceC: [CChar] = []
    var chunk: RawChunkRows?
    var row = 0
    var lo = Int64.min, hi = Int64.max
    var descending = false
    var rowid: Int64 = 0
    var eof = true

    init(table: ColdTable) { self.table = table }

    func start(device: String?, lo: Int64, hi: Int64, descending: Bool) throws {
        self.lo = lo; self.hi = hi; self.descending = descending
        keys = lo > hi ? [] : try table.keys(device: device, lo: lo, hi: hi, descending: descending)
        keyIndex = -1
        chunk = nil
        eof = false
        try advance(first: true)
    }

    /// Moves to the next row inside [lo, hi], loading chunks as needed.
    func advance(first: Bool = false) throws {
        if !first, chunk != nil { row += descending ? -1 : 1 }
        while true {
            if let c = chunk, row >= 0, row < c.count {
                let t = c.ts[row]
                if t >= lo, t <= hi { rowid += 1; return }
                // Rows are ascending by ts, so a row past the bound ends this chunk.
                if descending ? t < lo : t > hi { chunk = nil; continue }
                row += descending ? -1 : 1
                continue
            }
            keyIndex += 1
            guard keyIndex < keys.count else { chunk = nil; eof = true; return }
            let (d, h) = keys[keyIndex]
            guard let c = try table.rows(device: d, hourStart: h) else { chunk = nil; continue }
            chunk = c
            if d != device { device = d; deviceC = Array(d.utf8CString) }
            row = descending ? c.count - 1 : 0
        }
    }

    func column(_ ctx: OpaquePointer?, _ i: Int32) {
        guard let c = chunk else { return sqlite3_result_null(ctx) }
        switch i {
        case 0:
            deviceC.withUnsafeBufferPointer { sqlite3_result_text(ctx, $0.baseAddress, Int32($0.count - 1), SQLITE_TRANSIENT_DESTRUCTOR) }
        case 1:
            sqlite3_result_int64(ctx, c.ts[row])
        default:
            let index = Int(i) - 2
            let col = c.columns[index]
            if col.isNull?[row] == true { return sqlite3_result_null(ctx) }
            if let blobs = col.blobs {
                // An empty blob has no base address, and a nil pointer would read back as NULL.
                if blobs[row].isEmpty { return sqlite3_result_zeroblob(ctx, 0) }
                return blobs[row].withUnsafeBytes { sqlite3_result_blob(ctx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT_DESTRUCTOR) }
            }
            if table.stream.columns[index].kind.isReal {
                sqlite3_result_double(ctx, Double(bitPattern: UInt64(bitPattern: col.values[row])))
            } else {
                sqlite3_result_int64(ctx, col.values[row])
            }
        }
    }
}

// The C side. A vtab/cursor allocation is the SQLite struct followed by one pointer to the Swift object.
private let vtabSize = MemoryLayout<sqlite3_vtab>.stride
private let cursorSize = MemoryLayout<sqlite3_vtab_cursor>.stride

private func object<T: AnyObject>(_ base: UnsafeMutableRawPointer, offset: Int) -> T {
    Unmanaged<T>.fromOpaque(base.load(fromByteOffset: offset, as: UnsafeMutableRawPointer.self)).takeUnretainedValue()
}

private func fail(_ vtab: UnsafeMutablePointer<sqlite3_vtab>?, _ error: Error) -> Int32 {
    if let vtab {
        sqlite3_free(vtab.pointee.zErrMsg)
        let message = Array("\(error)".utf8CString)
        let copy = sqlite3_malloc(Int32(message.count))?.assumingMemoryBound(to: CChar.self)
        copy?.initialize(from: message, count: message.count)
        vtab.pointee.zErrMsg = copy
    }
    return SQLITE_CORRUPT
}

/// idxNum bits: which bounds xFilter receives (in this order) and whether the scan runs newest first.
private enum Plan {
    static let device: Int32 = 1, eq: Int32 = 2, gt: Int32 = 4, ge: Int32 = 8, lt: Int32 = 16, le: Int32 = 32
    static let descending: Int32 = 64
}

private let coldModule: UnsafeMutablePointer<sqlite3_module> = {
    let m = UnsafeMutablePointer<sqlite3_module>.allocate(capacity: 1)
    m.initialize(to: sqlite3_module())
    m.pointee.iVersion = 0
    m.pointee.xCreate = nil  // eponymous only: usable as `hrSampleCold` without CREATE VIRTUAL TABLE
    m.pointee.xConnect = { db, aux, _, _, ppVTab, _ in
        guard let db, let stream = RawStream(rawValue: Int(bitPattern: aux)) else { return SQLITE_ERROR }
        let decl = "CREATE TABLE x(deviceId TEXT, ts INTEGER, "
            + stream.columns.map { "\($0.name) \($0.kind == .blob ? "BLOB" : $0.kind.isReal ? "REAL" : "INTEGER")" }.joined(separator: ", ") + ")"
        let rc = sqlite3_declare_vtab(db, decl)
        guard rc == SQLITE_OK else { return rc }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: vtabSize + 8, alignment: 8)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: vtabSize + 8)
        raw.storeBytes(of: Unmanaged.passRetained(ColdTable(stream: stream, db: db)).toOpaque(),
                       toByteOffset: vtabSize, as: UnsafeMutableRawPointer.self)
        ppVTab?.pointee = raw.assumingMemoryBound(to: sqlite3_vtab.self)
        return SQLITE_OK
    }
    let disconnect: @convention(c) (UnsafeMutablePointer<sqlite3_vtab>?) -> Int32 = { vtab in
        guard let vtab else { return SQLITE_OK }
        let raw = UnsafeMutableRawPointer(vtab)
        Unmanaged<ColdTable>.fromOpaque(raw.load(fromByteOffset: vtabSize, as: UnsafeMutableRawPointer.self)).release()
        sqlite3_free(vtab.pointee.zErrMsg)
        raw.deallocate()
        return SQLITE_OK
    }
    m.pointee.xDisconnect = disconnect
    m.pointee.xDestroy = disconnect
    m.pointee.xBestIndex = { vtab, info in
        guard let vtab, let info else { return SQLITE_ERROR }
        let stream = (object(UnsafeMutableRawPointer(vtab), offset: vtabSize) as ColdTable).stream
        var found: [Int32: Int] = [:]  // plan bit -> constraint index
        for i in 0..<Int(info.pointee.nConstraint) {
            let c = info.pointee.aConstraint[i]
            guard c.usable != 0 else { continue }
            let bit: Int32
            switch (c.iColumn, Int32(c.op)) {
            case (0, SQLITE_INDEX_CONSTRAINT_EQ): bit = Plan.device
            case (1, SQLITE_INDEX_CONSTRAINT_EQ): bit = Plan.eq
            case (1, SQLITE_INDEX_CONSTRAINT_GT): bit = Plan.gt
            case (1, SQLITE_INDEX_CONSTRAINT_GE): bit = Plan.ge
            case (1, SQLITE_INDEX_CONSTRAINT_LT): bit = Plan.lt
            case (1, SQLITE_INDEX_CONSTRAINT_LE): bit = Plan.le
            default: continue
            }
            if found[bit] == nil { found[bit] = i }
        }
        var plan: Int32 = 0
        var argv: Int32 = 0
        // SQLite still checks every constraint itself (omit stays 0); the bounds only narrow the scan.
        for bit in [Plan.device, Plan.eq, Plan.gt, Plan.ge, Plan.lt, Plan.le] {
            guard let i = found[bit] else { continue }
            argv += 1
            plan |= bit
            info.pointee.aConstraintUsage[i].argvIndex = argv
        }
        // Rows come out in primary-key order, (deviceId, ts, extra key columns), so an ORDER BY that is a
        // prefix of that key in one direction needs no sort and a LIMIT stops early. With one device the
        // key may start at ts.
        let orderBy = (0..<Int(info.pointee.nOrderBy)).map { info.pointee.aOrderBy[$0] }
        let oneDevice = plan & Plan.device != 0
        let key: [Int32] = [0, 1] + stream.extraKeyColumns.map { Int32($0 + 2) }
        let columns = orderBy.map(\.iColumn)
        let prefix = { (start: Int) in
            columns.count >= 2 - start && columns.count <= key.count - start
                && Array(key[start..<(start + columns.count)]) == columns
        }
        if let first = orderBy.first, orderBy.allSatisfy({ $0.desc == first.desc }),
           prefix(0) || (oneDevice && prefix(1)) {
            info.pointee.orderByConsumed = 1
            if first.desc != 0 { plan |= Plan.descending }
        }
        let ranged = plan & (Plan.eq | Plan.gt | Plan.ge | Plan.lt | Plan.le) != 0
        info.pointee.idxNum = plan
        info.pointee.estimatedCost = (oneDevice ? 1 : 100) * (ranged ? (plan & Plan.eq != 0 ? 1 : 1_000) : 1_000_000)
        info.pointee.estimatedRows = Int64(info.pointee.estimatedCost)
        return SQLITE_OK
    }
    m.pointee.xOpen = { vtab, ppCursor in
        guard let vtab else { return SQLITE_ERROR }
        let table: ColdTable = object(UnsafeMutableRawPointer(vtab), offset: vtabSize)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: cursorSize + 8, alignment: 8)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: cursorSize + 8)
        raw.storeBytes(of: Unmanaged.passRetained(ColdCursor(table: table)).toOpaque(),
                       toByteOffset: cursorSize, as: UnsafeMutableRawPointer.self)
        ppCursor?.pointee = raw.assumingMemoryBound(to: sqlite3_vtab_cursor.self)
        return SQLITE_OK
    }
    m.pointee.xClose = { cursor in
        guard let cursor else { return SQLITE_OK }
        let raw = UnsafeMutableRawPointer(cursor)
        Unmanaged<ColdCursor>.fromOpaque(raw.load(fromByteOffset: cursorSize, as: UnsafeMutableRawPointer.self)).release()
        raw.deallocate()
        return SQLITE_OK
    }
    m.pointee.xFilter = { cursor, idxNum, _, argc, argv in
        guard let cursor else { return SQLITE_ERROR }
        let c: ColdCursor = object(UnsafeMutableRawPointer(cursor), offset: cursorSize)
        var device: String?
        var lo = Int64.min, hi = Int64.max
        var next = 0
        func arg() -> OpaquePointer? { defer { next += 1 }; return next < argc ? argv?[next] : nil }
        // A bound that is not an integer is ignored; SQLite applies it to every returned row anyway.
        func int(_ v: OpaquePointer?) -> Int64? { sqlite3_value_type(v) == SQLITE_INTEGER ? sqlite3_value_int64(v) : nil }
        if idxNum & Plan.device != 0 {
            let v = arg()
            if sqlite3_value_type(v) == SQLITE_TEXT, let text = sqlite3_value_text(v) { device = String(cString: text) }
        }
        if idxNum & Plan.eq != 0, let v = int(arg()) { lo = max(lo, v); hi = min(hi, v) }
        if idxNum & Plan.gt != 0, let v = int(arg()) { if v == .max { hi = .min; lo = .max } else { lo = max(lo, v + 1) } }
        if idxNum & Plan.ge != 0, let v = int(arg()) { lo = max(lo, v) }
        if idxNum & Plan.lt != 0, let v = int(arg()) { if v == .min { hi = .min; lo = .max } else { hi = min(hi, v - 1) } }
        if idxNum & Plan.le != 0, let v = int(arg()) { hi = min(hi, v) }
        do {
            try c.start(device: device, lo: lo, hi: hi, descending: idxNum & Plan.descending != 0)
            return SQLITE_OK
        } catch {
            return fail(cursor.pointee.pVtab, error)
        }
    }
    m.pointee.xNext = { cursor in
        guard let cursor else { return SQLITE_ERROR }
        let c: ColdCursor = object(UnsafeMutableRawPointer(cursor), offset: cursorSize)
        do { try c.advance(); return SQLITE_OK } catch { return fail(cursor.pointee.pVtab, error) }
    }
    m.pointee.xEof = { cursor in
        guard let cursor else { return 1 }
        let c: ColdCursor = object(UnsafeMutableRawPointer(cursor), offset: cursorSize)
        return c.eof ? 1 : 0
    }
    m.pointee.xColumn = { cursor, ctx, i in
        guard let cursor else { return SQLITE_ERROR }
        let c: ColdCursor = object(UnsafeMutableRawPointer(cursor), offset: cursorSize)
        c.column(ctx, i)
        return SQLITE_OK
    }
    m.pointee.xRowid = { cursor, rowid in
        guard let cursor else { return SQLITE_ERROR }
        let c: ColdCursor = object(UnsafeMutableRawPointer(cursor), offset: cursorSize)
        rowid?.pointee = c.rowid
        return SQLITE_OK
    }
    return m
}()
