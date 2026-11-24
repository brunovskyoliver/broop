import XCTest
import GRDB
@testable import WhoopStore
@testable import WhoopProtocol

/// The cold tier must be invisible: every reader returns the same answer before and after sealing, and
/// every write, delete and maintenance pass leaves the same data it would have left on an unsealed store.
/// Most tests build two stores from one seed, seal one of them, and compare everything they can read.
final class RawColdTierTests: XCTestCase {
    private let now = 1_760_000_000
    private let devices = ["w5", "w4", "oura"]

    // MARK: - Codec

    func testCodecRoundTripsEveryStreamBitForBit() throws {
        var rng = Rng(7)
        let specials: [Double] = [0, -0.0, .infinity, -.infinity, .nan, Double(bitPattern: 0x7FF8_0000_DEAD_BEEF),
                                  .leastNonzeroMagnitude, .greatestFiniteMagnitude, 0.1, -1.5, 1e-310]
        for stream in RawStream.allCases {
            for n in [0, 1, 2, 3, 50, 4000] {
                for mode in 0..<3 {
                    let f32 = mode == 0
                    var ts: [Int64] = []
                    var t = Int64(rng.next() % 1_000_000)
                    for _ in 0..<n { t += Int64(rng.next() % 3); ts.append(t) }   // repeats, as RR has
                    let k = Int(rng.next() % 25)
                    let columns = stream.columns.map { _, kind -> RawColumnValues in
                        if kind == .blob {
                            return RawColumnValues(blobs: (0..<n).map { _ in
                                let len = rng.next() % 5 == 0 ? Int(rng.next() % 41) : 32
                                return (0..<len).map { _ in rng.next() % 3 == 0 ? UInt8(truncatingIfNeeded: rng.next()) : 7 }
                            })
                        }
                        var values: [Int64] = [], nulls: [Bool] = []
                        for i in 0..<n {
                            let null = kind.isOptional && rng.next() % 4 == 0
                            nulls.append(null)
                            if null { values.append(0); continue }
                            if kind.isReal {
                                // Mode 2 input: small integers over 2^k, with an occasional -0.0 that forces a fallback.
                                let scaled = rng.next() % 500 == 0 ? -0.0
                                    : Double(Int64(bitPattern: rng.next()) >> (34 + rng.next() % 30)) / Double(UInt64(1) << k)
                                let d = mode == 2 ? scaled
                                    : f32 ? Double(Float(bitPattern: UInt32(truncatingIfNeeded: rng.next())))
                                            : (i % 9 == 0 ? specials[Int(rng.next() % UInt64(specials.count))]
                                                          : Double(bitPattern: rng.next()))
                                values.append(Int64(bitPattern: d.bitPattern))
                            } else {
                                let pick = rng.next() % 10
                                values.append(pick == 0 ? .min : pick == 1 ? .max : pick < 6 ? 60 : Int64(bitPattern: rng.next()) >> (rng.next() % 64))
                            }
                        }
                        return RawColumnValues(values: values, isNull: kind.isOptional ? nulls : nil)
                    }
                    let rows = RawChunkRows(ts: ts, columns: columns)
                    for compress in [true, false] {
                        let blob = RawChunkCodec.encode(rows, stream: stream, compress: compress)
                        XCTAssertEqual(try RawChunkCodec.decode(blob, stream: stream), rows, "\(stream) n=\(n)")
                        XCTAssertThrowsError(try RawChunkCodec.decode(blob + [0], stream: stream), "trailing byte")
                        if blob.count > 2 {
                            XCTAssertThrowsError(try RawChunkCodec.decode(Array(blob.dropLast()), stream: stream))
                        }
                    }
                }
            }
        }
        XCTAssertThrowsError(try RawChunkCodec.decode([2, 0, 0], stream: .hr), "unknown version")
    }

