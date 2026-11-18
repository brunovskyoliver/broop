import Foundation
import SQLite3
import WhoopProtocol

/// Minimal read-only SQLite reader, the same shape as SleepBench's. Deliberately not GRDB: this tool must
/// open a COPY of a device database at any schema version without running migrations against it. Opened
/// `immutable=1` so it can never write.
final class ReadOnlyDB {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let uri = "file:\(path)?immutable=1"
        let rc = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK else {
            throw Err("cannot open \(path): \(String(cString: sqlite3_errstr(rc)))")
        }
    }
    deinit { if let handle { sqlite3_close(handle) } }

    struct Err: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    func query(_ sql: String, _ each: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Err("prepare failed: \(String(cString: sqlite3_errmsg(handle))) [\(sql)]")
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { each(stmt!) }
    }

    static func int(_ s: OpaquePointer, _ i: Int32) -> Int { Int(sqlite3_column_int64(s, i)) }
    static func dbl(_ s: OpaquePointer, _ i: Int32) -> Double { sqlite3_column_double(s, i) }
    static func isNull(_ s: OpaquePointer, _ i: Int32) -> Bool { sqlite3_column_type(s, i) == SQLITE_NULL }
    static func str(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }
    /// A string literal safe to splice into SQL (device ids come from the command line).
    static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
}

/// One stored workout row, used as a label.
struct LabelRow {
    let deviceId: String
    let startTs: Int
    let endTs: Int
    let sport: String
    let source: String
    /// True for a row saved from the suggestion card: its bounds and sport are the detector's own.
    var cardSaved = false
    var span: Span { Span(start: startTs, end: endTs) }
}

struct DayStreams {
    var hr: [HRSample] = []
    var grav: [GravitySample] = []
    var steps: [StepSample] = []
}

extension ReadOnlyDB {
    /// The `deviceId` holding the most HR rows: the strap whose streams a replay should read.
    func busiestStreamDevice() throws -> String? {
        var out: String?
        try query("SELECT deviceId FROM hrSample GROUP BY deviceId ORDER BY COUNT(*) DESC LIMIT 1") {
            out = ReadOnlyDB.str($0, 0)
        }
        return out
    }

    func hrRange(device: String) throws -> (Int, Int)? {
        var out: (Int, Int)?
        try query("SELECT MIN(ts), MAX(ts) FROM hrSample WHERE deviceId = \(ReadOnlyDB.quoted(device))") {
            if !ReadOnlyDB.isNull($0, 0) { out = (ReadOnlyDB.int($0, 0), ReadOnlyDB.int($0, 1)) }
        }
        return out
    }

    func streams(device: String, from: Int, to: Int) throws -> DayStreams {
        var st = DayStreams()
        let w = "deviceId = \(ReadOnlyDB.quoted(device)) AND ts >= \(from) AND ts < \(to)"
        try query("SELECT ts, bpm FROM hrSample WHERE \(w) ORDER BY ts") {
            st.hr.append(HRSample(ts: ReadOnlyDB.int($0, 0), bpm: ReadOnlyDB.int($0, 1)))
        }
        try query("SELECT ts, x, y, z FROM gravitySample WHERE \(w) ORDER BY ts") {
            st.grav.append(GravitySample(ts: ReadOnlyDB.int($0, 0), x: ReadOnlyDB.dbl($0, 1),
                                         y: ReadOnlyDB.dbl($0, 2), z: ReadOnlyDB.dbl($0, 3)))
        }
        try query("SELECT ts, counter, activityClass FROM stepSample WHERE \(w) ORDER BY ts") {
            st.steps.append(StepSample(ts: ReadOnlyDB.int($0, 0), counter: ReadOnlyDB.int($0, 1),
                                       activityClass: ReadOnlyDB.isNull($0, 2) ? nil : ReadOnlyDB.int($0, 2)))
        }
        return st
    }

    /// Every stored workout that can serve as a label: anything the detector did not write itself. Rows
    /// with sport "detected" and rows under a computed ("-noop") id are the detector's own output.
    func labels(from: Int, to: Int) throws -> [LabelRow] {
        var out: [LabelRow] = []
        // A card-saved row is a manual row that is either the generic "Workout" or still carries the
        // classifier's class (newer builds store the suggested sport). The column postdates some
        // database copies, so its presence is checked rather than assumed.
        var hasClass = false
        try query("PRAGMA table_info(workout)") { if ReadOnlyDB.str($0, 1) == "suggestedClass" { hasClass = true } }
        let card = "source = 'manual' AND (sport = 'Workout'" + (hasClass ? " OR suggestedClass IS NOT NULL)" : ")")
        let sql = """
        SELECT deviceId, startTs, endTs, sport, source, (\(card)) FROM workout
        WHERE startTs < \(to) AND endTs > \(from) AND endTs > startTs
          AND sport <> 'detected' AND deviceId NOT LIKE '%-noop'
        ORDER BY startTs
        """
        try query(sql) {
            out.append(LabelRow(deviceId: ReadOnlyDB.str($0, 0) ?? "", startTs: ReadOnlyDB.int($0, 1),
                                endTs: ReadOnlyDB.int($0, 2), sport: ReadOnlyDB.str($0, 3) ?? "",
                                source: ReadOnlyDB.str($0, 4) ?? "", cardSaved: ReadOnlyDB.int($0, 5) != 0))
        }
        return out
    }

    /// Stored resting HR per local day key ("yyyy-MM-dd"). A computed ("-noop") row wins a shared day,
    /// since that is the value the app scores the day against.
    func restingHRByDay() throws -> [String: Int] {
        var out: [String: Int] = [:]
        let sql = """
        SELECT day, restingHr FROM dailyMetric WHERE restingHr IS NOT NULL
        ORDER BY (deviceId LIKE '%-noop') ASC
        """
        try query(sql) { if let d = ReadOnlyDB.str($0, 0) { out[d] = ReadOnlyDB.int($0, 1) } }
        return out
    }
}
