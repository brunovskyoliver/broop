package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests Calories.estimateDayEnergy (its total) — the APPROXIMATE whole-day HR-only energy estimate
 * (Keytel active + Harris–Benedict BMR) that backs DailyMetric.activeKcalEst and the Today
 * Calories tile for BLE-only users. Pure-function tests; no DB. Not cloud/clinical parity.
 */
class DayCaloriesTest {

    private fun hrDay(bpm: Int, n: Int, start: Int = 0): List<com.noop.data.HrSample> =
        (0 until n).map { com.noop.data.HrSample(deviceId = "test", ts = (start + it).toLong(), bpm = bpm) }

    @Test
    fun dayCalories_emptyIsZero() {
        assertEquals(
            0.0,
            Calories.estimateDayEnergy(emptyList(), UserProfile(), hrmax = 190.0, restingHR = 55.0).totalKcal,
            1e-12,
        )
    }

    @Test
    fun dayEnergy_emptyComponentsAreZero() {
        val estimate = Calories.estimateDayEnergy(emptyList(), UserProfile(), hrmax = 190.0, restingHR = 55.0)
        assertEquals(0.0, estimate.restingKcal, 1e-12)
        assertEquals(0.0, estimate.activeKcal, 1e-12)
        assertEquals(0.0, estimate.totalKcal, 1e-12)
        assertEquals(0.0, estimate.observedSeconds, 1e-12)
    }

    @Test
    fun dayCalories_matchesBoutAtOneHz() {
        // At a steady 1 Hz stream the day and bout estimators agree exactly: the bout path's
        // elapsed-time weighting caps every ~1 s interval at 1 s, so it collapses to the day
        // path's flat one-second-per-sample. They diverge on gappy streams, but not here.
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val hr = hrDay(bpm = 130, n = 600) // 10 min above the active threshold, dense 1 Hz
        // Credited for the bout's own span: the day estimate otherwise adds BMR for the whole day.
        val day = Calories.estimateDayEnergy(hr, profile, hrmax = 185.0, restingHR = 55.0,
            creditedSeconds = 600.0).totalKcal
        val bout = Calories.estimateBoutCalories(hr, profile, hrmax = 185.0, restingHR = 55.0).first
        assertEquals(bout, day, 1e-9)
    }

    @Test
    fun gaplessOneHzDay_matchesLegacyTotal() {
        // Pin the pre-change 1 Hz result so the sparse-cadence fix cannot silently move WHOOP 4
        // totals. This mixed full day exercises both the resting floor and gross active rate.
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val block = 8 * 3_600
        val day = hrDay(55, block) + hrDay(130, block, block) + hrDay(70, block, 2 * block)
        val total = Calories.estimateDayEnergy(day, profile, hrmax = 185.0, restingHR = 55.0).totalKcal
        // Measured from the legacy estimator on main. Its per-sample summation differs from the
        // new R × N association by ~6.6e-9 kcal, so keep tolerance above that rounding noise.
        assertEquals("a gapless 1 Hz day must remain equal to the legacy estimator",
            6_774.323772067612, total, 1e-6)
    }

    @Test
    fun sparseHr_tracksElapsedTimeNotSampleCount() {
        // A 10-minute effort at a steady active HR, sampled two ways over the SAME ~600 s span:
        // densely at 1 Hz, and sparsely at one sample / 10 s (the WHOOP 5/MG case). Energy must
        // track elapsed time, so the sparse estimate lands close to the dense one — NOT ~1/10th
        // of it, as the old one-second-per-sample count produced. (BOUT path only.)
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val dense = (0 until 600).map { com.noop.data.HrSample(deviceId = "t", ts = it.toLong(), bpm = 130) }
        val sparse = (0 until 600 step 10).map { com.noop.data.HrSample(deviceId = "t", ts = it.toLong(), bpm = 130) }
        val denseKcal = Calories.estimateBoutCalories(dense, profile, hrmax = 185.0, restingHR = 55.0).first
        val sparseKcal = Calories.estimateBoutCalories(sparse, profile, hrmax = 185.0, restingHR = 55.0).first
        assertEquals("sparse HR must be counted over elapsed time, not undercounted per sample",
            denseKcal, sparseKcal, denseKcal * 0.05)
        // Teeth: a per-sample count (60 samples) would be ~1/10th of the dense total.
        assertTrue(sparseKcal > denseKcal * 0.5)
    }