    func testScaledIntegerModeIsChosenOnlyWhenExact() throws {
        let w4 = [-16_384, -1, 0, 1, 8192, 16_383].map { Double($0) / 16_384 }
        XCTAssertEqual(RawChunkCodec.scaleExponent(w4.map { Int64(bitPattern: $0.bitPattern) }), 14)
        XCTAssertEqual(RawChunkCodec.scaleExponent([3.0, -2.0].map { Int64(bitPattern: $0.bitPattern) }), 0)
        for refused: [Double] in [[0.1], [-0.0], [.nan], [.infinity], [1.0 / Double(1 << 25)], [Double(1 << 60)]] {
            XCTAssertNil(RawChunkCodec.scaleExponent(refused.map { Int64(bitPattern: $0.bitPattern) }), "\(refused)")
        }
        // ts 10, 11: gaps 10, 1, deltas 10, -9 -> 20, 17. x = 0.5, -0.25: mode 2, k 2, IntSeq of 2, -1
        // (deltas 2, -3 -> 4, 5). y = 0, 0 and z = 1, 1: mode 2, k 0. dynAccel all NULL: presence 0 with a
        // run of 1, then mode 2, k 0 over no values.
        let rows = RawChunkRows(ts: [10, 11], columns: [
            RawColumnValues(values: [0.5, -0.25].map { Int64(bitPattern: $0.bitPattern) }),
            RawColumnValues(values: [0, 0].map { Int64(bitPattern: ($0 as Double).bitPattern) }),
            RawColumnValues(values: [1, 1].map { Int64(bitPattern: ($0 as Double).bitPattern) }),
            RawColumnValues(values: [0, 0]),
            RawColumnValues(values: [0, 0], isNull: [true, true]),
        ])
        let blob = RawChunkCodec.encode(rows, stream: .gravity, compress: false)
        XCTAssertEqual(blob, [1, 0, 2, 20, 17,   2, 2, 4, 5,   2, 0, 0, 1,   2, 0, 2, 0, 0,   0, 1,   0, 1, 2, 0])
        XCTAssertEqual(try RawChunkCodec.decode(blob, stream: .gravity), rows)
    }

    func testBlobColumnLayout() throws {
        // ts 7, 8 -> 14, 11. lengths 2, 1 (deltas 2, -1 -> 4, 1); byte 0 of both: 5, 5 -> 10, then 0 with a
        // run of 0; byte 1 of the first only: 9 -> 18.
        let rows = RawChunkRows(ts: [7, 8], columns: [RawColumnValues(blobs: [[5, 9], [5]])])
        let blob = RawChunkCodec.encode(rows, stream: .v18Aux, compress: false)
        XCTAssertEqual(blob, [1, 0, 2, 14, 11, 4, 1, 10, 0, 0, 18])
        XCTAssertEqual(try RawChunkCodec.decode(blob, stream: .v18Aux), rows)
    }

    /// The layout is a contract with the Kotlin twin, so one encoding is pinned byte for byte.
    func testCodecLayoutIsPinned() {
        let rows = RawChunkRows(ts: [100, 101, 101, 103],
                                columns: [RawColumnValues(values: [60, 60, 60, 58]), RawColumnValues(values: [0, 0, 0, 0])])
        // version 1, no zlib; n=4.
        // ts: gaps D = 100, 1, 0, 2, written as an IntSeq, so deltas 100, -99, -1, 2 -> zigzag 200, 197, 1, 4
        // (200 and 197 take two LEB128 bytes each).
        // bpm: 60 -> 120; then 0 with a run of 1 more; then -2 -> 3.
        // synced: 0 with a run of 3 more.
        XCTAssertEqual(RawChunkCodec.encode(rows, stream: .hr),
                       [1, 0, 4, 200, 1, 197, 1, 1, 4, 120, 0, 1, 3, 0, 3])
    }

    // MARK: - Readers

