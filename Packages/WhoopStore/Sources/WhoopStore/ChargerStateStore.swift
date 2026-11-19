import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    /// The charger-edge filter, shared by both reads below. Kinds are rendered with their number
    /// ("CHARGING_ON(7)"), so they are matched by prefix; `ChargerState` ignores anything else that matches.
    static let chargerEdgeFilter = ChargerState.kindPrefixes.map { _ in "kind LIKE ?" }.joined(separator: " OR ")
    static var chargerEdgeArguments: [String] { ChargerState.kindPrefixes.map { $0 + "%" } }

    /// `samples` with each missing `charging` filled from the device's stored charger edges: the latest at or
    /// before the batch's first sample, and every one inside the batch. Run inside the insert transaction,
    /// after the batch's events are written. A batch whose samples all carry a bit reads nothing.
    static func withChargerState(_ db: Database, deviceId: String,
                                 _ samples: [BatterySample]) throws -> [BatterySample] {
        guard samples.contains(where: { $0.charging == nil }),
              let from = samples.map(\.ts).min(), let to = samples.map(\.ts).max() else { return samples }
        func edges(_ sql: String, _ args: [DatabaseValueConvertible]) throws -> [ChargerState.Edge] {
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map {
                ChargerState.Edge(ts: $0["ts"], kind: $0["kind"])
            }
        }
        let prior = try edges("""
            SELECT ts, kind FROM event WHERE deviceId = ? AND ts < ? AND (\(chargerEdgeFilter))
            ORDER BY ts DESC LIMIT 8
            """, [deviceId, from] + chargerEdgeArguments)
        let inBatch = try edges("""
            SELECT ts, kind FROM event WHERE deviceId = ? AND ts >= ? AND ts <= ? AND (\(chargerEdgeFilter))
            """, [deviceId, from, to] + chargerEdgeArguments)
        // `prior` keeps several rows so a same-second pair (CHARGING_ON beside BATTERY_PACK_CONNECTED)
        // still resolves by rank; only its newest second matters.
        let newest = prior.first?.ts
        return ChargerState.resolve(samples, edges: prior.filter { $0.ts == newest } + inBatch)
    }
}
