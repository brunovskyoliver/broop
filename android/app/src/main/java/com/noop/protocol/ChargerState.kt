package com.noop.protocol

import com.noop.data.BatteryRow

/**
 * Charger state of a WHOOP strap at a moment, from the strap's own charger EDGE events.
 *
 * The WHOOP 5.0/MG BATTERY_LEVEL event carries no charging bit NOOP can read (see
 * `Framing.decodeEventWhoop5`): on a real 5/MG every one of 3,980 events read 0 at the offset 4.0 uses +4,
 * through 85 charge sessions in which SoC climbed about 1 % per 30 s. The strap does report the edges:
 * CHARGING_ON(7) / CHARGING_OFF(8). Replayed over that strap's whole history, "the latest edge at or before
 * the sample" marked 1,199 ten-minute intervals as charging, and SoC rose in all of them (median +60 %/h);
 * the rest fell (median -1.6 %/h).
 *
 * BATTERY_PACK_REMOVED(22) also clears charging. Its partner BATTERY_PACK_CONNECTED(21) is NOT read: it
 * means a pack was attached, not that charging began, and a depleted pack raises 21 without ever raising 7.
 * BOOT(15) clears the state: after a reboot the strap has said nothing yet about its charger. No edge at
 * all, or none since a boot, gives null, never false. Twin of Swift `ChargerState`.
 */
object ChargerState {
    /** One stored event the resolver reads: its RTC timestamp and rendered kind, e.g. "CHARGING_ON(7)". */
    data class Edge(val ts: Long, val kind: String)

    /** Event-kind prefixes the resolver reads, for the store's SQL filter. */
    val kindPrefixes = listOf("CHARGING_ON", "CHARGING_OFF", "BATTERY_PACK_REMOVED", "BOOT")

    private data class Effect(val charging: Boolean?, val rank: Int)

    /**
     * The state an edge sets (null charging for BOOT, which clears it), and its order among edges in one
     * second: a boot first, then a pack removal, then a charging edge, so the charging edge has the last word.
     */
    private fun effect(kind: String): Effect? = when {
        kind.startsWith("BOOT(") || kind == "BOOT" -> Effect(null, 0)
        kind.startsWith("BATTERY_PACK_REMOVED") -> Effect(false, 1)
        kind.startsWith("CHARGING_ON") -> Effect(true, 2)
        kind.startsWith("CHARGING_OFF") -> Effect(false, 2)
        else -> null
    }

    /**
     * Fill each sample's missing `charging` from the latest edge at or before its timestamp. A sample that
     * already carries a value (a WHOOP 4.0 reads its own bit) keeps it. Order of either list is free.
     */
    fun resolve(samples: List<BatteryRow>, edges: List<Edge>): List<BatteryRow> {
        if (samples.none { it.charging == null }) return samples
        val ordered = edges.mapNotNull { e -> effect(e.kind)?.let { Triple(e.ts, it.charging, it.rank) } }
            .sortedWith(compareBy<Triple<Long, Boolean?, Int>> { it.first }.thenBy { it.third })
        if (ordered.isEmpty()) return samples
        val out = samples.toMutableList()
        var next = 0
        var state: Boolean? = null
        for (i in samples.indices.sortedBy { samples[it].ts }) {
            val s = samples[i]
            while (next < ordered.size && ordered[next].first <= s.ts) {
                state = ordered[next].second
                next++
            }
            if (s.charging == null && state != null) out[i] = s.copy(charging = state)
        }
        return out
    }
}
