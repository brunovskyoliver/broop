package com.noop.analytics

import com.noop.data.StressAnalysisStore
import com.noop.data.WhoopRepository
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * The per-pass energy anchors: resting HR while awake (median wake floor of the 14 days before today, whole
 * bpm so a small daily drift does not rescore every cached day) and the newest imported VO2max. Null
 * anchors leave the day-energy estimate on the caller's resting HR, the sleeping floor, and on Uth. Twin of
 * Swift `Repository.refreshEnergyAnchors` + `withEnergyAnchors`.
 */
internal object EnergyAnchors {
    /** The 14 prior days' wake floors, oldest → newest; a missing day is null. */
    fun priorFloors(today: LocalDate, stored: Map<String, Map<String, Double>>): List<Double?> =
        (StressMonitor.baselineWindowDays.toLong() downTo 1L).map {
            stored[today.minusDays(it).toString()]?.get(StressMonitor.wakeFloorKey)
        }

    /** Whole-bpm awake anchor. `Math.round` rounds half up, as Swift's `rounded()` does for positive HR. */
    fun awakeAnchor(priorFloors: List<Double?>): Double? =
        Calories.awakeRestingHR(priorFloors)?.let { Math.round(it).toDouble() }

    fun apply(profile: UserProfile, awake: Double?, vo2max: Double?): UserProfile =
        profile.copy(awakeRestingHR = awake, vo2max = vo2max)

    suspend fun anchored(
        repo: WhoopRepository,
        importedDeviceId: String,
        profile: UserProfile,
        nowSeconds: Long,
        zone: ZoneId = ZoneId.systemDefault(),
    ): UserProfile {
        val today = Instant.ofEpochSecond(nowSeconds).atZone(zone).toLocalDate()
        val stored = StressAnalysisStore.storedValues(
            repo, importedDeviceId, listOf(StressMonitor.wakeFloorKey),
            today.minusDays(StressMonitor.baselineWindowDays.toLong()).toString(), today.toString(),
        )
        val vo2max = repo.metricSeries(WhoopRepository.APPLE_HEALTH_SOURCE, "vo2max", "0000-01-01", "9999-12-31")
            .lastOrNull()?.value
        return apply(profile, awakeAnchor(priorFloors(today, stored)), vo2max)
    }
}