    @Test
    fun sparseDayCalories_trackElapsedTimeNotSampleCount() {
        // The daily path must be cadence-invariant too: WHOOP 5/MG's ~30 s HR and a 1 Hz
        // stream over the same ten active minutes represent the same elapsed work.
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val dense = (0 until 600).map { com.noop.data.HrSample(deviceId = "t", ts = it.toLong(), bpm = 130) }
        val sparse = (0 until 600 step 30).map { com.noop.data.HrSample(deviceId = "t", ts = it.toLong(), bpm = 130) }
        val denseEnergy = Calories.estimateDayEnergy(dense, profile, hrmax = 185.0, restingHR = 55.0)
        val sparseEnergy = Calories.estimateDayEnergy(sparse, profile, hrmax = 185.0, restingHR = 55.0)
        assertEquals(600.0, sparseEnergy.observedSeconds, 1e-12)
        assertEquals(denseEnergy.restingKcal, sparseEnergy.restingKcal, 1e-9)
        assertEquals(denseEnergy.activeKcal, sparseEnergy.activeKcal, 1e-9)
        assertEquals(denseEnergy.totalKcal, sparseEnergy.totalKcal, 1e-9)
    }

    @Test
    fun dayEnergy_parityVectorOracle() {
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val vectors = listOf(
            hrDay(55, 86_400),
            (0 until 600).map { com.noop.data.HrSample(deviceId = "t", ts = it.toLong(), bpm = 130) },
            (0 until 600 step 30).map { com.noop.data.HrSample(deviceId = "t", ts = it.toLong(), bpm = 130) },
            listOf(
                com.noop.data.HrSample(deviceId = "t", ts = 0L, bpm = 130),
                com.noop.data.HrSample(deviceId = "t", ts = 3600L, bpm = 130),
            ),
        ).map { Calories.estimateDayEnergy(it, profile, hrmax = 185.0, restingHR = 55.0) }
        // Generated by the Swift twin's testDayEnergyParityVectorOracle. BMR covers the whole span.
        val expected = listOf(
            doubleArrayOf(1825.247000000000, 0.000000000000, 1825.247000000000, 86_400.0),
            doubleArrayOf(1825.247000000000, 103.105766084605, 1928.352766084605, 600.0),
            doubleArrayOf(1825.247000000000, 103.105766084603, 1928.352766084603, 600.0),
            doubleArrayOf(1825.247000000000, 20.621153216921, 1845.868153216921, 120.0),
        )
        vectors.zip(expected).forEach { (value, oracle) ->
            assertEquals(oracle[0], value.restingKcal, 1e-9)
            assertEquals(oracle[1], value.activeKcal, 1e-9)
            assertEquals(oracle[2], value.totalKcal, 1e-9)
            assertEquals(oracle[3], value.observedSeconds, 1e-9)
        }
    }

    @Test
    fun wearGap_isCappedNotCreditedInFull() {
        // Two active samples an hour apart must NOT credit a full hour of active burn — the
        // per-sample interval is capped at mergeGapS (150 s). The pre-gap sample contributes
        // 150 s and the tail 1 s, so the total equals a 151 s continuous equivalent, not 3600 s.
        // (BOUT path only.)
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val gapped = listOf(
            com.noop.data.HrSample(deviceId = "t", ts = 0L, bpm = 130),
            com.noop.data.HrSample(deviceId = "t", ts = 3600L, bpm = 130),
        )
        val cappedEquiv = (0..150).map { com.noop.data.HrSample(deviceId = "t", ts = it.toLong(), bpm = 130) }
        val gappedKcal = Calories.estimateBoutCalories(gapped, profile, hrmax = 185.0, restingHR = 55.0).first
        val equivKcal = Calories.estimateBoutCalories(cappedEquiv, profile, hrmax = 185.0, restingHR = 55.0).first
        assertEquals("an inter-sample gap must be capped at mergeGapS, not credited in full",
            equivKcal, gappedKcal, equivKcal * 0.001)
    }

