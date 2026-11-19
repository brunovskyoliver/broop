package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Parity for [DayCycleResolver.uncoveredDays]. The expected lines are the verbatim stdout of a Swift oracle
 * that calls `DayCycleResolver.uncoveredDays` from `Packages/StrandAnalytics` over the same inputs: two real
 * sleepless-night shapes (strap on the charger 2026-11-09, awake all night 2026-11-14), edge cases, and a
 * 40-case sweep from an LCG this test reproduces bit for bit. The Swift side pins the same behaviour in
 * `DayCycleTests`.
 */
class DayCycleUncoveredDaysParityTest {
    private fun w(id: String, onset: Long, day: String) = DayCycleResolver.WakeDayBoundary(id, onset, day)

    private fun run(name: String, boundaries: List<DayCycleResolver.WakeDayBoundary>, now: Long, offset: Long) =
        "$name:" + DayCycleResolver.uncoveredDays(boundaries, now, offset)
            .joinToString(",") { "${it.day}@${it.onset}<${it.splitFrom}" }

    private var x: Long = 0x9E3779B97F4A7C15uL.toLong()
    private fun next(bound: Int): Int {
        x = x * 6_364_136_223_846_793_005L + 1_442_695_040_888_963_407L
        return ((x ushr 33) % bound.toLong()).toInt()
    }

    @Test fun matchesTheSwiftOracle() {
        val out = ArrayList<String>()
        out += run("charger", listOf(w("a", 1_794_001_906, "2026-11-07"), w("b", 1_794_089_757, "2026-11-08"),
            w("c", 1_794_264_049, "2026-11-10"), w("d", 1_794_344_183, "2026-11-11")), 1_794_394_583, 3_600)
        out += run("awake", listOf(w("a", 1_794_434_096, "2026-11-12"), w("b", 1_794_525_825, "2026-11-13"),
            w("c", 1_794_695_304, "2026-11-15"), w("d", 1_794_777_173, "2026-11-16")), 1_794_827_573, 3_600)
        out += run("openTail", listOf(w("a", 1_794_089_757, "2026-11-08")), 1_794_350_000, 3_600)
        out += run("unordered", listOf(w("c", 1_794_264_049, "2026-11-10"), w("b", 1_794_089_757, "2026-11-08"),
            w("b", 1_794_089_757, "2026-11-08")), 1_794_300_000, 3_600)
        out += run("malformed", listOf(w("x", 0, "bogus")), 1_794_300_000, 3_600)
        out += run("future", listOf(w("x", 1_794_300_001, "2026-11-12")), 1_794_300_000, 3_600)
        val offsets = listOf(3_600L, -18_000L, 19_800L, 0L, 7_200L)
        val base = 1_793_491_200L // 2026-11-01T00:00Z
        for (index in 0 until 40) {
            val offset = offsets[next(offsets.size)]
            var dayIndex = 0
            val boundaries = ArrayList<DayCycleResolver.WakeDayBoundary>()
            for (k in 0 until 1 + next(5)) {
                dayIndex += 1 + next(3)
                val midnight = base + dayIndex * 86_400L - offset
                val onset = midnight - 4 * 3_600L + next(12 * 3_600)
                boundaries += w("b$k", onset, AnalyticsEngine.dayString(midnight, offset))
            }
            val now = boundaries.last().onset + 1 + next(72 * 3_600)
            out += run("lcg$index", boundaries, now, offset)
        }
        assertEquals(EXPECTED.joinToString("\n"), out.joinToString("\n"))
    }

    /** Splitting only adds seams: windows still tile first onset → now, and each day owns one window. */
    @Test fun splitWindowsTileTheSpanWithoutOverlap() {
        val boundaries = listOf(w("b", 1_794_089_757, "2026-11-08"), w("c", 1_794_264_049, "2026-11-10"),
            w("d", 1_794_525_825, "2026-11-13"), w("e", 1_794_695_304, "2026-11-15"))
        val now = 1_794_695_304L + 30 * 3_600
        val uncovered = DayCycleResolver.uncoveredDays(boundaries, now, 3_600)
        val all = boundaries.map { PhysiologicalSteps.CycleBoundary(it.sleepId, it.onset) } +
            uncovered.map { PhysiologicalSteps.CycleBoundary(it.sleepId, it.onset) }
        val windows = PhysiologicalSteps.cycleWindows(all, now)
        assertEquals(1_794_089_757L, windows.first().onset)
        assertEquals(now, windows.last().endExclusive)
        windows.zipWithNext().forEach { (a, b) -> assertEquals(a.endExclusive, b.onset) }
        assertEquals(listOf("2026-11-09", "2026-11-11", "2026-11-12", "2026-11-14"), uncovered.map { it.day })
    }

