package com.noop.ui

import android.content.Context
import com.noop.analytics.AutoWorkoutDetector

/**
 * AutoWorkoutPrefs — durable dismissed-span store for the opt-in auto-detect Today card.
 *
 * Byte-mirror of the iOS `Repository.autoDetectDismissedSpans` (UserDefaults key
 * "workouts.autoDetectDismissed"): a flat list of "startSec:endSec" tokens (the detector's integer
 * seconds). The store remains intact for compatibility; candidate filtering now honors it together
 * with the analytics detector's legacy `dismissedWorkout` markers, so neither prior rejection can
 * reappear after the #2187 transition.
 *
 * NON-destructive: this only records that the user said "not this one"; no workout row is ever
 * created or deleted by the auto-detect feature unless the user taps Save.
 */
object AutoWorkoutPrefs {
    private const val FILE = "noop_auto_workout_prefs"
    private const val KEY_DISMISSED = "workouts.autoDetectDismissed"

    /**
     * Hard cap on the dismissed-span set — a backstop so it can't grow without bound even in
     * pathological use. 200 most-recent (by span END) is far more than detection's 7-day window can
     * ever re-surface; the age prune below normally keeps it much shorter. Mirrors the iOS twin.
     */
    private const val DISMISSED_MAX = 200

    /**
     * Spans whose END is older than this many seconds can never be re-suggested (detection only scans
     * the last 7 days), so we drop them. 30 days, matching the iOS twin byte-for-byte.
     */
    private const val DISMISSED_MAX_AGE_SEC = 30L * 86_400L

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** Token for one auto-detect span — matches the iOS `autoDetectToken` ("startSec:endSec"). */
    fun token(w: AutoWorkoutDetector.DetectedWorkout): String = "${w.startSec}:${w.endSec}"

    /** Parse only the suffix after the last colon, exactly like Swift's pruning path. */
    private fun tokenEnd(token: String): Long? = token.substringAfterLast(':', "").toLongOrNull()

    /**
     * Preserve the published semantics of each dismissal store. This card's SharedPreferences entries
     * suppress only the exact detector token that was dismissed. The analytics detector's durable legacy
     * markers use half-open interval overlap, so a drifted candidate is suppressed but two spans that only
     * touch at an endpoint are not treated as the same workout.
     */
    internal fun isDismissed(
        w: AutoWorkoutDetector.DetectedWorkout,
        legacyTokens: Set<String>,
        detectedSpans: List<Pair<Long, Long>>,
    ): Boolean {
        if (token(w) in legacyTokens) return true
        return detectedSpans.any { (start, end) ->
            w.startSec < end && start < w.endSec
        }
    }

    /**
     * Prune the dismissed-span set: drop spans whose END is older than ~30 days (they can never be
     * re-suggested anyway), then hard-cap to the [DISMISSED_MAX] most-recent (by END) as a backstop.
     * Malformed tokens are kept (treated as newest) so we never silently lose data on a parse miss.
     * Byte-mirrored in the iOS `Repository.prunedAutoDetectSpans`.
     */
    internal fun prune(spans: Set<String>, now: Long): Set<String> {
        val cutoff = now - DISMISSED_MAX_AGE_SEC
        // Drop anything that aged out; an unparseable token survives the age filter.
        val fresh = spans.filter { token -> (tokenEnd(token) ?: return@filter true) >= cutoff }
        if (fresh.size <= DISMISSED_MAX) return fresh.toSet()
        // Over the cap — keep the most-recent by END (unparseable sort as newest).
        return fresh.sortedByDescending { tokenEnd(it) ?: Long.MAX_VALUE }
            .take(DISMISSED_MAX)
            .toSet()
    }

    private const val KEY_AUTO_SAVED = "workouts.autoSaved"
    private const val KEY_FULL_SCAN_DAY = "workouts.autoSaveFullScanDay"

    /** "startSec:endSec" tokens as spans; malformed or non-positive-width entries are dropped. */
    fun spans(tokens: Collection<String>): List<Pair<Long, Long>> = tokens.mapNotNull { t ->
        val p = t.split(":")
        val a = p.getOrNull(0)?.toLongOrNull()
        val b = p.getOrNull(1)?.toLongOrNull()
        if (p.size == 2 && a != null && b != null && b > a) a to b else null
    }

    /** Spans this device ever auto-saved (2026-11-18 ledger; same key as the iOS UserDefaults list). */
    fun autoSaved(ctx: Context): Set<String> =
        prefs(ctx).getStringSet(KEY_AUTO_SAVED, emptySet())?.toSet() ?: emptySet()

    fun recordAutoSaved(ctx: Context, startSec: Long, endSec: Long) {
        val cur = autoSaved(ctx).toMutableSet()
        if (cur.add("$startSec:$endSec")) {
            prefs(ctx).edit().putStringSet(KEY_AUTO_SAVED, prune(cur, System.currentTimeMillis() / 1000L)).apply()
        }
    }

    /** Span-addressed dismissal, for the notification actions that carry only a span. */
    fun dismissSpan(ctx: Context, startSec: Long, endSec: Long) {
        val cur = dismissed(ctx).toMutableSet()
        if (cur.add("$startSec:$endSec")) {
            prefs(ctx).edit().putStringSet(KEY_DISMISSED, prune(cur, System.currentTimeMillis() / 1000L)).apply()
        }
    }

    /** Local epoch day of the last auto-save pass that scanned the whole suggestion lifetime. */
    fun fullScanDay(ctx: Context): Long = prefs(ctx).getLong(KEY_FULL_SCAN_DAY, Long.MIN_VALUE)
    fun setFullScanDay(ctx: Context, day: Long) { prefs(ctx).edit().putLong(KEY_FULL_SCAN_DAY, day).apply() }

    /** The set of dismissed span tokens (empty when none). */
    fun dismissed(ctx: Context): Set<String> =
        prefs(ctx).getStringSet(KEY_DISMISSED, emptySet())?.toSet() ?: emptySet()

    /**
     * Record a dismissed span durably. Idempotent (a Set never double-stores a token). Prunes the
     * stored set on every add (drop spans older than ~30 days + hard-cap to 200 most-recent) so it can
     * never grow unbounded. Byte-mirrored in the iOS `Repository.dismissDetectedSuggestion`.
     */
    fun dismiss(ctx: Context, w: AutoWorkoutDetector.DetectedWorkout) {
        val cur = dismissed(ctx).toMutableSet()
        if (cur.add(token(w))) {
            // Store a fresh copy — SharedPreferences.getStringSet returns a live instance that must not
            // be mutated in place, so a new set is written back.
            val pruned = prune(cur, System.currentTimeMillis() / 1000L)
            prefs(ctx).edit().putStringSet(KEY_DISMISSED, pruned).apply()
        }
    }
}