    @Test
    fun dayPath_capsRestingAndActiveGap() {
        // Two isolated high readings must not claim the whole hour as either resting or active
        // energy. With the 60 s carry cap, both components cover exactly 120 supported seconds.
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val gapped = listOf(
            com.noop.data.HrSample(deviceId = "t", ts = 0L, bpm = 130),
            com.noop.data.HrSample(deviceId = "t", ts = 3600L, bpm = 130),
        )
        val gapEnergy = Calories.estimateDayEnergy(gapped, profile, hrmax = 185.0, restingHR = 55.0)
        val shortEnergy = Calories.estimateDayEnergy(hrDay(130, 120), profile, hrmax = 185.0, restingHR = 55.0)
        val continuousEnergy = Calories.estimateDayEnergy(hrDay(130, 3660), profile, hrmax = 185.0, restingHR = 55.0)
        assertEquals(120.0, gapEnergy.observedSeconds, 1e-12)
        assertEquals("a long gap must carry only 120 capped resting seconds",
            shortEnergy.restingKcal, gapEnergy.restingKcal, 1e-9)
        assertEquals("a long gap must carry only 120 capped active seconds",
            shortEnergy.activeKcal, gapEnergy.activeKcal, 1e-9)
        assertEquals(shortEnergy.totalKcal, gapEnergy.totalKcal, 1e-9)
        assertTrue("a sensor gap must not be treated as continuous exercise",
            gapEnergy.totalKcal < continuousEnergy.totalKcal)
    }

    @Test
    fun dayCalories_restingDayIsLowerThanActiveDay() {
        // A whole day at resting HR burns far less than the same length all-active day,
        // and the resting-day total is positive (BMR floor).
        val profile = UserProfile(weightKg = 70.0, heightCm = 170.0, age = 30.0, sex = "nonbinary")
        // Day activeThreshold = 55 + 0.50*(185-55) = 120 bpm; 60 < 120 (resting), 150 >= 120 (active).
        val restingDay = Calories.estimateDayEnergy(hrDay(60, 3600), profile, hrmax = 185.0, restingHR = 55.0).totalKcal
        val activeDay = Calories.estimateDayEnergy(hrDay(150, 3600), profile, hrmax = 185.0, restingHR = 55.0).totalKcal
        assertTrue("resting day must burn > 0 (BMR floor)", restingDay > 0.0)
        assertTrue("active day must exceed resting day", activeDay > restingDay)
    }

    @Test
    fun dayCalories_sedentaryFullDayApproximatesBMR() {
        // A full 24 h at resting HR (below the day active gate) must total ≈ the subject's BMR:
        // the day estimator floors every sub-threshold second at the resting metabolic rate, so
        // an all-rest day is BMR by construction. Standard male test subject's revised
        // Harris–Benedict BMR ≈ 1825 kcal. This is an APPROXIMATE estimate, not medical advice.
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val sedentary = hrDay(55, 86_400) // 24 h, all at resting HR
        val total = Calories.estimateDayEnergy(sedentary, profile, hrmax = 185.0, restingHR = 55.0).totalKcal
        assertEquals("a sedentary full day must total ≈ the subject's BMR (~1825 kcal)",
            1825.25, total, 1.0)
    }