    func testEveryReaderAnswersTheSameAfterSealing() async throws {
        let plain = try await seeded()
        let sealed = try await seeded()
        let before = try await snapshot(plain)
        try await sealed.runStorageMaintenance(now: now, compact: true)
        let chunks = try await chunkCount(sealed)
        XCTAssertGreaterThan(chunks, 100, "the seed must actually seal")
        let hotLeft = try await sealed.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample WHERE ts < ?",
                             arguments: [(self.now - RawColdTier.sealAgeSeconds) / 3600 * 3600])
        }
        let groups = try await sealed.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT deviceId, ts / 3600 * 3600 AS h, COUNT(*) AS n, SUM(typeof(bpm) = 'real') AS r FROM hrSample WHERE ts < ? GROUP BY 1, 2",
                             arguments: [(self.now - RawColdTier.sealAgeSeconds) / 3600 * 3600]).map { "\($0)" }
        }
        // Every closed hour is sealed except the one holding a REAL heart rate, which cannot round-trip
        // through an integer column and so stays in rows.
        XCTAssertEqual(groups.count, 1, "\(groups)")
        XCTAssertTrue(groups.first?.contains("r:1") == true, "\(groups)")
        XCTAssertGreaterThan(hotLeft ?? 0, 0)
        try await plain.runStorageMaintenance(now: now, compact: true, sealing: false)
        let unsealed = try await chunkCount(plain)
        XCTAssertEqual(unsealed, 0)
        try await assertSame(plain, sealed, before: before)
    }

    func testByteEstimatesCountChunkBytes() async throws {
        let store = try await seeded()
        try await store.runStorageMaintenance(now: now, compact: true)
        // The WHOOP 4.0's sealed gravity is exactly i16 / 16384, so its chunks take the scaled mode at k = 14.
        let w4 = try await store.dbWriter.read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM rawChunk WHERE stream = 3 AND deviceId = 'w4' LIMIT 1")
        }
        let x = try RawChunkCodec.decode([UInt8](try XCTUnwrap(w4)), stream: .gravity).columns[0].values
        XCTAssertEqual(RawChunkCodec.scaleExponent(x), 14)
        let estimates = try await store.storageByteEstimates()
        for stream in RawStream.allCases {
            let key = WhoopStore.rawTableKeys.first { $0.1 == stream.table }!.0
            let (hot, cold) = try await store.dbWriter.read { db in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(stream.table)") ?? 0,
                 try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(LENGTH(data)), 0) FROM rawChunk WHERE stream = \(stream.rawValue)") ?? 0)
            }
            XCTAssertGreaterThan(cold, 0, "\(stream)")
            XCTAssertGreaterThan(hot, 0, "\(stream)")
            // Hot rows at their sampled payload (8 bytes per number at least) plus the sealed bytes.
            XCTAssertGreaterThanOrEqual(estimates[key] ?? 0, cold + hot * 16, "\(stream)")
        }
    }

    func testSealingKeepsRevisionsAndCanBeRepeated() async throws {
        let store = try await seeded()
        let revisions = try await revisionTable(store)
        let before = try await snapshot(store)
        try await store.runStorageMaintenance(now: now, compact: true)
        try await store.runStorageMaintenance(now: now + 600, compact: false)
        let afterRevisions = try await revisionTable(store)
        XCTAssertEqual(afterRevisions, revisions, "moving rows between tiers is not a data change")
        let after = try await snapshot(store)
        XCTAssertEqual(diff(before, after), [])
    }

    func testPassWithoutChargerIsBounded() async throws {
        let store = try await seeded()
        try await store.runStorageMaintenance(now: now, compact: false)
        let perStream = try await store.dbWriter.read { db in
            try Int.fetchAll(db, sql: "SELECT COUNT(*) FROM rawChunk GROUP BY stream")
        }
        XCTAssertTrue(perStream.allSatisfy { $0 <= RawColdTier.hoursPerPassWithoutCharger })
    }

    // MARK: - Writes into sealed hours

    /// The newest-N cap on `v18AuxSample` counts sealed rows and deletes across both tiers, cutting inside a
    /// sealed hour, exactly as it cuts the rows of an unsealed store.
    func testV18AuxCapKeepsTheNewestRowsAcrossTiers() async throws {
        let plain = try await seeded()
        let sealed = try await seeded()
        try await plain.runStorageMaintenance(now: now, compact: true, sealing: false)
        try await sealed.runStorageMaintenance(now: now, compact: true)
        let total = try await sealed.v18AuxCountForTest()
        let keep = total / 2 + 7   // lands inside a sealed hour
        let late = Streams(v18Aux: [V18AuxSample(ts: now - 3 * 86_400 + 5, rrCount: 1),
                                    V18AuxSample(ts: now - 10, rrCount: 2)])
        for store in [plain, sealed] {
            _ = try await store.insert(late, deviceId: "w5", v18AuxRetentionRows: keep, v18AuxPruneEveryRows: 1)
        }
        let kept = try await sealed.v18AuxCountForTest()
        XCTAssertEqual(kept, keep)
        try await assertSame(plain, sealed)
    }

    func testLateRowsMergeExactlyAsOnAnUnsealedStore() async throws {
        let plain = try await seeded()
        let sealed = try await seeded()
        try await sealed.runStorageMaintenance(now: now, compact: true)
        let old = now - 3 * 86_400 + 1800
        // Duplicates (dropped on conflict), new seconds, a WHOOP 5 promote of a legacy beat, a 500 ms fill
        // beat the fill rule must flag against sealed heart rate, and every other stream.
        let late = Streams(
            hr: [HRSample(ts: old, bpm: 1), HRSample(ts: old + 1, bpm: 99)],
            rr: [RRInterval(ts: old + 4, rrMs: 777, srcChannel: .whoop5Historical),
                 RRInterval(ts: old + 2, rrMs: 500, srcChannel: .whoop5Standard),
                 RRInterval(ts: old + 13, rrMs: 812, srcChannel: .whoop5Historical)],
            skinTemp: [SkinTempSample(ts: old + 3, raw: 5)],
            gravity: [GravitySample(ts: old + 3, x: 0.3, y: 0.2, z: 0.1)],
            steps: [StepSample(ts: old + 3, counter: 1)],
            sleepState: [SleepStateSample(ts: old + 3, state: 2)])
        _ = try await plain.insert(late, deviceId: "w5")
        _ = try await sealed.insert(late, deviceId: "w5")
        try await assertSame(plain, sealed)
        // The next pass packs the touched hours again.
        try await sealed.runStorageMaintenance(now: now, compact: false)
        let hot = try await sealed.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval WHERE deviceId = 'w5' AND ts < ?", arguments: [old + 3600])
        }
        XCTAssertEqual(hot, 0)
        try await assertSame(plain, sealed)
    }

    func testGuardRefusesARowForASealedHour() async throws {
        let store = try await seeded()
        try await store.runStorageMaintenance(now: now, compact: true)
        do {
            try await store.dbWriter.write { db in
                try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('w5', ?, 70)",
                               arguments: [self.now - 3 * 86_400 + 7])
            }
            XCTFail("a raw INSERT into a sealed hour must fail rather than duplicate a key")
        } catch {}
    }

    // MARK: - Deletes

    func testRetentionAndThinningMatchAfterSealing() async throws {
        let plain = try await seeded()
        let sealed = try await seeded()
        try await sealed.runStorageMaintenance(now: now, compact: true)
        // A month later most of the seed is below the floor: heart rate thins, everything else goes.
        for days in [29, 31, 33, 40] {
            let later = now + days * 86_400
            try await plain.runStorageMaintenance(now: later, compact: false, sealing: false)
            try await sealed.runStorageMaintenance(now: later, compact: true)
            try await assertSame(plain, sealed)
        }
    }

    func testDeviceWipeAndIdentityAdoptionReachSealedRows() async throws {
        let plain = try await seeded()
        let sealed = try await seeded()
        try await sealed.runStorageMaintenance(now: now, compact: true)
        for store in [plain, sealed] {
            try await store.deleteAllData(deviceId: "w4")
            // Re-point the ring onto another id that already holds rows, so the merge meets key clashes.
            let registry = DeviceRegistryStore(dbQueue: await store.dbWriter)
            try registry.add(PairedDevice(id: "oura", brand: "Oura", model: "Ring 4", sourceKind: .liveBLE,
                                          capabilities: [], status: .active, addedAt: 0, lastSeenAt: 0))
            let moved = try registry.adoptSerialIdentity(from: "oura", to: "w5")
            XCTAssertTrue(moved)
        }
        let left = try await sealed.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawChunk WHERE deviceId = 'w4'")
        }
        XCTAssertEqual(left, 0)
        try await assertSame(plain, sealed)
    }

    func testImplausibleTimestampHealReachesSealedRows() async throws {
        let plain = try await seeded()
        let sealed = try await seeded()
        let garbage = Streams(hr: (0..<50).map { HRSample(ts: 1_400_000_000 + $0, bpm: 50) },
                              gravity: (0..<50).map { GravitySample(ts: 1_400_000_000 + $0, x: 1, y: 0, z: 0) })
        _ = try await plain.insert(garbage, deviceId: "w5")
        _ = try await sealed.insert(garbage, deviceId: "w5")
        try await plain.runStorageMaintenance(now: now, compact: true, sealing: false)
        try await sealed.runStorageMaintenance(now: now, compact: true)
        let sealedGarbage = try await sealed.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawChunk WHERE hourStart < 1500000000")
        }
        XCTAssertEqual(sealedGarbage, 1, "retention took the gravity; the heart rate stays, sealed")
        let a = try await plain.healImplausibleTimestamps(now: now, todayLocalDayKey: "2025-10-09")
        let b = try await sealed.healImplausibleTimestamps(now: now, todayLocalDayKey: "2025-10-09")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.rawRowsDeleted, 50)
        try await assertSame(plain, sealed)
    }

    // MARK: - Old databases

    /// A backup from before the cold tier is a store without `rawChunk`. Opening it migrates, and its rows
    /// read and seal like any others.
    func testStoreFromBeforeTheColdTierOpensAndSeals() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("whoop.sqlite").path
        let now = self.now
        do {
            let queue = try DatabaseQueue(path: path)
            try WhoopStore.makeMigrator().migrate(queue, upTo: "v48-ecg-waveform")
            try await queue.write { db in
                for i in 0..<5000 {
                    try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('d', ?, ?)",
                                   arguments: [now - 5 * 86_400 + i * 7, 50 + i % 40])
                }
            }
            let hasChunk = try await queue.read { db in try db.tableExists("rawChunk") }
            XCTAssertFalse(hasChunk)
        }
        let store = try await WhoopStore(path: path)
        let before = try await store.hrSamples(deviceId: "d", from: 0, to: now, limit: 100_000)
        XCTAssertEqual(before.count, 5000)
        try await store.runStorageMaintenance(now: now, compact: true)
        let chunks = try await chunkCount(store)
        XCTAssertGreaterThan(chunks, 0)
        let after = try await store.hrSamples(deviceId: "d", from: 0, to: now, limit: 100_000)
        XCTAssertEqual(after, before)
        // A second connection of the pool reads the cold tier too.
        let latest = try await store.latestHRSampleTs(deviceId: "d")
        XCTAssertEqual(latest, before.last?.ts)
    }

    /// Measurement on a copy of a real store: `NOOP_COLD_DB=<copy> swift test --filter testRealDatabaseCopySeals`.
    /// Runs maintenance twice, the second time sealing when `NOOP_COLD_SEAL` is set, so a sealed copy and a
    /// plain copy differ only by sealing (each pass re-thins the trailing HR week, which bumps revisions).
    /// `NOOP_COLD_DUMP=<name>` writes the reader digests next to the copy; `NOOP_COLD_FULL_ONLY` limits them to
    /// the whole-history window (for timing with `COLD_TIMING`).
    func testRealDatabaseCopySeals() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NOOP_COLD_DB"] else { throw XCTSkip("NOOP_COLD_DB not set") }
        let store = try await WhoopStore(path: path)
        let frontier = try await store.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT MAX(ts) FROM hrSample") ?? 0 }
        let now = frontier + 600
        let size = { () -> Int in ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0 }
        try await store.runStorageMaintenance(now: now, compact: true, sealing: false)
        try await store.vacuumForTest()
        print("COLD size after plain maintenance + VACUUM: \(size()) bytes")
        let t0 = Date()
        try await store.runStorageMaintenance(now: now, compact: true, sealing: env["NOOP_COLD_SEAL"] != nil)
        print(String(format: "COLD second pass: %.1f s", Date().timeIntervalSince(t0)))
        try await store.vacuumForTest()
        print("COLD size after second pass + VACUUM: \(size()) bytes")
        let report = try await store.dbWriter.read { db -> [String] in
            let chunks = try Row.fetchAll(db, sql: """
                SELECT stream, COUNT(*) AS chunks, SUM(n) AS rows, SUM(length(data)) AS bytes,
                       SUM(substr(data, 2, 1) = x'01') AS zipped FROM rawChunk GROUP BY stream
                """).map { "COLD chunks \($0)" }
            let pages = try Row.fetchAll(db, sql: """
                SELECT name, SUM(pgsize) AS bytes, SUM(ncell) AS cells FROM dbstat GROUP BY name ORDER BY bytes DESC LIMIT 25
                """).map { "COLD dbstat \($0)" }
            return chunks + pages
        }
        report.forEach { print($0) }
        let t2 = Date()
        let cutoff = try await store.dbWriter.read { db in
            try Int.fetchOne(db, sql: """
                SELECT MIN(ts) FROM (SELECT ts FROM \(RawStream.v18Aux.union) WHERE deviceId = 'whoop-5B01542864'
                ORDER BY ts DESC LIMIT \(WhoopStore.v18AuxRetentionRows))
                """)
        }
        print(String(format: "COLD v18Aux cap cutoff %@ found in %.2f s", "\(cutoff as Any)", Date().timeIntervalSince(t2)))
        guard let name = env["NOOP_COLD_DUMP"] else { return }
        let devices = try await store.dbWriter.read { db in
            try String.fetchAll(db, sql: "SELECT deviceId FROM hrSample UNION SELECT deviceId FROM rrInterval UNION SELECT deviceId FROM rawChunk WHERE stream IN (1, 2)")
        }
        let start = now - 31 * 86_400
        var windows: [(Int, Int)] = [(0, Int.max - 1)]
        var day = start / 86_400 * 86_400
        while env["NOOP_COLD_FULL_ONLY"] == nil, day < now {
            windows.append((day, day + 86_399)); windows.append((day + 18 * 3600, day + 34 * 3600)); day += 86_400
        }
        let t1 = Date()
        let lines = try await snapshot(store, devices: devices, windows: windows, start: start, now: now,
                                       csvSince: now - 3 * 86_400, rowLimit: 5_000_000, digest: true)
        let out = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        print("COLD dump \(name): \(lines.count) answers in \(String(format: "%.1f", Date().timeIntervalSince(t1))) s")
    }

    // MARK: - Fixtures

    /// Three straps over four days: a WHOOP 5 with tagged transports and 500 ms fill beats, a WHOOP 4 with
    /// its history/realtime/standard/unlabelled sources, and a ring with every optical channel.
    private func seeded() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        var rng = Rng(42)
        let start = now - 4 * 86_400
        for (d, device) in devices.enumerated() {
            try await store.upsertDevice(id: device, mac: nil, name: nil)
            var s = Streams()
            var t = start + d
            while t < now {
                s.hr.append(HRSample(ts: t, bpm: 45 + Int(rng.next() % 80)))
                if rng.next() % 3 == 0 {
                    s.ppgHr.append(PpgHrSample(ts: t + Int(rng.next() % 2), bpm: 61, conf: 0.4))
                }
                let beats = 1 + Int(rng.next() % 2)
                for _ in 0..<beats {
                    let channel: RRSourceChannel?
                    switch device {
                    case "w5": channel = [.whoop5Historical, .whoop5Standard, .whoop5Realtime, nil][Int(rng.next() % 4)]
                    case "w4": channel = [.whoop4Historical, .whoop4Realtime, .whoop4Standard, nil][Int(rng.next() % 4)]
                    default: channel = [.greenQuality, .spo2Ibi, .ibiAmplitude, .ibiBare][Int(rng.next() % 4)]
                    }
                    let rr = rng.next() % 9 == 0 ? 500 : 600 + Int(rng.next() % 500)
                    s.rr.append(RRInterval(ts: t, rrMs: rr, srcChannel: channel))
                }
                // The WHOOP 4.0's gravity is an i16 / 16384, which seals in the scaled-integer mode.
                let q = { Double(Int(rng.next() % 32_768) - 16_384) / 16_384 }
                s.gravity.append(device == "w4"
                    ? GravitySample(ts: t, x: q(), y: q(), z: q(), dynAccel: nil)
                    : GravitySample(ts: t, x: Double(Float(rng.unit())), y: rng.unit(), z: -0.98,
                                    dynAccel: rng.next() % 5 == 0 ? nil : Double(Float(rng.unit()))))
                if device == "w5" {
                    s.v18Aux.append(V18AuxSample(ts: t, recordIndex: t - start, rrCount: Int(rng.next() % 3),
                                                 hrQualityFlags: rng.next() % 2 == 0 ? 0x80 : nil,
                                                 heartRateAlt: 60 + Int(rng.next() % 5), statusWord: 0x1234,
                                                 unknownF32Bits: Int(rng.next() % 1_000_000)))
                }
                s.skinTemp.append(SkinTempSample(ts: t, raw: 3000 + Int(rng.next() % 50),
                                                 aux1Raw: rng.next() % 2 == 0 ? nil : 7, aux2Raw: nil))
                s.steps.append(StepSample(ts: t, counter: (t - start) / 40,
                                          activityClass: rng.next() % 3 == 0 ? nil : Int(rng.next() % 3)))
                s.sleepState.append(SleepStateSample(ts: t, state: Int(rng.next() % 4),
                                                     rawByte: rng.next() % 2 == 0 ? nil : Int(rng.next() % 256)))
                t += 11 + Int(rng.next() % 20)
            }
            _ = try await store.insert(s, deviceId: device)
        }
        // A future-stamped quarantine and one REAL heart rate the codec must refuse to seal.
        try await store.dbWriter.write { db in
            try db.execute(sql: "UPDATE rrInterval SET tsSuspect = 1 WHERE deviceId = 'oura' AND ts % 7 = 0")
            try db.execute(sql: "UPDATE hrSample SET bpm = 61.5 WHERE deviceId = 'w4' AND ts = (SELECT MIN(ts) FROM hrSample WHERE deviceId = 'w4')")
        }
        // Rebuild the tables WITHOUT ROWID first (nothing is old enough to seal yet), so a later
        // comparison sees only what sealing changed and not the rebuild's new scan order.
        try await store.runStorageMaintenance(now: start + 3600, compact: true)
        let chunks = try await chunkCount(store)
        XCTAssertEqual(chunks, 0)
        return store
    }

    /// Everything a caller can read about the raw streams, one line per answer.
    private func snapshot(_ store: WhoopStore) async throws -> [String] {
        let start = now - 4 * 86_400
        let windows = [(0, Int.max - 1), (start, now), (start + 7200, start + 7200 + 1800),
                       (now - 50 * 3600, now - 40 * 3600), (start + 86_400 + 13, start + 2 * 86_400 - 1), (5, 10)]
        return try await snapshot(store, devices: devices + ["nobody"], windows: windows, start: start, now: now,
                                  csvSince: start + 3600, rowLimit: 1_000_000)
    }

    private func snapshot(_ store: WhoopStore, devices: [String], windows: [(Int, Int)], start: Int, now: Int,
                          csvSince: Int, rowLimit: Int, digest: Bool = false) async throws -> [String] {
        var out: [String] = []
        let timing = ProcessInfo.processInfo.environment["COLD_TIMING"] != nil
        var last = Date()
        func add(_ label: String, _ value: Any) {
            let line = "\(value)"
            out.append(digest ? "\(label): \(line.utf8.count) bytes, fnv \(fnv(line))" : "\(label): \(line)")
            if timing { let t = Date().timeIntervalSince(last); if t > 0.05 { print(String(format: "SLOW %.3f %@", t, label)) }; last = Date() }
        }
        add("hrFingerprint()", try await store.hrFingerprint())
        add("analysisFingerprint", try await store.analysisFingerprint())
        add("storageRowCounts", try await store.storageRowCounts().sorted { $0.key < $1.key })
        // Sealed streams report their real chunk bytes, so only the other tables' estimates stay the same;
        // `testByteEstimatesCountChunkBytes` covers the sealed ones.
        let sealedKeys = Set(WhoopStore.rawTableKeys.filter { k in RawStream.allCases.contains { $0.table == k.1 } }.map(\.0))
        add("storageByteEstimates", try await store.storageByteEstimates().filter { !sealedKeys.contains($0.key) }.sorted { $0.key < $1.key })
        add("storageStats", try await store.storageStats())
        add("rowCountsForTest", try await store.storageStats_rowCountsForTest())
        add("stepCountForTest", try await store.stepCountForTest())
        add("sleepStateCountForTest", try await store.sleepStateCountForTest())
        add("v18AuxCountForTest", try await store.v18AuxCountForTest())
        for (from, to) in windows {
            add("rawSampleCountsByDevice \(from)", try await store.rawSampleCountsByDevice(from: from, to: to).sorted { $0.0 < $1.0 })
        }
        for device in devices {
            add("\(device) latestHR", try await store.latestHRSampleTs(deviceId: device) as Any)
            add("\(device) firstScorable", try await store.firstScorableWhoop5RRTimestamp(deviceId: device) as Any)
            add("\(device) firstRecorded", try await store.firstRecordedRRTimestamp(deviceId: device) as Any)
            add("\(device) isWhoop5", try await store.isWhoop5RRSource(deviceId: device))
            add("\(device) rrRows", try await store.rrRowsWithChannelForTest(deviceId: device).map { "\($0.rrMs)/\($0.srcChannel as Any)" })
            add("\(device) suspect", try await store.rrSuspectRowsForTest(deviceId: device).map { "\($0.ts)/\($0.tsSuspect as Any)" })
            add("\(device) ord", try await store.rrOrdValuesForTest(deviceId: device, ts: start + 100))
            add("\(device) stepBefore", try await store.stepSampleBefore(deviceId: device, before: now - 3 * 86_400) as Any)
            add("\(device) stepBefore0", try await store.stepSampleBefore(deviceId: device, before: 0) as Any)
            add("\(device) page", try await store.stepSamplesPage(deviceId: device, afterExclusive: start + 500, endExclusive: now, limit: 300))
            let csv = try await store.exportRawCSV(deviceId: device, since: TimeInterval(csvSince))
            add("\(device) csv", try String(contentsOf: csv, encoding: .utf8))
            try? FileManager.default.removeItem(at: csv)
            for (from, to) in windows {
                let w = "\(device) [\(from), \(to)]"
                add("\(w) hrSamples", try await store.hrSamples(deviceId: device, from: from, to: to, limit: rowLimit))
                add("\(w) hrSamples 10", try await store.hrSamples(deviceId: device, from: from, to: to, limit: 10))
                add("\(w) hrFingerprint", try await store.hrFingerprint(deviceId: device, from: from, to: to))
                add("\(w) hasHr", try await store.hasHrInWindow(deviceId: device, from: from, to: to))
                add("\(w) gravityFingerprint", try await store.gravityFingerprint(deviceId: device, from: from, to: to))
                add("\(w) dayStream", try await store.dayStreamFingerprint(deviceId: device, from: from, to: to))
                add("\(w) hrWindowStats", try await store.hrWindowStats(primaryId: device, secondaryId: "w4", from: from, to: to))
                add("\(w) hrBuckets", try await store.hrBuckets(deviceId: device, from: from, to: to, bucketSeconds: 300))
                add("\(w) rr", try await store.rrIntervals(deviceId: device, from: from, to: to, limit: rowLimit))
                add("\(w) rr alias", try await store.rrIntervals(deviceId: device, from: from, to: to, limit: 777, unlabelledAliasOfWhoop5: true))
                add("\(w) rawRr", try await store.rawRrIntervals(deviceId: device, from: from, to: to, limit: rowLimit))
                add("\(w) withheld", try await store.legacyWhoop5RRWithheld(deviceId: device, from: from, to: to))
                add("\(w) skinTemp", try await store.skinTempSamples(deviceId: device, from: from, to: to, limit: rowLimit))
                add("\(w) steps", try await store.stepSamples(deviceId: device, from: from, to: to, limit: rowLimit))
                add("\(w) hasClasses", try await store.hasStepActivityClasses(deviceId: device, from: from, to: to))
                add("\(w) stepCoverage", try await store.stepTimestampCoverage(deviceId: device, from: from, to: to))
                add("\(w) motionCounts", try await store.stepDiagnosticMotionCounts(deviceId: device, from: from, to: to))
                add("\(w) presence", try await store.streamPresence(deviceId: device, from: from, to: to))
                add("\(w) gravity", try await store.gravitySamples(deviceId: device, from: from, to: to, limit: rowLimit))
                add("\(w) sleepState", try await store.sleepStateSamples(deviceId: device, from: from, to: to, limit: rowLimit))
                add("\(w) v18Aux", try await store.v18AuxSamples(deviceId: device, from: from, to: to, limit: rowLimit))
            }
        }
        out.append(contentsOf: try await revisionTable(store))
        return out
    }

    private func fnv(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }

    private func revisionTable(_ store: WhoopStore) async throws -> [String] {
        try await store.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT deviceId, day, revision FROM analysisRevision ORDER BY deviceId, day")
                .map { "revision \($0[0] as String) \($0[1] as Int) \($0[2] as Int)" }
        }
    }

    private func chunkCount(_ store: WhoopStore) async throws -> Int {
        try await store.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawChunk") ?? 0 }
    }

    private func diff(_ a: [String], _ b: [String]) -> [String] {
        guard a != b else { return [] }
        if a.count != b.count { return ["line count \(a.count) vs \(b.count)"] }
        return zip(a, b).filter { $0 != $1 }.prefix(5).map { "\(String($0.prefix(300)))\n  vs \(String($1.prefix(300)))" }
    }

    private func assertSame(_ plain: WhoopStore, _ sealed: WhoopStore, before: [String]? = nil,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let a = try await snapshot(plain)
        let b = try await snapshot(sealed)
        XCTAssertEqual(diff(a, b), [], file: file, line: line)
        if let before { XCTAssertEqual(diff(before, b), [], "against the snapshot taken before sealing", file: file, line: line) }
    }
}

/// SplitMix64: deterministic, so a failure reproduces.
private struct Rng {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) * 2 - 1 }
}
