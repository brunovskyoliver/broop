import Foundation

/// Charger state of a WHOOP strap at a moment, from the strap's own charger EDGE events.
///
/// The WHOOP 5.0/MG BATTERY_LEVEL event carries no charging bit NOOP can read (see `decodeWhoop5Event`):
/// on a real 5/MG every one of 3,980 events read 0 at the offset 4.0 uses +4, through 85 charge sessions in
/// which SoC climbed about 1 % per 30 s. The strap does report the edges: CHARGING_ON(7) / CHARGING_OFF(8).
/// Replayed over that strap's whole history, "the latest edge at or before the sample" marked 1,199
/// ten-minute intervals as charging, and SoC rose in all of them (median +60 %/h); the rest fell (median
/// -1.6 %/h).
///
/// BATTERY_PACK_REMOVED(22) also clears charging: nothing charges once the pack is off. Its partner
/// BATTERY_PACK_CONNECTED(21) is NOT read: it means a pack was attached, not that charging began, and a
/// depleted pack raises 21 without ever raising 7. BOOT(15) clears the state: after a reboot the strap has
/// said nothing yet about its charger. No edge at all, or none since a boot, gives nil, never false. Twin of
/// Kotlin `com.noop.protocol.ChargerState`.
public enum ChargerState {
    /// One stored event the resolver reads: its RTC timestamp and its rendered kind, e.g. "CHARGING_ON(7)".
    public struct Edge: Equatable, Sendable {
        public let ts: Int
        public let kind: String
        public init(ts: Int, kind: String) { self.ts = ts; self.kind = kind }
    }

    /// Event-kind prefixes the resolver reads, for the store's SQL filter. Kinds are rendered with their
    /// number ("CHARGING_ON(7)"), so callers match on the prefix.
    public static let kindPrefixes = ["CHARGING_ON", "CHARGING_OFF", "BATTERY_PACK_REMOVED", "BOOT"]

    /// The state an edge sets (nil for BOOT, which clears it), and its order among edges in one second:
    /// a boot first, then a pack removal, then a charging edge, so the charging edge has the last word.
    static func effect(_ kind: String) -> (charging: Bool?, rank: Int)? {
        // "BOOT(" rather than "BOOT": the schema may later name events that only start with it.
        if kind.hasPrefix("BOOT(") || kind == "BOOT" { return (nil, 0) }
        if kind.hasPrefix("BATTERY_PACK_REMOVED") { return (false, 1) }
        if kind.hasPrefix("CHARGING_ON") { return (true, 2) }
        if kind.hasPrefix("CHARGING_OFF") { return (false, 2) }
        return nil
    }

    /// Fill each sample's missing `charging` from the latest edge at or before its timestamp. A sample that
    /// already carries a value (a WHOOP 4.0 reads its own bit) keeps it. `edges` may be in any order and
    /// may include unrelated kinds, which are ignored.
    public static func resolve(_ samples: [BatterySample], edges: [Edge]) -> [BatterySample] {
        guard samples.contains(where: { $0.charging == nil }) else { return samples }
        let ordered = edges.compactMap { e in effect(e.kind).map { (ts: e.ts, charging: $0.charging, rank: $0.rank) } }
            .sorted { $0.ts != $1.ts ? $0.ts < $1.ts : $0.rank < $1.rank }
        guard !ordered.isEmpty else { return samples }
        // Walk the samples in time order, keeping the caller's order in the result.
        let order = samples.indices.sorted { samples[$0].ts < samples[$1].ts }
        var out = samples
        var next = 0
        var state: Bool? = nil
        for i in order {
            let s = samples[i]
            while next < ordered.count, ordered[next].ts <= s.ts {
                state = ordered[next].charging
                next += 1
            }
            if s.charging == nil, let state {
                out[i] = BatterySample(ts: s.ts, soc: s.soc, mv: s.mv, charging: state)
            }
        }
        return out
    }
}
