package com.noop.ui

import android.content.Context
import com.noop.analytics.StepsCounter
import com.noop.analytics.WorkoutAutoSave
import com.noop.analytics.WorkoutDetector
import com.noop.data.DailyMetric
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.ingest.ActivityFileImporter
import com.noop.ingest.LiftingImporter
import kotlinx.coroutines.flow.first
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * WorkoutAutoDetect — workout detection for the suggestion card and the auto-save pass (2026-11-18).
 *
 * Twin of the iOS `Repository` section of the same name (`detectWorkouts`, `autoDetectCandidates`,
 * `runWorkoutAutoSave`): [WorkoutDetector] one local day at a time over the last week, each day with
 * its own resting HR, classified and judged by [WorkoutAutoSave]. A session that clears the bar is
 * saved as a manual row under the class it was saved as (`suggestedClass` stays on the row, marking it
 * as the detector's own) and its span goes into a ledger, so a row the wearer later deletes is never
 * saved or suggested again. Everything else is a suggestion for [SUGGESTION_LIFETIME_DAYS].
 */
object WorkoutAutoDetect {

    /** How long a suggestion stays on the card, and how far back the daily full scan looks. */
    const val SUGGESTION_LIFETIME_DAYS = 7
    /** Hours past midnight each day's chunk also reads, so a session that crosses midnight is whole. */
    const val DETECTION_TAIL_S = 6L * 3_600L

    /** One detected session with everything Save stores. Twin of Swift `DetectedWorkout`. */
    data class Suggestion(
        val startSec: Long,
        val endSec: Long,
        val avgBpm: Int,
        val peakBpm: Int,
        val durationMin: Int,
        val energyKcal: Double? = null,
        val strain: Double? = null,
        val zonesJSON: String? = null,
        val steps: Int? = null,
        val suggestedClass: String? = null,
        val suggestedClassConfidence: Double? = null,
    )

    /** One session with its auto-save verdict: the token it is saved under, else null. */
    data class Detection(val suggestion: Suggestion, val autoSaveToken: String?)

    /** Per-day results, keyed by the chunk start, valid while the chunk's inputs are unchanged. */
    private val cache = ConcurrentHashMap<Long, Pair<String, List<Detection>>>()

    private fun overlaps(a: Long, b: Long, c: Long, d: Long) = a < d && c < b

    /** The stored sport for a class token, in English (a storage token cross-source dedup compares). */
    fun sportFor(token: String?): String? = when (token) {
        "walk" -> "Walking"
        "run" -> "Running"
        "strength" -> "Strength Training"
        "cycle" -> "Cycling"
        "ski" -> "Skiing"
        else -> null
    }

    /** The manual row Save (or the auto-save) stores for [s]. Twin of Swift `WorkoutSource.buildRow(fromSuggestion:)`. */
    fun buildRow(s: Suggestion, deviceId: String, nowSec: Long = System.currentTimeMillis() / 1000L): WorkoutRow? {
        val r = WorkoutEditing.buildManualRowFromSpan(
            deviceId = deviceId, startSeconds = s.startSec, endSeconds = s.endSec,
            sport = sportFor(s.suggestedClass) ?: "Workout", avgHr = s.avgBpm, energyKcal = s.energyKcal,
            nowSeconds = nowSec,
        ) ?: return null
        return r.copy(maxHr = s.peakBpm, strain = s.strain, zonesJSON = s.zonesJSON, steps = s.steps,
                      suggestedClass = s.suggestedClass, suggestedClassConfidence = s.suggestedClassConfidence)
    }

    /**
     * Open suggestions, newest first: settled (may no longer grow), and overlapping no saved row, no
     * dismissal and no earlier auto-save. Twin of Swift `Repository.selectAutoDetectCandidates`.
     */
    fun selectOpen(
        detections: List<Detection>, savedSpans: List<Pair<Long, Long>>, blockedSpans: List<Pair<Long, Long>>,
        nowSec: Long,
    ): List<Suggestion> = detections.map { it.suggestion }
        .filter { c ->
            c.endSec <= nowSec - WorkoutDetector.stitchMaxGapS &&
                blockedSpans.none { overlaps(c.startSec, c.endSec, it.first, it.second) } &&
                savedSpans.none { overlaps(c.startSec, c.endSec, it.first, it.second) }
        }
        .sortedByDescending { it.startSec }

    /** The detections a pass should save now, oldest first. Twin of Swift `Repository.selectAutoSaves`. */
    fun selectAutoSaves(
        detections: List<Detection>, savedSpans: List<Pair<Long, Long>>, blockedSpans: List<Pair<Long, Long>>,
        nowSec: Long,
    ): List<Detection> {
        val out = ArrayList<Detection>()
        for (d in detections.sortedBy { it.suggestion.startSec }) {
            val w = d.suggestion
            if (d.autoSaveToken == null || w.endSec > nowSec - WorkoutDetector.stitchMaxGapS) continue
            if (blockedSpans.any { overlaps(w.startSec, w.endSec, it.first, it.second) }) continue
            if (savedSpans.any { overlaps(w.startSec, w.endSec, it.first, it.second) }) continue
            if (out.any { overlaps(w.startSec, w.endSec, it.suggestion.startSec, it.suggestion.endSec) }) continue
            out.add(d)
        }
        return out
    }

    /** Every saved workout window of any source, cross-source deduped (what the Workouts list shows). */
    suspend fun savedRows(repo: WhoopRepository, deviceId: String, from: Long, to: Long): List<WorkoutRow> =
        mergeAutoDetectSavedRows(
            whoopRows = repo.workoutsUnion(deviceId, from, to),
            computedRows = repo.detectedWorkoutsUnion(deviceId, from, to),
            appleRows = repo.workouts("apple-health", from, to),
            healthConnectRows = repo.workouts("health-connect", from, to),
            liftingRows = repo.workouts(LiftingImporter.SOURCE_ID, from, to),
            activityFileRows = repo.workouts(ActivityFileImporter.SOURCE_ID, from, to),
        )

    /** Dismissals of both stores plus the ledger, as spans. */
    suspend fun blockedSpans(context: Context, repo: WhoopRepository, deviceId: String): List<Pair<Long, Long>> =
        AutoWorkoutPrefs.spans(AutoWorkoutPrefs.dismissed(context)) +
            AutoWorkoutPrefs.spans(AutoWorkoutPrefs.autoSaved(context)) +
            repo.dismissedDetectedUnion(deviceId).map { it.startTs to it.endTs }

    /**
     * Every session [WorkoutDetector] finds in the last [daysBack] days, oldest first, one local day at a
     * time. Day by day because the stream reads are capped and a week in one read would drop the newest
     * days, and because that is the shape WorkoutBench replays. PURE READ.
     */
    suspend fun detect(
        context: Context, repo: WhoopRepository, deviceId: String, daysBack: Int,
        nowSec: Long = System.currentTimeMillis() / 1000L, days: List<DailyMetric>,
    ): List<Detection> {
        if (!NoopPrefs.autoDetectWorkouts(context)) return emptyList()
        val profileStore = ProfileStore.from(context)
        val profile = profileStore.toUserProfile()
        val maxHR = profileStore.hrMax.takeIf { it > 0 }?.toDouble()
        val method = NoopPrefs.effortMethod(context)
        val zone = ZoneId.systemDefault()
        val kept = ArrayList<Detection>()
        var day = Instant.ofEpochSecond(nowSec - daysBack * 86_400L).atZone(zone).toLocalDate()
        val today = Instant.ofEpochSecond(nowSec).atZone(zone).toLocalDate()
        while (!day.isAfter(today)) {
            val dayStart = day.atStartOfDay(zone).toEpochSecond()
            val nextDay = day.plusDays(1).atStartOfDay(zone).toEpochSecond()
            val key = day.toString()
            day = day.plusDays(1)
            val to = minOf(nowSec, nextDay + DETECTION_TAIL_S)
            val hr = repo.hrSamplesUnion(deviceId, dayStart, to, limit = 200_000)
            if (hr.size < 2) continue
            val gravity = repo.gravitySamplesUnion(deviceId, dayStart, to, limit = 200_000)
            val steps = repo.stepSamples(deviceId, dayStart, to, limit = 200_000)
                .ifEmpty { repo.stepSamples("my-whoop", dayStart, to, limit = 200_000) }
            val rest = days.lastOrNull { it.day <= key && it.restingHr != null }?.restingHr?.toDouble()
            val cacheKey = "${to - dayStart}:${hr.size}:${hr.last().ts}:${gravity.size}:${steps.size}:" +
                "${rest ?: -1}:${maxHR ?: -1}:${profile.cacheKey}:$method"
            val hit = cache[dayStart]
            val found = if (hit != null && hit.first == cacheKey) hit.second else {
                WorkoutDetector.detect(hr, gravity, restingHR = rest, maxHR = maxHR,
                                       age = if (profile.age > 0) profile.age else null, profile = profile,
                                       effortMethod = method, steps = steps)
                    .filter { it.start >= dayStart && it.start < nextDay }
                    .map { s ->
                        val (features, prediction) = WorkoutAutoSave.classify(s, hr, gravity, steps, rest)
                        val cls = prediction?.predictedClass?.raw?.takeIf { it != "other" }
                        val checked = s.copy(suggestedClass = cls, suggestedClassConfidence = prediction?.confidence)
                        val ticks = StepsCounter.stepsInWindow(steps.filter { it.ts >= s.start && it.ts <= s.end })
                        val count = ticks?.let { (it.toDouble() / max(profile.stepTicksPerStep, 0.5)).roundToInt() }
                        Detection(
                            Suggestion(
                                startSec = s.start, endSec = s.end, avgBpm = s.avgHR.roundToInt(), peakBpm = s.peakHR,
                                durationMin = ((s.end - s.start) / 60).toInt(), energyKcal = s.caloriesKcal,
                                strain = s.strain, zonesJSON = WorkoutDetector.zonesJSON(s.zoneTimePct),
                                steps = count?.takeIf { it > 0 }, suggestedClass = cls,
                                suggestedClassConfidence = prediction?.confidence,
                            ),
                            WorkoutAutoSave.verdict(checked, features, prediction).token,
                        )
                    }
                    .also { cache[dayStart] = cacheKey to it }
            }
            for (d in found) {
                if (kept.none { overlaps(it.suggestion.startSec, it.suggestion.endSec, d.suggestion.startSec, d.suggestion.endSec) }) kept.add(d)
            }
        }
        val oldest = nowSec - (daysBack + 1) * 86_400L
        cache.keys.removeAll { it < oldest }
        return kept
    }

    /** Open suggestions for the card, newest first. Twin of Swift `autoDetectCandidates`. */
    suspend fun openSuggestions(
        context: Context, repo: WhoopRepository, deviceId: String, days: List<DailyMetric>,
        daysBack: Int = SUGGESTION_LIFETIME_DAYS,
    ): List<Suggestion> {
        val now = System.currentTimeMillis() / 1000L
        val detections = detect(context, repo, deviceId, daysBack, now, days)
        if (detections.isEmpty()) return emptyList()
        val saved = savedRows(repo, deviceId, now - (daysBack + 1) * 86_400L, now).map { it.startTs to it.endTs }
        return selectOpen(detections, saved, blockedSpans(context, repo, deviceId), now)
    }

    /**
     * One analysis pass: save every confident session that is due, then return what was saved and the
     * suggestions still open. The first pass of each local day covers the whole suggestion lifetime.
     * Twin of Swift `Repository.runWorkoutAutoSave` + the daily full scan in `WorkoutDetectedNotifier`.
     */
    suspend fun runAutoSave(
        context: Context, repo: WhoopRepository, deviceId: String, days: List<DailyMetric>,
    ): Pair<List<WorkoutRow>, List<Suggestion>> {
        if (!NoopPrefs.autoDetectWorkouts(context)) return emptyList<WorkoutRow>() to emptyList()
        val now = System.currentTimeMillis() / 1000L
        val today = LocalDate.now(ZoneId.systemDefault()).toEpochDay()
        val fullScan = AutoWorkoutPrefs.fullScanDay(context) != today
        val daysBack = if (fullScan) SUGGESTION_LIFETIME_DAYS else 2
        val detections = detect(context, repo, deviceId, daysBack, now, days)
        if (fullScan) AutoWorkoutPrefs.setFullScanDay(context, today)
        if (detections.isEmpty()) return emptyList<WorkoutRow>() to emptyList()
        val savedSpans = ArrayList(savedRows(repo, deviceId, now - (daysBack + 1) * 86_400L, now).map { it.startTs to it.endTs })
        val due = selectAutoSaves(detections, savedSpans, blockedSpans(context, repo, deviceId), now)
        val saved = ArrayList<WorkoutRow>()
        for (d in due) {
            val row = buildRow(d.suggestion.copy(suggestedClass = d.autoSaveToken), deviceId, now) ?: continue
            // The ledger first: if the write fails, a later pass still never saves the span twice.
            AutoWorkoutPrefs.recordAutoSaved(context, row.startTs, row.endTs)
            repo.saveManualWorkout(row)
            saved.add(row)
            savedSpans.add(row.startTs to row.endTs)
        }
        return saved to selectOpen(detections, savedSpans, blockedSpans(context, repo, deviceId), now)
    }

    /** Notification Save: re-resolve the suggestion by its span and save it as the card would. */
    suspend fun saveSuggestion(context: Context, repo: WhoopRepository, deviceId: String, startTs: Long, endTs: Long): Boolean {
        val days = repo.recentDaysMergedFlow(deviceId).first()
        val s = openSuggestions(context, repo, deviceId, days).firstOrNull { overlaps(it.startSec, it.endSec, startTs, endTs) }
            ?: return false
        val row = buildRow(s, deviceId) ?: return false
        repo.saveManualWorkout(row)
        return true
    }

    /**
     * Notification Delete on an auto-saved workout: delete the manual row still carrying its class over
     * the span, and dismiss the span. A row the wearer has since edited carries no class and is left alone.
     */
    suspend fun deleteAutoSaved(context: Context, repo: WhoopRepository, deviceId: String, startTs: Long, endTs: Long) {
        for (r in repo.workoutsUnion(deviceId, startTs - 86_400L, endTs + 86_400L)) {
            if (r.source.lowercase() == "manual" && r.suggestedClass != null && overlaps(r.startTs, r.endTs, startTs, endTs)) {
                repo.deleteWorkout(r)
            }
        }
        AutoWorkoutPrefs.dismissSpan(context, startTs, endTs)
    }
}
