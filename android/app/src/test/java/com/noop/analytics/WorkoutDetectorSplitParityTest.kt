package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.StepSample
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 2026-11-18: the Kotlin [WorkoutDetector] splits and stitches exactly as the Swift one does: elevated
 * cores, walking-streak pieces, the grip-dropout bridge and the funnel line that reports them.
 *
 * The expected text is the verbatim stdout of a Swift oracle that runs `WorkoutDetector.detect` from
 * Packages/StrandAnalytics over the same fixtures (the shape of WorkoutDetectorTests' `movingDay`), so a
 * one-sided edit on either platform fails here or in the Swift suite. Session bounds are relative to the
 * fixture start; `a` = activity tier, `w` = cleared the zone-2 bar; avg10 = 10 x mean HR, rounded.
 */
class WorkoutDetectorSplitParityTest {
    private val dev = "test-device"

    private data class Day(val hr: List<HrSample>, val grav: List<GravitySample>, val steps: List<StepSample>?)

    private fun day(
        start: Long, segs: List<Pair<Int, Int>>, gait: Set<Int>? = null, holeAfter: Long? = null, holeS: Long = 0,
    ): Day {
        var hr = ArrayList<HrSample>()
        var grav = ArrayList<GravitySample>()
        val bounds = ArrayList<Pair<Long, Long>>()
        var t = start - 600
        repeat(600) { hr.add(HrSample(dev, t, 55)); grav.add(GravitySample(deviceId = dev, ts = t, x = 0.0, y = 0.0, z = 1.0)); t++ }
        for ((dur, bpm) in segs) {
            bounds.add(t to t + dur)
            repeat(dur) {
                hr.add(HrSample(dev, t, bpm))
                grav.add(GravitySample(deviceId = dev, ts = t, x = (t % 2).toDouble() * 0.5, y = 0.0, z = 1.0)); t++
            }
        }
        repeat(600) { hr.add(HrSample(dev, t, 55)); grav.add(GravitySample(deviceId = dev, ts = t, x = 0.0, y = 0.0, z = 1.0)); t++ }
        if (holeAfter != null) {
            val hole = (start + holeAfter) until (start + holeAfter + holeS)
            hr = ArrayList(hr.filter { it.ts !in hole })
            grav = ArrayList(grav.map { if (it.ts in hole) GravitySample(deviceId = dev, ts = it.ts, x = 0.0, y = 0.0, z = 1.0) else it })
        }
        if (gait == null) return Day(hr, grav, null)
        val steps = grav.map { g ->
            val walking = bounds.indices.any { it in gait && g.ts >= bounds[it].first && g.ts < bounds[it].second }
            StepSample(deviceId = dev, ts = g.ts, counter = 0, activityClass = if (walking) 1 else 0)
        }
        return Day(hr, grav, steps)
    }

    private val liftSets = List(10) { listOf(150 to 125, 90 to 95) }.flatten()
    private val lone = List(10) { listOf(100 to 125, 140 to 95) }.flatten()

    @Test
    fun splitsAndStitchesLikeTheSwiftDetector() {
        val fixtures = listOf(
            Triple("diluted", 9_000_000L, day(9_000_000L, listOf(3000 to 90) + liftSets + listOf(3000 to 90))),
            Triple("walkToGym", 11_000_000L, day(11_000_000L, listOf(900 to 118) + liftSets, gait = setOf(0))),
            Triple("walkWithStop", 12_000_000L, day(12_000_000L, listOf(1200 to 118, 180 to 118, 1200 to 118), gait = setOf(0, 2))),
            Triple("dropout480", 14_000_000L, day(14_000_000L, liftSets + listOf(480 to 125) + liftSets, gait = emptySet(), holeAfter = 2400, holeS = 480)),
            Triple("dropout720", 15_000_000L, day(15_000_000L, liftSets + listOf(720 to 125) + liftSets, gait = emptySet(), holeAfter = 2400, holeS = 720)),
            Triple("loneLift", 10_500_000L, day(10_500_000L, lone)),
            Triple("liftWalkLift", 16_000_000L, day(16_000_000L, liftSets + listOf(600 to 112) + liftSets, gait = setOf(1))),
        )
        val out = ArrayList<String>()
        for ((name, start, d) in fixtures) {
            var f: WorkoutDetector.DetectionFunnel? = null
            val s = WorkoutDetector.detect(d.hr, d.grav, restingHR = 60.0, maxHR = 190.0, funnel = { f = it }, steps = d.steps)
            out.add("$name: " + s.joinToString(", ") {
                "${it.start - start}..${it.end - start}${if (it.isActivityTier) "a" else "w"} avg10=${Math.round(it.avgHR * 10)} peak=${it.peakHR}"
            })
            out.add("  " + WorkoutDetector.detectionFunnelLine(name, f!!))
        }
        assertEquals(SWIFT_ORACLE.joinToString("\n"), out.joinToString("\n"))
    }

    private companion object {
        val SWIFT_ORACLE = listOf(
            "diluted: 3000..5309a avg10=1145 peak=125",
            "  workout detect day=diluted hr=9600 motion=9600 restHR=60 floor=75 motionOK=8402 hrMissing=0 hrTooLow=7 active=8395 runs=1 bridged=1 longestRunS=8394 meanRunS=8394 short=0 noHR=0 lowIntensity=0 kept=1 activity=1 split=1 splitKept=1 splitDropped=0",
            "walkToGym: 0..899a avg10=1180 peak=118, 900..3299a avg10=1138 peak=125",
            "  workout detect day=walkToGym hr=4500 motion=4500 restHR=60 floor=75 motionOK=3307 hrMissing=0 hrTooLow=7 active=3300 runs=1 bridged=1 longestRunS=3299 meanRunS=3299 short=0 noHR=0 lowIntensity=0 kept=2 activity=2 split=1 splitKept=2 splitDropped=0",
            "walkWithStop: 0..2579a avg10=1180 peak=118",
            "  workout detect day=walkWithStop hr=3780 motion=3780 restHR=60 floor=75 motionOK=2587 hrMissing=0 hrTooLow=7 active=2580 runs=1 bridged=1 longestRunS=2579 meanRunS=2579 short=0 noHR=0 lowIntensity=0 kept=1 activity=1 split=0 splitKept=0 splitDropped=0",
            "dropout480: 5..5279a avg10=1137 peak=125",
            "  workout detect day=dropout480 hr=6000 motion=6480 restHR=60 floor=75 motionOK=4804 hrMissing=2 hrTooLow=7 active=4795 runs=2 bridged=2 longestRunS=2399 meanRunS=2396 short=0 noHR=0 lowIntensity=0 kept=1 activity=1 split=0 splitKept=0 splitDropped=0",
            "dropout720: 5..2404a avg10=1137 peak=125, 3125..5519a avg10=1137 peak=125",
            "  workout detect day=dropout720 hr=6000 motion=6720 restHR=60 floor=75 motionOK=4804 hrMissing=2 hrTooLow=7 active=4795 runs=2 bridged=2 longestRunS=2399 meanRunS=2396 short=0 noHR=0 lowIntensity=0 kept=2 activity=2 split=0 splitKept=0 splitDropped=0",
            "loneLift: ",
            "  workout detect day=loneLift hr=3600 motion=3600 restHR=60 floor=75 motionOK=2402 hrMissing=0 hrTooLow=7 active=2395 runs=1 bridged=1 longestRunS=2394 meanRunS=2394 short=0 noHR=0 lowIntensity=0 kept=0 activity=0 split=1 splitKept=0 splitDropped=1",
            "liftWalkLift: 5..5399a avg10=1135 peak=125",
            "  workout detect day=liftWalkLift hr=6600 motion=6600 restHR=60 floor=75 motionOK=5402 hrMissing=0 hrTooLow=7 active=5395 runs=1 bridged=1 longestRunS=5394 meanRunS=5394 short=0 noHR=0 lowIntensity=0 kept=1 activity=1 split=0 splitKept=0 splitDropped=0",
        )
    }
}