    private companion object {
        val EXPECTED = listOf(
            "charger:2026-11-09@1794178800<b",
            "awake:2026-11-14@1794610800<b",
            "openTail:2026-11-09@1794178800<a",
            "unordered:2026-11-09@1794178800<b",
            "malformed:",
            "future:",
            "lcg0:2026-11-04@1793743200<b0,2026-11-07@1794002400<b2,2026-11-08@1794088800<b2",
            "lcg1:2026-11-05@1793836800<b0",
            "lcg2:2026-11-05@1793854800<b0,2026-11-07@1794027600<b1,2026-11-08@1794114000<b1,2026-11-10@1794286800<b2,2026-11-11@1794373200<b2,2026-11-14@1794632400<b4",
            "lcg3:2026-11-05@1793817000<b0,2026-11-06@1793903400<b0,2026-11-09@1794162600<b2",
            "lcg4:2026-11-05@1793854800<b0,2026-11-07@1794027600<b1",
            "lcg5:",
            "lcg6:2026-11-03@1793656800<b0,2026-11-04@1793743200<b0,2026-11-06@1793916000<b1,2026-11-07@1794002400<b1",
            "lcg7:",
            "lcg8:2026-11-06@1793923200<b3,2026-11-07@1794009600<b3",
            "lcg9:2026-11-05@1793817000<b0,2026-11-06@1793903400<b0,2026-11-08@1794076200<b1,2026-11-09@1794162600<b1,2026-11-11@1794335400<b2",
            "lcg10:",
            "lcg11:2026-11-06@1793919600<b1,2026-11-07@1794006000<b1",
            "lcg12:2026-11-03@1793664000<b0,2026-11-04@1793750400<b0,2026-11-07@1794009600<b2,2026-11-08@1794096000<b2",
            "lcg13:2026-11-04@1793730600<b1,2026-11-05@1793817000<b1,2026-11-07@1793989800<b2,2026-11-09@1794162600<b3,2026-11-11@1794335400<b4,2026-11-12@1794421800<b4",
            "lcg14:2026-11-04@1793768400<b0,2026-11-05@1793854800<b0,2026-11-07@1794027600<b1,2026-11-09@1794200400<b2,2026-11-10@1794286800<b2",
            "lcg15:2026-11-06@1793941200<b2,2026-11-07@1794027600<b2,2026-11-10@1794286800<b4,2026-11-11@1794373200<b4",
            "lcg16:2026-11-03@1793660400<b0,2026-11-04@1793746800<b0,2026-11-06@1793919600<b1",
            "lcg17:2026-11-06@1793919600<b1",
            "lcg18:2026-11-05@1793833200<b0,2026-11-06@1793919600<b0,2026-11-08@1794092400<b1,2026-11-09@1794178800<b1",
            "lcg19:2026-11-06@1793923200<b1,2026-11-07@1794009600<b1,2026-11-10@1794268800<b3",
            "lcg20:2026-11-05@1793833200<b0,2026-11-06@1793919600<b0,2026-11-08@1794092400<b1",
            "lcg21:2026-11-07@1794027600<b2,2026-11-08@1794114000<b2,2026-11-10@1794286800<b3,2026-11-12@1794459600<b4",
            "lcg22:2026-11-05@1793833200<b1,2026-11-07@1794006000<b2",
            "lcg23:",
            "lcg24:",
            "lcg25:2026-11-05@1793833200<b0,2026-11-07@1794006000<b1",
            "lcg26:2026-11-04@1793730600<b1",
            "lcg27:2026-11-05@1793829600<b0",
            "lcg28:2026-11-03@1793644200<b0,2026-11-04@1793730600<b0,2026-11-06@1793903400<b1,2026-11-07@1793989800<b1,2026-11-09@1794162600<b2,2026-11-11@1794335400<b3,2026-11-12@1794421800<b3",
            "lcg29:2026-11-03@1793656800<b0,2026-11-04@1793743200<b0,2026-11-07@1794002400<b2,2026-11-08@1794088800<b2",
            "lcg30:2026-11-05@1793833200<b1,2026-11-07@1794006000<b2,2026-11-08@1794092400<b2",
            "lcg31:2026-11-03@1793656800<b0",
            "lcg32:2026-11-03@1793644200<b0,2026-11-04@1793730600<b0,2026-11-06@1793903400<b1,2026-11-07@1793989800<b1",
            "lcg33:2026-11-04@1793730600<b0,2026-11-06@1793903400<b1,2026-11-08@1794076200<b2",
            "lcg34:2026-11-05@1793829600<b0",
            "lcg35:2026-11-03@1793644200<b0,2026-11-05@1793817000<b1,2026-11-06@1793903400<b1",
            "lcg36:2026-11-06@1793941200<b1,2026-11-07@1794027600<b1",
            "lcg37:2026-11-05@1793833200<b0,2026-11-06@1793919600<b0,2026-11-08@1794092400<b1",
            "lcg38:",
            "lcg39:2026-11-03@1793664000<b0,2026-11-04@1793750400<b0,2026-11-07@1794009600<b2",
        )
    }
}
