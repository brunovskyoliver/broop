package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.noop.analytics.AutoWorkoutDetector
import com.noop.analytics.AutoWorkoutDetectorTrace
import com.noop.data.DailyMetric
import com.noop.data.WorkoutRow
import com.noop.ingest.ActivityFileImporter
import com.noop.ingest.LiftingImporter
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/**
 * AutoWorkoutNudge — the NON-DESTRUCTIVE "looks like a workout" Today card (MVP auto-detect, opt-in).
 *
 * Android twin of the iOS suggestion card. Gated on [NoopPrefs.autoDetectWorkouts] — when off, NOTHING runs
 * and nothing renders. When on, after Today appears (and whenever the data refreshes) it reads the open
 * suggestions from [WorkoutAutoDetect] (the last week of [com.noop.analytics.WorkoutDetector] sessions,
 * minus saved, dismissed and auto-saved spans; 2026-11-18) and surfaces ONE card — the most recent:
 *
 *   "Looks like a workout around <start>–<end> (avg HR <avg>, <dur> min). Save it?"
 *
 * SAVE → [WorkoutAutoDetect.buildRow]: a manual row over the window with the detector's figures, under the
 * suggested sport. DISMISS (× or "Not a workout") → records the window in [AutoWorkoutPrefs]; filtering
 * matches every dismissal store by overlap. The card itself never creates a workout without Save; confident
 * sessions are saved by the analysis pass ([WorkoutAutoDetect.runAutoSave]), not here.
 *
 * Design-Reset compliant: a flat accent-tinted [NoopCard], NoopMetrics tokens, no gold — matching the
 * other Today cards (matches the iOS source exactly).
 */

/** Days of HR history the Test Centre shadow diagnostics cover (the card itself covers
 *  [WorkoutAutoDetect.SUGGESTION_LIFETIME_DAYS]). */
private const val AUTO_DETECT_DAYS_BACK = 2L

/**
 * Compose the same saved-workout source set the Workouts screen/Swift `workoutRows()` expose, then apply
 * the shared cross-source duplicate collapse once. The WHOOP arguments are already natural-key-deduped by
 * [com.noop.data.WhoopRepository.workoutsUnion] / `detectedWorkoutsUnion`; this final pass collapses a
 * physical activity mirrored by another provider without hiding distinct sessions.
 */
internal fun mergeAutoDetectSavedRows(
    whoopRows: List<WorkoutRow>,
    computedRows: List<WorkoutRow>,
    appleRows: List<WorkoutRow>,
    healthConnectRows: List<WorkoutRow>,
    liftingRows: List<WorkoutRow>,
    activityFileRows: List<WorkoutRow>,
): List<WorkoutRow> = WorkoutEditing.dedupCrossSource(
    whoopRows + computedRows + appleRows + healthConnectRows + liftingRows + activityFileRows,
)

/** Shadow ground truth is the already-deduped saved set, excluding legacy detector output. */
internal fun autoDetectLabelledSpans(savedRows: List<WorkoutRow>): List<Pair<Long, Long>> =
    savedRows
        .filter { WorkoutEditing.classify(it.source) != WorkoutSource.DETECTED }
        .map { it.startTs to it.endTs }

/** Compare the published baseline with every proposed shadow alternative in stable order. */
internal fun autoDetectShadowPolicies(): List<Double> =
    (AutoWorkoutDetector.shadowSustainedMinutes + AutoWorkoutDetector.minSustainedMin)
        .distinct()
        .sorted()

private sealed interface AutoWorkoutDay {
    data object Today : AutoWorkoutDay
    data object Yesterday : AutoWorkoutDay
    data class OnDate(val epochSec: Long) : AutoWorkoutDay
}

private fun autoWorkoutDay(epochSec: Long): AutoWorkoutDay {
    val zone = ZoneId.systemDefault()
    val day = Instant.ofEpochSecond(epochSec).atZone(zone).toLocalDate()
    val today = LocalDate.now(zone)
    return when (day) {
        today -> AutoWorkoutDay.Today
        today.minusDays(1) -> AutoWorkoutDay.Yesterday
        else -> AutoWorkoutDay.OnDate(epochSec)
    }
}