    @Test
    fun dayCalories_lightActivityDayIsFarBelowOldInflatedTotal() {
        // The bug: at the OLD 30% day gate (~94 bpm for this subject) ordinary low-intensity
        // daytime HR (~100 bpm walking/standing) was credited the FULL Keytel gross-exercise
        // rate, inflating the day total by ~1000+ kcal. The 50% day gate (120 bpm) now treats
        // that HR as resting, so a realistic mixed light day (8 h sleep @55, 8 h sedentary @70,
        // 8 h light activity @100) collapses toward BMR instead of the old runaway figure.
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val block = 8 * 3_600
        val lightDay = hrDay(55, block) + hrDay(70, block, block) + hrDay(100, block, 2 * block)
        val total = Calories.estimateDayEnergy(lightDay, profile, hrmax = 185.0, restingHR = 55.0).totalKcal
        // NEW total ≈ 1825 kcal (every second below the 120 bpm gate → BMR floor).
        assertEquals("a light-activity day must land near BMR, not the old inflated total",
            1825.25, total, 1.0)
        // Teeth: the OLD 30%-gate model credited the 8 h @100 bpm block at the full Keytel active
        // rate (~3551 kcal for that block alone), so the old day total was ≈ 4768 kcal. Pin that
        // we are now WELL below it (more than 2000 kcal lower).
        assertTrue("the light-activity day must drop far below the old inflated ~4768 kcal",
            total < 4768.0 - 2000.0)
    }

    @Test
    fun analyzeDay_caloriesIgnoreAdjacentDayHr() {
        // analyzeDay must filter HR to the target UTC day before summing calories — the
        // IntelligenceEngine read window spans ~42h, so adjacent-day HR must NOT inflate the
        // day's activeKcalEst (the critical "full-window double-count" regression).
        val day = "2026-01-02"
        val noon = 1_767_355_200L // 2026-01-02T12:00:00Z
        fun hr(tsOffsetSec: Long, bpm: Int) =
            com.noop.data.HrSample(deviceId = "t", ts = noon + tsOffsetSec, bpm = bpm)
        val inDay = (0 until 600).map { hr(it.toLong(), 120) }
        // Same in-day HR plus 600 samples ~36h earlier (a different UTC day, inside the window).
        val withAdjacent = inDay + (0 until 600).map { hr(-36L * 3_600 - it, 120) }
        val a = AnalyticsEngine.analyzeDay(day = day, hr = inDay, profile = UserProfile()).daily.activeKcalEst
        val b = AnalyticsEngine.analyzeDay(day = day, hr = withAdjacent, profile = UserProfile()).daily.activeKcalEst
        assertNotNull(a)
        assertNotNull(b)
        assertEquals("adjacent-day HR must not change the day's calories", a!!, b!!, 1e-6)
    }

    @Test
    fun analyzeDay_dayHrCoversFullCalendarDay() {
        // Simulate the past-day clip: the night-window HR only reaches midday; the full calendar-day
        // HR also has the afternoon. activeKcalEst must use dayHr when supplied, so the full-day total
        // exceeds the clipped night-window total (the past-day undercount fix).
        val day = "2026-01-02"
        val noon = 1_767_355_200L // 2026-01-02T12:00:00Z
        fun hr(tsOffsetSec: Long, bpm: Int) =
            com.noop.data.HrSample(deviceId = "t", ts = noon + tsOffsetSec, bpm = bpm)
        // 160 bpm: above the active gate, so the afternoon adds energy beyond the whole-day BMR both carry.
        val nightWindow = (0 until 600).map { hr(it.toLong(), 160) }
        val fullDay = nightWindow + (0 until 600).map { hr(3L * 3_600 + it, 160) }
        val clipped = AnalyticsEngine.analyzeDay(day = day, hr = nightWindow, profile = UserProfile()).daily.activeKcalEst
        val full = AnalyticsEngine.analyzeDay(
            day = day, hr = nightWindow, dayHr = fullDay, profile = UserProfile(),
        ).daily.activeKcalEst
        assertNotNull(clipped)
        assertNotNull(full)
        assertTrue("full calendar-day calories must exceed the clipped night-window total", full!! > clipped!!)
    }

    @Test
    fun analyzeDay_dayHrNullFallsBackToWindowHr() {
        // With no calendar-day stream, the total falls back to the window `hr` — identical to passing
        // that same window explicitly as dayHr (the (dayHr ?: hr) fallback).
        val day = "2026-01-02"
        val noon = 1_767_355_200L
        fun hr(tsOffsetSec: Long, bpm: Int) =
            com.noop.data.HrSample(deviceId = "t", ts = noon + tsOffsetSec, bpm = bpm)
        val window = (0 until 600).map { hr(it.toLong(), 120) }
        val fallback = AnalyticsEngine.analyzeDay(day = day, hr = window, profile = UserProfile()).daily.activeKcalEst
        val explicit = AnalyticsEngine.analyzeDay(day = day, hr = window, dayHr = window, profile = UserProfile()).daily.activeKcalEst
        assertNotNull(fallback)
        assertNotNull(explicit)
        assertEquals(fallback!!, explicit!!, 1e-9)
    }

