package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Twin of the iOS DetectedWorkoutReconciliationTests auto-save cases (2026-11-18). */
class WorkoutAutoDetectTest {

    private fun detection(start: Long, end: Long, save: Boolean = true) = WorkoutAutoDetect.Detection(
        WorkoutAutoDetect.Suggestion(startSec = start, endSec = end, avgBpm = 118, peakBpm = 150,
                                     durationMin = ((end - start) / 60).toInt(), suggestedClass = "strength",
                                     suggestedClassConfidence = 0.3),
        if (save) "strength" else null,
    )

    private val lift = detection(10_000, 13_000)

    private fun due(
        d: List<WorkoutAutoDetect.Detection> = listOf(lift), saved: List<Pair<Long, Long>> = emptyList(),
        blocked: List<Pair<Long, Long>> = emptyList(), now: Long = 100_000,
    ) = WorkoutAutoDetect.selectAutoSaves(d, saved, blocked, now).map { it.suggestion.startSec }

    @Test
    fun autoSaveSelectionHonoursEverythingThatSaysNo() {
        assertEquals(listOf(10_000L), due())
        assertEquals(emptyList<Long>(), due(listOf(detection(10_000, 13_000, save = false))))
        assertEquals("a session that may still grow waits", emptyList<Long>(), due(now = 13_000 + 60))
        assertEquals(emptyList<Long>(), due(saved = listOf(12_000L to 14_000L)))
        assertEquals(emptyList<Long>(), due(blocked = listOf(12_500L to 12_600L)))
        assertEquals("two detections of one span save once", listOf(10_000L, 20_000L),
                     due(listOf(lift, detection(12_900, 14_000), detection(20_000, 23_000))))
    }

    @Test
    fun openSuggestionsAreNewestFirstAndExcludeBlockedSpans() {
        val open = WorkoutAutoDetect.selectOpen(
            listOf(lift, detection(20_000, 23_000, save = false), detection(30_000, 33_000, save = false)),
            savedSpans = listOf(30_500L to 30_600L), blockedSpans = emptyList(), nowSec = 100_000)
        assertEquals(listOf(20_000L, 10_000L), open.map { it.startSec })
    }

    @Test
    fun theStoredRowCarriesTheSportTheFiguresAndTheClass() {
        val s = WorkoutAutoDetect.Suggestion(startSec = 1_000, endSec = 5_139, avgBpm = 117, peakBpm = 151, durationMin = 68,
                                             energyKcal = 612.0, strain = 41.0, zonesJSON = "{\"z1\":10}", steps = 900,
                                             suggestedClass = "strength", suggestedClassConfidence = 0.6)
        val row = WorkoutAutoDetect.buildRow(s, "my-whoop", nowSec = 100_000)!!
        assertEquals("Strength Training", row.sport)
        assertEquals("manual", row.source)
        assertEquals(5_139L, row.endTs)
        assertEquals(151, row.maxHr)
        assertEquals(41.0, row.strain!!, 0.0)
        assertEquals(900, row.steps)
        assertEquals("strength", row.suggestedClass)
        assertEquals("Workout", WorkoutAutoDetect.buildRow(s.copy(suggestedClass = null), "my-whoop", 100_000)!!.sport)
        assertNull(WorkoutAutoDetect.sportFor("swim"))
    }
}
