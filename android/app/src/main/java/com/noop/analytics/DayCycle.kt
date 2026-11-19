package com.noop.analytics

/**
 * User-selectable ownership rule for additive daily metrics.
 *
 * Sleep and recovery values keep their night/wake-day semantics; this setting is for values accumulated
 * while awake, such as steps, energy and cardiovascular load.
 */
enum class DayCycleMode(val persistedValue: String) {
    SLEEP_ONSET("sleep_onset"),
    MIDNIGHT("midnight");

    companion object {
        fun fromPersisted(value: String?): DayCycleMode = entries.firstOrNull {
            it.persistedValue == value
        } ?: SLEEP_ONSET
    }
}

/** Shared cycle window consumed by every additive daily metric. */
data class DayCycleWindow(
    val id: String,
    val startInclusive: Long,
    val endExclusive: Long,
    val displayDay: String,
    val source: Source,
) {
    enum class Source { DETECTED_SLEEP, EDITED_SLEEP, SYNTHETIC_MIDNIGHT, CALENDAR }
}

object DayCycleResolver {
    const val MIN_SYNTHETIC_MIDNIGHT_AGE_SECONDS = 18 * 3_600L
    const val ABSOLUTE_MAX_OPEN_SECONDS = 40 * 3_600L

    /** Midnight is always available and is also the honest cold-start/failure fallback. */
    fun calendarWindow(now: Long, tzOffsetSeconds: Long): DayCycleWindow {
        val local = now + tzOffsetSeconds
        val dayNumber = Math.floorDiv(local, SleepStageTotals.SECONDS_PER_DAY)
        val start = dayNumber * SleepStageTotals.SECONDS_PER_DAY - tzOffsetSeconds
        val day = AnalyticsEngine.dayString(start, tzOffsetSeconds)
        return DayCycleWindow("calendar:$day", start, now, day, DayCycleWindow.Source.CALENDAR)
    }

    /** First local midnight that does not truncate a freshly-started sleep cycle. */
    fun fallbackMidnightAfter(start: Long, tzOffsetSeconds: Long): Long {
        val minimum = start + MIN_SYNTHETIC_MIDNIGHT_AGE_SECONDS
        val local = minimum + tzOffsetSeconds
        val dayNumber = Math.floorDiv(local, SleepStageTotals.SECONDS_PER_DAY)
        val atMidnight = dayNumber * SleepStageTotals.SECONDS_PER_DAY - tzOffsetSeconds
        return if (atMidnight >= minimum) atMidnight
        else (dayNumber + 1) * SleepStageTotals.SECONDS_PER_DAY - tzOffsetSeconds
    }

    /** A cycle boundary with the calendar day whose row it fills (the day its main sleep ends on). */
    data class WakeDayBoundary(val sleepId: String, val onset: Long, val wakeDay: String)

    /**
     * A calendar day that no main sleep ends on, cut out of the cycle that would otherwise run across it.
     * [sleepId] is `synthetic:<day>`, the id the open-cycle cap in [activeWindow] gives the same day;
     * [onset] is local midnight at the start of [day]; [splitFrom] is the boundary it was cut from.
     */
    data class UncoveredDay(val sleepId: String, val onset: Long, val day: String, val splitFrom: String)

    /**
     * Calendar days that fall strictly between two consecutive wake days, or between the last wake day and
     * the calendar day of [now], each with a boundary at its own local midnight.
     *
     * A night with no detected main sleep (strap on the charger, a night spent awake) has no boundary, so
     * the cycle before it ran to the NEXT night's onset: one row carried two days of steps, Effort and
     * energy and the following row was empty (2026-11-08 and 2026-11-13 on real data). Cutting at the
     * orphan day's midnight is the window the Home screens already read for that day, since a day with no
     * onset marker falls back to its calendar bound. Consecutive wake days yield nothing, so ordinary
     * cycles are unchanged. Only days that have fully started are cut, and the day of [now] is never cut
     * by this rule: a sleep ending later today may still claim it. The live cap in [activeWindow] covers
     * the open cycle before that, and its boundary must be passed in so the day counts as claimed.
     *
     * Swift twin: `DayCycleResolver.uncoveredDays`.
     */
    fun uncoveredDays(boundaries: List<WakeDayBoundary>, now: Long, tzOffsetSeconds: Long): List<UncoveredDay> {
        val ordered = boundaries.asSequence()
            .filter { it.onset <= now }
            .distinctBy { it.sleepId }
            .sortedWith(compareBy<WakeDayBoundary> { it.onset }.thenBy { it.sleepId })
            .toList()
        val claimed = ordered.mapTo(HashSet()) { it.wakeDay }
        val today = AnalyticsEngine.dayString(now, tzOffsetSeconds)
        val output = ArrayList<UncoveredDay>()
        for ((index, item) in ordered.withIndex()) {
            val next = ordered.getOrNull(index + 1)
            val nextDay = next?.wakeDay ?: today
            val nextOnset = next?.onset ?: now
            val dayStart = AnalyticsEngine.dayStartUtcSeconds(item.wakeDay)
            // A malformed key parses to 0; walking from 1970 would invent decades of days.
            if (AnalyticsEngine.dayString(dayStart) != item.wakeDay) continue
            var midnight = dayStart + SleepStageTotals.SECONDS_PER_DAY - tzOffsetSeconds
            while (midnight < nextOnset) {
                val day = AnalyticsEngine.dayString(midnight, tzOffsetSeconds)
                if (day >= nextDay) break
                if (midnight > item.onset && day !in claimed) {
                    output += UncoveredDay("synthetic:$day", midnight, day, item.sleepId)
                }
                midnight += SleepStageTotals.SECONDS_PER_DAY
            }
        }
        return output
    }

    /**
     * Resolve the active window. Sleep-onset mode stays open across midnight even when awake coverage is
     * unavailable. The absolute cap still prevents a stale sleep boundary from remaining active forever.
     *
     * That "even when" is unconditional, not a gate: an earlier design decided it from whether awake
     * coverage was reliable and carried a `reliableAwakeCoverage` parameter for it. The gate was dropped
     * but the parameter survived — unread on both platforms, and passed `false` by every one of its call
     * sites — so it was removed rather than left looking like a switch someone could flip.
     */
    fun activeWindow(
        mode: DayCycleMode,
        latestSleep: DayCycleWindow?,
        now: Long,
        tzOffsetSeconds: Long,
    ): DayCycleWindow {
        if (mode == DayCycleMode.MIDNIGHT || latestSleep == null) {
            return calendarWindow(now, tzOffsetSeconds)
        }
        val age = now - latestSleep.startInclusive
        val mustFallback = age >= ABSOLUTE_MAX_OPEN_SECONDS
        if (!mustFallback) return latestSleep.copy(endExclusive = now)
        val boundary = fallbackMidnightAfter(latestSleep.startInclusive, tzOffsetSeconds)
        val day = AnalyticsEngine.dayString(boundary, tzOffsetSeconds)
        return DayCycleWindow(
            id = "synthetic:$day",
            startInclusive = boundary,
            endExclusive = now,
            displayDay = day,
            source = DayCycleWindow.Source.SYNTHETIC_MIDNIGHT,
        )
    }
}