    /**
     * A dropout in an otherwise dense day adds no ACTIVE energy, and RESTING is the same whole-day BMR.
     *
     * Active duration is capped at the inferred cadence (1 s here), so the two dense blocks credit
     * exactly as much active energy as one continuous block of the same sample count — no magic
     * number, just the invariant. Metabolism continues across a gap, exercise is not evidenced by one.
     * Capping active at 60 s instead would have credited the reading before the gap with a full minute
     * of exercise it never demonstrated. Twin of the Swift test.
     */
    @Test
    fun dropoutInADenseDayCarriesRestingButNotActive() {
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val gapped = hrDay(130, 120, start = 0) + hrDay(130, 120, start = 200)   // 81 s dropout
        val continuous = hrDay(130, 240)
        val g = Calories.estimateDayEnergy(gapped, profile, hrmax = 185.0, restingHR = 55.0)
        val c = Calories.estimateDayEnergy(continuous, profile, hrmax = 185.0, restingHR = 55.0)
        assertEquals("active energy must not grow across a sensor gap", c.activeKcal, g.activeKcal, 1e-9)
        assertEquals("BMR does not depend on what the strap saw", c.restingKcal, g.restingKcal, 1e-9)
        assertTrue("coverage counts only to the observed-gap cap", g.observedSeconds < 240.0 + 81.0)
    }

    /**
     * Two readings in the same second are reachable — `hrSample` is keyed (deviceId, ts) and the day
     * feed unions devices, so a two-strap day has one per strap. Only the LAST of a tied run receives
     * the interval, so without a tiebreak the day's active energy depended on the order the feed
     * happened to arrive in, and on a sort stability Swift does not guarantee.
     *
     * Pinned twice: the result must not depend on input order, and a tie must hand the interval to the
     * LOWER reading (so a lone elevated duplicate cannot claim the following minute as exercise).
     */
    @Test
    fun tiedTimestampsAreOrderIndependentAndResolveToTheLowerReading() {
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val tied = listOf(
            com.noop.data.HrSample(deviceId = "a", ts = 0L, bpm = 150),
            com.noop.data.HrSample(deviceId = "b", ts = 0L, bpm = 60),
            com.noop.data.HrSample(deviceId = "b", ts = 60L, bpm = 60),
        )
        val forward = Calories.estimateDayEnergy(tied, profile, hrmax = 185.0, restingHR = 55.0)
        val reversed = Calories.estimateDayEnergy(tied.reversed(), profile, hrmax = 185.0, restingHR = 55.0)
        assertEquals("feed order must not change the day's energy", forward.activeKcal, reversed.activeKcal, 1e-12)
        assertEquals(forward.restingKcal, reversed.restingKcal, 1e-12)
        assertEquals("the tie resolves to the lower reading, so no active energy is credited",
            0.0, forward.activeKcal, 1e-12)
    }