@Composable
fun AutoWorkoutNudgeCard(
    viewModel: AppViewModel,
    days: List<DailyMetric>,
) {
    val context = LocalContext.current
    val locale = LocalConfiguration.current.locales[0]
    // Read once — SharedPreferences isn't reactive; when off, the whole feature is invisible + inert.
    val enabled = remember { NoopPrefs.autoDetectWorkouts(context) }
    if (!enabled) return

    // The single surfaced candidate (null = nothing to suggest). Re-scanned whenever the day data grows.
    var candidate by remember { mutableStateOf<WorkoutAutoDetect.Suggestion?>(null) }
    // Hide immediately on Save/X without waiting for the next reload (mirrors iOS `handledThisSession`).
    var handledThisSession by remember { mutableStateOf(false) }

    // Re-scan after Today appears / when the data refreshes (days = the recompute trigger; the Android
    // analog of the iOS refreshSeq). All reads + detection run off the main thread. Mirrors `reload()`.
    LaunchedEffect(days, enabled) {
        val next = runCatching { autoDetectCandidate(viewModel, context, days) }.getOrNull()
        // A fresh scan that surfaces a DIFFERENT window resets the session guard so a new bout can show.
        if (next != candidate) handledThisSession = false
        candidate = next
    }

    val w = candidate
    if (handledThisSession || w == null) return
    val timeFormatter = remember(locale) {
        DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale).withZone(ZoneId.systemDefault())
    }
    val startTime = timeFormatter.format(Instant.ofEpochSecond(w.startSec))
    val endTime = timeFormatter.format(Instant.ofEpochSecond(w.endSec))
    val prompt = when (val day = autoWorkoutDay(w.startSec)) {
        AutoWorkoutDay.Today -> uiString(R.string.today_auto_workout_prompt_today, startTime, endTime, w.avgBpm, w.durationMin)
        AutoWorkoutDay.Yesterday -> uiString(R.string.today_auto_workout_prompt_yesterday, startTime, endTime, w.avgBpm, w.durationMin)
        is AutoWorkoutDay.OnDate -> {
            val dateFormatter = remember(locale) {
                DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(locale).withZone(ZoneId.systemDefault())
            }
            uiString(
                R.string.today_auto_workout_prompt_date,
                dateFormatter.format(Instant.ofEpochSecond(day.epochSec)), startTime, endTime, w.avgBpm, w.durationMin,
            )
        }
    }

    NoopCard(tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(modifier = Modifier.fillMaxWidth()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.AutoMirrored.Filled.DirectionsRun,
                        contentDescription = null,
                        tint = Palette.accent,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(uiString(R.string.l10n_auto_workout_nudge_looks_like_a_workout_e745e403), style = NoopType.headline, color = Palette.textPrimary)
                }
                // Standard × dismiss → record the window durably so it never re-prompts.
                IconButton(
                    onClick = {
                        AutoWorkoutPrefs.dismissSpan(context, w.startSec, w.endSec)
                        handledThisSession = true
                        candidate = null
                    },
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .size(Metrics.iconButton)
                        .semantics { contentDescription = uiString(R.string.l10n_auto_workout_nudge_dismiss_this_workout_suggestion_52ace8f3) },
                ) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = null,
                        tint = Palette.textTertiary,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
            Text(
                prompt,
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Button(
                    onClick = {
                        // The manual row over the exact detected window with everything the detector
                        // computed, under the suggested sport (twin of iOS `buildRow(fromSuggestion:)`).
                        // Saved under the ACTIVE strap id (what the Workouts union reads, #200/#814).
                        val row = WorkoutAutoDetect.buildRow(w, viewModel.deviceId)
                        // #214 ROOT CAUSE: save on the ViewModel's scope, NOT the card's. Setting
                        // handledThisSession=true removes this card from composition immediately (see the
                        // `return` gate above), which CANCELS its rememberCoroutineScope — so the old
                        // `scope.launch { saveManualWorkout }` was killed before the suspend DB write
                        // committed. The workout never saved and the card kept re-prompting. viewModel
                        // .saveManualWorkout runs on viewModelScope (survives) + reloads the list itself.
                        if (row != null) viewModel.saveManualWorkout(row)
                        handledThisSession = true
                        candidate = null
                    },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Palette.accent, contentColor = Palette.surfaceBase,
                    ),
                ) { Text(uiString(R.string.l10n_auto_workout_nudge_save_it_01d23661)) }

                OutlinedButton(
                    onClick = {
                        AutoWorkoutPrefs.dismissSpan(context, w.startSec, w.endSec)
                        handledThisSession = true
                        candidate = null
                    },
                ) { Text(uiString(R.string.l10n_auto_workout_nudge_not_a_workout_15c5f784), color = Palette.textSecondary) }
            }
        }
    }
}

