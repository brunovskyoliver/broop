package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Twin of Swift WorkoutAutoSaveTests. [EXPECTED_GRID] is the SAME literal the Swift test asserts (its
 * `expectedGrid`), produced by running the Swift `WorkoutAutoSave.verdict` over every threshold either
 * side of it: one character per case, 'S' strength, 'R' run, 'C' cycle, '.' suggest.
 */
class WorkoutAutoSaveTest {

    private fun grid(): String {
        val out = StringBuilder()
        for (durS in listOf(1199L, 1200L)) for (cov in listOf(69.9, 70.0)) for (hrr in listOf(39.9, 40.0))
            for (cls in listOf(CoarseWorkoutClass.STRENGTH, CoarseWorkoutClass.OTHER, CoarseWorkoutClass.WALK,
                               CoarseWorkoutClass.SKI, CoarseWorkoutClass.RUN, CoarseWorkoutClass.CYCLE))
                for (str in listOf(0.39, 0.40)) for (mv in listOf(0.079, 0.08)) for (conf in listOf(0.39, 0.40))
                    for (tier in listOf(true, false)) {
                        val s = ExerciseSession(
                            start = 0, end = durS, avgHR = 120.0, peakHR = 150, strain = null,
                            durationS = durS.toDouble(), zoneTimePct = emptyMap(), avgHRRPct = hrr, hrmax = 195.0,
                            hrmaxSource = "caller", caloriesKcal = null, caloriesKJ = null,
                            hrCoveragePct = cov, isActivityTier = tier,
                        )
                        val f = WorkoutClassFeatures(
                            durationSec = durS.toDouble(), meanHR = 120.0, peakHR = 150, meanHRRPct = hrr,
                            hrCV = 0.1, stillFraction = 0.7, walkFraction = 0.3, runFraction = 0.0,
                            tickCoverage = 1.0, motionVariance = mv, motionCV = 1.0, kcalPerMin = 7.0,
                        )
                        val p = WorkoutClassPrediction(predictedClass = cls, confidence = conf,
                                                       scores = mapOf(CoarseWorkoutClass.STRENGTH to str))
                        out.append(when (WorkoutAutoSave.verdict(s, f, p).token) {
                            "strength" -> 'S'; "run" -> 'R'; "cycle" -> 'C'; else -> '.'
                        })
                    }
        return out.toString()
    }

    @Test
    fun verdictsMatchTheSwiftOracle() {
        val g = grid()
        assertEquals(768, g.length)
        assertEquals(EXPECTED_GRID, g)
    }

    @Test
    fun aWalkIsNeverSavedAndALiftIs() {
        val s = ExerciseSession(start = 0, end = 2700, avgHR = 116.0, peakHR = 150, strain = 9.0, durationS = 2700.0,
            zoneTimePct = emptyMap(), avgHRRPct = 46.0, hrmax = 195.0, hrmaxSource = "caller", caloriesKcal = 350.0,
            caloriesKJ = 1464.0, hrCoveragePct = 100.0, isActivityTier = true)
        val f = WorkoutClassFeatures(durationSec = 2700.0, meanHR = 116.0, peakHR = 150, meanHRRPct = 46.0, hrCV = 0.1,
            stillFraction = 0.7, walkFraction = 0.3, runFraction = 0.0, tickCoverage = 1.0, motionVariance = 0.1,
            motionCV = 1.0, kcalPerMin = 7.0)
        fun p(c: CoarseWorkoutClass) = WorkoutClassPrediction(c, 0.9, mapOf(CoarseWorkoutClass.STRENGTH to 0.55))
        assertEquals("strength", WorkoutAutoSave.verdict(s, f, p(CoarseWorkoutClass.OTHER)).token)
        assertEquals(null, WorkoutAutoSave.verdict(s, f, p(CoarseWorkoutClass.WALK)).token)
        assertEquals(null, WorkoutAutoSave.verdict(s, null, null).token)
    }

    private companion object {
        const val EXPECTED_GRID =
            "................................................................" +
            "................................................................" +
            "................................................................" +
            "................................................................" +
            "................................................................" +
            "................................................................" +
            "................................................................" +
            "................................................................" +
            "................................................................" +
            "................................................................" +
            "............................................SSSS............SSSS" +
            "...................................R...R...R...R...C...C...C...C"
    }
}