    /**
     * The awake-anchored day gate and the whole-span BMR. Expected rows generated by the Swift twin
     * `DayCaloriesTests.testDayEnergyAnchorOracle` and pasted verbatim. `zeroAwake` and `vo2Only` must
     * equal `none`: a measured VO2max is read only beside an awake HR.
     */
    @Test
    fun dayEnergy_anchorOracle() {
        fun run(bpm: Int, n: Int, step: Int = 1, start: Int = 0) =
            (0 until n step step).map { com.noop.data.HrSample(deviceId = "t", ts = (start + it).toLong(), bpm = bpm) }
        val inputs = mapOf(
            "walk1Hz" to run(110, 3600), "walk30s" to run(110, 3600, 30),
            "mixed" to run(90, 1200) + run(110, 1200, start = 1200) + run(150, 1200, start = 2400),
        )
        val base = UserProfile(weightKg = 66.0, heightCm = 170.0, age = 19.0, sex = "male")
        fun profile(name: String) = when (name) {
            "awake" -> base.copy(awakeRestingHR = 67.0)
            "awakeVo2" -> base.copy(awakeRestingHR = 67.0, vo2max = 41.86)
            "zeroAwake" -> base.copy(awakeRestingHR = 0.0, vo2max = 41.86)
            "vo2Only" -> base.copy(vo2max = 41.86)
            else -> base
        }
        val expected = """
            none|walk1Hz|nil|1680.531000000|0.000000000|3600.000000000
            none|walk30s|nil|1680.531000000|0.000000000|3600.000000000
            none|mixed|nil|1680.531000000|242.204188894|3600.000000000
            none|mixed|50000|972.529513889|242.204188894|3600.000000000
            awake|walk1Hz|nil|1680.531000000|260.980016777|3600.000000000
            awake|walk30s|nil|1680.531000000|260.980016777|3600.000000000
            awake|mixed|nil|1680.531000000|295.210387220|3600.000000000
            awakeVo2|walk1Hz|nil|1680.531000000|245.909136950|3600.000000000
            awakeVo2|walk30s|nil|1680.531000000|245.909136950|3600.000000000
            awakeVo2|mixed|nil|1680.531000000|285.163134003|3600.000000000
            awakeVo2|mixed|50000|972.529513889|285.163134003|3600.000000000
            zeroAwake|mixed|nil|1680.531000000|242.204188894|3600.000000000
            vo2Only|mixed|nil|1680.531000000|242.204188894|3600.000000000
        """.trimIndent()
        val cases = listOf(
            Triple("none", "walk1Hz", null),
            Triple("none", "walk30s", null),
            Triple("none", "mixed", null),
            Triple("none", "mixed", 50000.0),
            Triple("awake", "walk1Hz", null),
            Triple("awake", "walk30s", null),
            Triple("awake", "mixed", null),
            Triple("awakeVo2", "walk1Hz", null),
            Triple("awakeVo2", "walk30s", null),
            Triple("awakeVo2", "mixed", null),
            Triple("awakeVo2", "mixed", 50000.0),
            Triple("zeroAwake", "mixed", null),
            Triple("vo2Only", "mixed", null),
        )
        fun f(x: Double) = String.format(java.util.Locale.ROOT, "%.9f", x)
        val rows = cases.map { (p, i, credited) ->
            val e = Calories.estimateDayEnergy(inputs.getValue(i), profile(p), hrmax = 194.7, restingHR = 48.0,
                creditedSeconds = credited)
            listOf(p, i, credited?.toInt()?.toString() ?: "nil", f(e.restingKcal), f(e.activeKcal), f(e.observedSeconds))
                .joinToString("|")
        }
        assertEquals(expected, rows.joinToString("\n"))
    }

    @Test
    fun awakeAnchor_isAWholeBpmPriorMedianOrNull() {
        val floors: List<Double?> = listOf(64.0, 66.0, null, 63.0, 120.7, 65.0, 64.0, 113.5, 66.0)
        assertEquals(65.5, Calories.awakeRestingHR(floors)!!, 0.0)
        assertEquals(66.0, EnergyAnchors.awakeAnchor(floors)!!, 0.0)
        assertEquals(null, EnergyAnchors.awakeAnchor(listOf(64.0, null)))
        val today = java.time.LocalDate.parse("2026-11-18")
        val stored = mapOf(
            "2026-11-04" to mapOf(StressMonitor.wakeFloorKey to 60.0),
            "2026-11-17" to mapOf(StressMonitor.wakeFloorKey to 62.0),
            "2026-11-18" to mapOf(StressMonitor.wakeFloorKey to 118.6),
        )
        val prior = EnergyAnchors.priorFloors(today, stored)
        assertEquals(14, prior.size)
        assertEquals(60.0, prior.first()!!, 0.0)
        assertEquals("today's own floor is not a prior", 62.0, prior.last()!!, 0.0)
    }
}
