package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.StepSample

/**
 * WorkoutAutoSave — which detected sessions are saved as workouts without asking.
 *
 * Twin of Swift `StrandAnalytics.WorkoutAutoSave` (same constants, same verdicts; pinned by the Swift
 * oracle literal in WorkoutAutoSaveTest). See the Swift file for why each threshold sits where it does.
 * Pure: no clock, no I/O.
 */
object WorkoutAutoSave {
    /** Shortest session saved without asking. */
    const val minDurationS: Long = 20 * 60
    /** Share of the session's minutes holding an HR reading. */
    const val minHRCoveragePct = 70.0
    /** Mean %HRR the session must average: the detector's activity floor as a percentage. */
    const val minAvgHRRPct = 40.0
    /** Gravity-delta variance that marks lifting (lifts read 0.08–0.13). */
    const val minLiftMotionVariance = 0.08
    /** Classifier confidence a run or ride needs. */
    const val minCardioConfidence = 0.40

    /** [token] is the class saved as `suggestedClass` ("strength"/"run"/"cycle"); null = suggest. */
    data class Verdict(val token: String?) {
        val save: Boolean get() = token != null
    }

    fun verdict(s: ExerciseSession, features: WorkoutClassFeatures?, prediction: WorkoutClassPrediction?): Verdict {
        val suggest = Verdict(null)
        if (s.end - s.start < minDurationS || (s.hrCoveragePct ?: 0.0) < minHRCoveragePct ||
            (s.avgHRRPct ?: 0.0) < minAvgHRRPct || features == null || prediction == null
        ) return suggest
        return when (prediction.predictedClass) {
            CoarseWorkoutClass.STRENGTH, CoarseWorkoutClass.OTHER ->
                if ((prediction.scores[CoarseWorkoutClass.STRENGTH] ?: 0.0) >= WorkoutTypeClassifier.minPlausibleScore &&
                    features.motionVariance >= minLiftMotionVariance
                ) Verdict(CoarseWorkoutClass.STRENGTH.raw) else suggest
            CoarseWorkoutClass.RUN, CoarseWorkoutClass.CYCLE ->
                if (prediction.confidence >= minCardioConfidence && !s.isActivityTier) Verdict(prediction.predictedClass.raw)
                else suggest
            else -> suggest
        }
    }

    /** The classifier's view of one session over the streams `detect` was given (Swift `classify`). */
    fun classify(
        s: ExerciseSession, hr: List<HrSample>, gravity: List<GravitySample>, steps: List<StepSample>, restingHR: Double?,
    ): Pair<WorkoutClassFeatures?, WorkoutClassPrediction?> {
        val f = WorkoutTypeFeatureExtractor.extract(
            hr = hr, gravity = gravity, steps = steps, start = s.start, end = s.end,
            restingHR = restingHR, maxHR = s.hrmax, caloriesKcal = s.caloriesKcal,
        ) ?: return null to null
        return f to WorkoutTypeClassifier.classify(f)
    }
}