/**
 * The card's suggestion: the newest open one from [WorkoutAutoDetect.openSuggestions] (the last
 * [WorkoutAutoDetect.SUGGESTION_LIFETIME_DAYS] days, saved and dismissed spans excluded; sessions that
 * clear the auto-save bar are saved by the analysis pass and leave). Never writes anything. With Workouts
 * Test Centre active, the old detector's trace and shadow comparison are logged too, as before.
 */
private suspend fun autoDetectCandidate(
    viewModel: AppViewModel,
    context: android.content.Context,
    days: List<DailyMetric>,
): WorkoutAutoDetect.Suggestion? {
    if (com.noop.testcentre.TestCentre.from(context).active(com.noop.testcentre.TestDomain.WORKOUTS)) {
        runCatching { logAutoDetectShadow(viewModel, context, days) }
    }
    return WorkoutAutoDetect.openSuggestions(context, viewModel.repo, viewModel.deviceId, days).firstOrNull()
}

/** Workouts & GPS test mode: the old detector's trace and shadow comparison, as diagnostics only. */
private suspend fun logAutoDetectShadow(
    viewModel: AppViewModel,
    context: android.content.Context,
    days: List<DailyMetric>,
) {
    val nowSec = System.currentTimeMillis() / 1000
    val fromSec = nowSec - AUTO_DETECT_DAYS_BACK * 86_400L
    val repo = viewModel.repo
    val hr = repo.hrSamplesUnion(viewModel.deviceId, fromSec, nowSec, limit = 200_000)
    if (hr.size < 2) return
    val restingHr = days.lastOrNull { it.restingHr != null }?.restingHr
    val savedRows = WorkoutAutoDetect.savedRows(repo, viewModel.deviceId, fromSec, nowSec)
    val saved = savedRows.map { it.startTs to it.endTs }
    val gravity = repo.gravitySamplesUnion(viewModel.deviceId, fromSec, nowSec)
    val maxHR = ProfileStore.from(context).hrMax.takeIf { it > 0 }
    val (_, trace) = AutoWorkoutDetectorTrace.detectTrace(
        hr = hr,
        restingHR = restingHr,
        gravity = gravity,
        savedWorkouts = saved,
        maxHR = maxHR,
        path = "autoDetect",
    )
    for (line in trace) viewModel.ble.externalLog(line, com.noop.testcentre.TestDomain.WORKOUTS)

    // #2187 PR 1: evaluate the published 12-minute baseline plus proposed 10/15 alternatives in SHADOW.
    // Use the exact same detector and inputs as the published 12-minute path, but do not feed either
    // result into the card, persistence, or downstream scoring. Compare against real saved sessions
    // (manual/imported); legacy computed rows are deliberately not labels. Aggregate local log lines
    // are the only output and are emitted only while Workouts Test Centre is explicitly active.
    val labelledSpans = autoDetectLabelledSpans(savedRows)
    for (policy in autoDetectShadowPolicies()) {
        val shadow = AutoWorkoutDetector.detect(
            hr = hr,
            restingHR = restingHr,
            gravity = emptyList(), // preserve the published HR-only input contract in shadow
            savedWorkouts = emptyList(), // labels must remain visible to the comparison
            minimumSustainedMinutes = policy,
        )
        viewModel.ble.externalLog(
            AutoWorkoutDetectorTrace.shadowComparisonLine(
                policy,
                shadow,
                labelledSpans,
                hrForObservability = hr,
            ),
            com.noop.testcentre.TestDomain.WORKOUTS,
        )
    }
}
