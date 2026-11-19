import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    /// The charger-edge filter, shared by both reads below. Kinds are rendered with their number
    /// ("CHARGING_ON(7)"), so they are matched by prefix; `ChargerState` ignores anything else that matches.
    /// One prefix per `ChargerState.kindPrefixes` entry (pinned by a test), written out so the Kotlin
    /// `WhoopDao.CHARGER_EDGE_FILTER` can be compared with it literally.
    static let chargerEdgeFilter = "(kind LIKE 'CHARGING_ON%' OR kind LIKE 'CHARGING_OFF%' OR kind LIKE 'BATTERY_PACK_REMOVED%' OR kind LIKE 'BOOT%')"

    /// `samples` with each missing `charging` filled from the device's stored charger edges: the latest at or
    /// before the batch's first sample, and every one inside the batch. Run inside the insert transaction,
    /// after the batch's events are written. A batch whose samples all carry a bit reads nothing.
    /// Kotlin twin: `WhoopRepository.withChargerState`.
    static func withChargerState(_ db: Database, deviceId: String,
                                 _ samples: [BatterySample]) throws -> [BatterySample] {
        guard samples.contains(where: { $0.charging == nil }),
              let from = samples.map(\.ts).min(), let to = samples.map(\.ts).max() else { return samples }
        func edges(_ sql: String, _ args: [any DatabaseValueConvertible]) throws -> [ChargerState.Edge] {
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map {
                ChargerState.Edge(ts: $0["ts"], kind: $0["kind"])
            }
        }
        let prior = try edges("""
            SELECT ts, kind FROM event WHERE deviceId = ? AND ts < ? AND \(chargerEdgeFilter)
            ORDER BY ts DESC LIMIT 8
            """, [deviceId, from])
        let inBatch = try edges("""
            SELECT ts, kind FROM event WHERE deviceId = ? AND ts >= ? AND ts <= ? AND \(chargerEdgeFilter)
            """, [deviceId, from, to])
        // `prior` keeps several rows so a same-second pair (CHARGING_ON beside BATTERY_PACK_CONNECTED)
        // still resolves by rank; only its newest second matters.
        let newest = prior.first?.ts
        return ChargerState.resolve(samples, edges: prior.filter { $0.ts == newest } + inBatch)
    }
}
