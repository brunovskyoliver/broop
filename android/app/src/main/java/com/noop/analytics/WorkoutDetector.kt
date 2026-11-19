package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.StepSample
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.min
import kotlin.math.roundToLong
import kotlin.math.sqrt

/*
 * WorkoutDetector.kt — retroactive workout detection from the 1 Hz store.
 *
 * Faithful Kotlin port of StrandAnalytics/WorkoutDetector.swift (verified on macOS),
 * itself ported from server/ingest/app/analysis/exercise.py (+ activity.py, calories.py).
 *
 * A workout is a SUSTAINED window (≥ MIN_EXERCISE_MIN) of elevated HR (above
 * resting + HR_MARGIN_BPM) AND sustained motion (gravity-derived intensity above
 * MOTION_THRESHOLD). Both gates must hold for a sample to count as active.
 *
 * Per detected bout: avg/peak HR, duration, Edwards zone time-%, mean %HRR,
 * strain (StrainScorer), and estimated calories (Keytel 2005 active + revised
 * Harris–Benedict BMR resting, age/sex/weight/height adjusted).
 *
 * All intensity/energy outputs are APPROXIMATE and not medical advice.
 *
 * Types note: [UserProfile], [ExerciseSession] and [ActivityPoint] live in
 * AnalyticsModels.kt (shared value types) and are NOT redefined here. Inputs are
 * the Room entities com.noop.data.HrSample (ts:Long seconds, bpm:Int) and
 * com.noop.data.GravitySample (ts:Long seconds, x/y/z:Double). All `ts`/`start`/`end`
 * are unix SECONDS as Long. The Swift source used Int seconds.
 */
object WorkoutDetector {

    // ---- Constants (exercise.py) ----

    const val minExerciseMin: Double = 5.0
    const val hrMarginBPM: Double = 15.0
    const val motionThreshold: Double = 0.20
    const val motionSmoothS: Double = 10.0
    const val mergeGapS: Double = 150.0
    const val minIntensityZ2Plus: Double = 0.50
    const val alignToleranceS: Double = 5.0
    const val restingPercentile: Double = 10.0

    /**
     * Second-pass bridge window (#303). Two adjacent active runs separated by a
     * below-motion-threshold gap no longer than this are stitched into one workout —
     * BUT ONLY while HR stays elevated across the gap (see [bridgeRuns]). A sustained
     * endurance effort (e.g. a long bike ride) routinely dips below the motion gate
     * for a few minutes — coasting a descent, a junction, a brief sensor dropout —
     * without the athlete actually resting; [mergeGapS] (150 s) is too tight to ride
     * through those, so the bout used to shatter into many sub-bouts, most of which
     * then fell under [minExerciseMin] and vanished. A genuine rest between two
     * separate workouts is gated out by the HR check, not by this window.
     */
    const val bridgeGapS: Double = 300.0

    // ---- 2026-09-21 activity tier (auto-detection plan) ----
    //
    // The classic qualification bar — ≥ [minIntensityZ2Plus] of HR samples in zone 2+ — drops exactly
    // the bouts WHOOP itself files as "Activity": sustained walks, hikes and easy rides whose mean HR
    // sits around rest + 30–50% HRR. On a user whose resting HR is ~45–50 with a realistic HRmax the
    // zone-2 floor lands ~130 bpm, so days with 20–40k steps and hours of walking produced ZERO kept
    // sessions. The activity tier re-qualifies those runs against a HEART-RATE-RESERVE floor instead
    // of a fixed bpm margin — a fixed `rest + N` massively over-fires on low-resting-HR users (rest+30
    // puts the floor in the 70s, where the whole day qualifies).
    //
    // A run qualifies for the activity tier when ALL of:
    //   - duration ≥ [activityMinMin] (longer than the classic bar — sustained ambulation, not stairs)
    //   - ≥ [activityElevatedFrac] of its in-run HR samples read above
    //     rest + [activityHRRFraction] × (HRmax − rest)
    // The motion gate is unchanged — every run already passed it to get here.
    /** Fraction of heart-rate reserve the activity tier's sustained-HR floor sits at (~40% HRR,
     *  matching where WHOOP's own auto-detected "Activity" rows land on real data). */
    const val activityHRRFraction: Double = 0.40
    /** Minimum run length for the activity tier, minutes. Deliberately longer than [minExerciseMin]:
     *  the tier exists to catch sustained low-intensity sessions, not brief staircases. */
    const val activityMinMin: Double = 10.0
    /** Fraction of the run's HR samples that must read above the activity floor (half — the same
     *  "majority of the window" shape [minIntensityZ2Plus] uses for zone time). */
    const val activityElevatedFrac: Double = 0.50

    // ---- Activity series (activity.py) ----

    /**
     * Per-record motion-intensity series: L2 magnitude of the gravity change vs
     * the previous record. First row → 0. Empty input → []. (GravitySample always
     * carries finite x/y/z, so no dropout sentinel is required here.)
     */
    fun activitySeries(gravity: List<GravitySample>): List<ActivityPoint> {
        if (gravity.isEmpty()) return emptyList()
        val rows = gravity.sortedBy { it.ts }
        val series = ArrayList<ActivityPoint>(rows.size)
        var prev: GravitySample? = null
        for ((i, row) in rows.withIndex()) {
            val intensity: Double
            val p = prev
            if (i == 0) {
                intensity = 0.0
            } else if (p != null) {
                val dx = row.x - p.x
                val dy = row.y - p.y
                val dz = row.z - p.z
                intensity = sqrt(dx * dx + dy * dy + dz * dz)
            } else {
                intensity = 0.0
            }
            series.add(ActivityPoint(ts = row.ts, intensity = intensity))
            prev = row
        }
        return series
    }

    // ---- Helpers ----

    /**
     * Sorted (ts, bpm) pairs.
     *
     * Swift `cleanHR` mapped to `(ts: Int, bpm: Double)`; here the Room [HrSample]
     * already carries an Int bpm, so we keep the rows sorted by ts and read bpm as a
     * Double on demand — equivalent and avoids losing the deviceId needed downstream.
     */
    internal fun cleanHR(hr: List<HrSample>): List<HrSample> = hr.sortedBy { it.ts }

    /** Day resting-HR baseline = nearest-rank RESTING_PERCENTILE of bpm values. */
    internal fun deriveRestingHR(hrSeg: List<HrSample>): Double {
        val bpms = hrSeg.map { it.bpm.toDouble() }.sorted()
        require(bpms.isNotEmpty()) { "deriveRestingHR called with empty segment" }
        val rank = maxOf(1, ceil(restingPercentile / 100.0 * bpms.size.toDouble()).toInt())
        return bpms[rank - 1]
    }

    /**
     * #1545: why a day produced no workout, counted at each gate the detector actually applies.
     *
     * The `effort bout` line explains a bout that EXISTS. It is silent when none does — and "no workouts at
     * all" is the harder report to answer, because every gate looks equally plausible from outside. A
     * reporter with 37 days and zero detected bouts previously had nothing to send that could distinguish
     * "the strap never registered motion" (a WHOOP 4.0 banks it coarsely, #345/#28) from "HR never cleared
     * resting + 15" from "the efforts were real but under five minutes".
     *
     * Counted during the detector's OWN walk, never recomputed alongside it: a funnel free to disagree with
     * the code it describes is worse than no funnel, because it will be believed. Byte-parity twin of Swift
     * `WorkoutDetector.DetectionFunnel`.
     */
    data class DetectionFunnel(
        /** Inputs the day actually had. */
        var hrSamples: Int = 0,
        var motionSamples: Int = 0,
        /** The bar a sample had to clear, in bpm — resting + [hrMarginBPM]. */
        var restingHR: Double? = null,
        var hrFloor: Double? = null,
        /** Motion samples whose smoothed intensity cleared [motionThreshold]. */
        var motionPassed: Int = 0,
        /** Of those, how many had NO HR sample within [alignToleranceS] (a sensor gap, not a quiet body). */
        var hrMissing: Int = 0,
        /** Of those, how many had HR at or below [hrFloor] (moving, but not working). */
        var hrTooLow: Int = 0,
        /** Samples that cleared BOTH gates. */
        var active: Int = 0,
        /** Contiguous runs after gap-merging, and after the #303 HR-gated bridge. */
        var runs: Int = 0,
        var bridged: Int = 0,
        /**
         * The LONGEST and MEAN bridged run, in seconds, before any qualification gate drops anything.
         *
         * They answer how SUBSTANTIAL the best candidate was, which the counts cannot. [droppedShort] is
         * checked first and short-circuits, so [droppedLowIntensity] already implies some run cleared the
         * duration bar — but not by how much, and that is the whole difference between a candidate
         * scraping five minutes and an hour-long effort rejected on intensity. The second is worth
         * investigating; the first is a walk.
         *
         * From the field log that motivated this: 22 days of `kept=0`, 1271 runs that never reached
         * [minExerciseMin] and 390 that did and failed the intensity bar instead. The counts said the
         * duration gate was not the whole story; only [longestRunS] says whether what survived it was a
         * five-minute stroll or something that should have scored.
         *
         * READ [longestRunS] AGAINST 290 s, NOT 300. The gate is `minDurS - motionSmoothS`
         * (5 min − 10 s), because the smoothing window costs a run its first samples. Comparing against
         * a round five minutes misjudges everything in the 290..300 window — a 295 s run cleared the
         * gate and would look as though it had not.
         */
        var longestRunS: Int = 0,
        var meanRunS: Int = 0,
        /** Runs rejected by each qualification gate, and the survivors. */
        var droppedShort: Int = 0,
        var droppedNoHR: Int = 0,
        var droppedLowIntensity: Int = 0,
        var kept: Int = 0,
        /**
         * 2026-09-21 auto-detection: of [kept], how many sessions survived via the ACTIVITY tier
         * (sustained ≥ [activityHRRFraction] HRR elevation) instead of the ≥50%-zone-2 bar. Zero on
         * any day whose kept bouts all cleared the classic gate — the field exists so a log can tell
         * "the detector is dead" from "the detector found walks, which used to be dropped".
         */
        var keptActivity: Int = 0,
        /** Runs that failed both intensity bars as a whole and were retried as their elevated cores or cut
         *  at their walking streaks instead. Such a run is not counted in [droppedLowIntensity]. */
        var splitRuns: Int = 0,
        /** Of [kept], how many sessions came from those cores or pieces. */
        var splitKept: Int = 0,
        /** Of [splitRuns], how many yielded no session at all: every core or piece failed its own bar. */
        var splitDropped: Int = 0,
    )

    /**
     * #1545: the always-on per-day line naming where the detector lost every candidate workout.
     *
     * Byte-identical string to the Swift twin. No PII: a day key and counts, plus the two bpm thresholds the
     * day was measured against — the same privacy class as the sibling `sleep day=` line.
     */
    fun detectionFunnelLine(day: String, f: DetectionFunnel): String =
        "workout detect day=$day hr=${f.hrSamples} motion=${f.motionSamples} " +
            "restHR=${round0(f.restingHR)} floor=${round0(f.hrFloor)} " +
            "motionOK=${f.motionPassed} hrMissing=${f.hrMissing} hrTooLow=${f.hrTooLow} " +
            "active=${f.active} runs=${f.runs} bridged=${f.bridged} " +
            "longestRunS=${f.longestRunS} meanRunS=${f.meanRunS} " +
            "short=${f.droppedShort} noHR=${f.droppedNoHR} lowIntensity=${f.droppedLowIntensity} " +
            "kept=${f.kept} activity=${f.keptActivity} split=${f.splitRuns} splitKept=${f.splitKept} " +
            "splitDropped=${f.splitDropped}"

    /**
     * #1545: how much of [start]..[end] the HR sensor actually covered, as a percentage of
     * [bucketSeconds]-wide buckets holding at least one reading.
     *
     * Bucketed rather than sample-counted on purpose. A WHOOP 5/MG sends live HR only about every 30 s, so
     * counting samples against a 1 Hz expectation would report ~3% for a perfectly captured bout, which is
     * worse than no number. A bucket is either seen or not, so a 30 s cadence reads as full coverage and a
     * genuine dropout reads as the gap it is. Byte-parity twin of Swift `hrCoveragePct`.
     */
    fun hrCoveragePct(sampleTs: List<Long>, start: Long, end: Long, bucketSeconds: Long = 60L): Double? {
        if (end <= start || bucketSeconds <= 0) return null
        val buckets = maxOf(1L, ((end - start) + bucketSeconds - 1) / bucketSeconds)
        val seen = HashSet<Long>()
        for (ts in sampleTs) if (ts in start until end) seen.add((ts - start) / bucketSeconds)
        return seen.size.toDouble() / buckets.toDouble() * 100.0
    }

    /**
     * #1545: the always-on per-bout line naming what this workout's Effort was actually scored against.
     *
     * HRmax is the single biggest determinant of an Effort score -- it sets every zone boundary, so being
     * wrong by a few bpm can move real work across the 50% floor and score it zero -- and until this line
     * existed a user could not see which number had been used, or whether it came from their own setting
     * or an age formula. Working that out previously meant reversing the arithmetic from the displayed
     * score, which is what #1545 took to diagnose.
     *
     * No PII: a day key, a duration, bpm and percentages. Byte-identical string to the Swift twin.
     */
    fun boutCalibrationLine(
        day: String, durMin: Int, hrmax: Double?, hrmaxSource: String,
        avgHRRPct: Double?, hrCoveragePct: Double?, strain: Double?,
    ): String =
        "effort bout day=$day durMin=$durMin hrmax=${round0(hrmax)} src=$hrmaxSource " +
            "avgHRR=${round0(avgHRRPct)} cover=${round0(hrCoveragePct)} effort=${round1(strain)}"

    /**
     * The two numeric formatters this line uses, written as integer arithmetic over the value's MAGNITUDE
     * rather than %.0f / %.1f.
     *
     * Three things this shape avoids, all of which would break a line whose entire job is being comparable
     * between two users' logs — and between an iOS log and an Android one:
     *
     * - The positive tie. C printf (Swift) breaks a rounding tie to even; Java's String.format
     *   (Kotlin) breaks it up. A bout at exactly 52.5% HRR would print 52 on iOS and 53 on Android.
     * - The negative tie. Swift's .rounded() is half-AWAY-from-zero and Java's Math.round is
     *   half-UP, so they disagree on -4.5 (-5 vs -4). Rounding abs(v) and re-applying the sign makes the
     *   two identical in both directions; it also keeps the minus sign, which integer / and % truncating
     *   toward zero would otherwise drop (-0.4 printing as 0.4).
     * - The trap. Swift's Int(_: Double) CRASHES on a finite value past Int.max while Kotlin's
     *   Math.round silently saturates to Long.MAX_VALUE. Today's caller can't produce one (the detector
     *   gates maxHR > restingHR before computing %HRR), but this is public API, and a diagnostic that kills
     *   the process is the worst possible way for one to fail. Past the bound both platforms print nil,
     *   which is also the more honest answer: such a value is not a heart rate, a percentage or an Effort.
     */
    internal const val PRINTABLE_MAGNITUDE_LIMIT = 1e15

    internal fun round0(v: Double?): String {
        if (v == null || !v.isFinite() || abs(v) >= PRINTABLE_MAGNITUDE_LIMIT) return "nil"
        return (if (v < 0) "-" else "") + Math.round(abs(v)).toString()
    }

    internal fun round1(v: Double?): String {
        if (v == null || !v.isFinite() || abs(v) >= PRINTABLE_MAGNITUDE_LIMIT) return "nil"
        val t = Math.round(abs(v) * 10.0)
        return "${if (v < 0) "-" else ""}${t / 10}.${t % 10}"
    }

    /**
     * Value whose ts is nearest to [ts] within [tol] seconds, else null. Ties go
     * to the later timestamp (matches the Python <= behaviour).
     */
    internal fun nearest(sortedTs: List<Long>, values: List<Double>, ts: Long, tol: Double): Double? {
        if (sortedTs.isEmpty()) return null
        // bisect_left
        var lo = 0
        var hi = sortedTs.size
        while (lo < hi) {
            val mid = (lo + hi) / 2
            if (sortedTs[mid] < ts) lo = mid + 1 else hi = mid
        }
        val i = lo
        var bestV: Double? = null
        var bestD = tol
        for (j in intArrayOf(i - 1, i)) {
            if (j in sortedTs.indices) {
                val d = abs((sortedTs[j] - ts).toDouble())
                if (d <= bestD) {
                    bestD = d
                    bestV = values[j]
                }
            }
        }
        return bestV
    }

    /** Trailing rolling mean (over window_s) of intensities (all finite here). */
    internal fun smoothedIntensity(motion: List<ActivityPoint>, windowS: Double): List<Double> {
        val ts = motion.map { it.ts }
        val raw = motion.map { if (it.intensity.isFinite()) it.intensity else 0.0 }
        val out = ArrayList<Double>(motion.size)
        var lo = 0
        var running = 0.0
        for (i in motion.indices) {
            running += raw[i]
            while ((ts[i] - ts[lo]).toDouble() > windowS) {
                running -= raw[lo]
                lo += 1
            }
            out.add(running / (i - lo + 1).toDouble())
        }
        return out
    }

    /** Per-bout Edwards zone breakdown (%) + mean %HRR. APPROXIMATE. */
    internal fun boutIntensity(
        hrSeries: List<HrSample>,
        restingHR: Double,
        maxHR: Double,
    ): Pair<Map<Int, Double>, Double?> {
        if (hrSeries.isEmpty() || maxHR <= restingHR) return emptyMap<Int, Double>() to null
        val hrReserve = maxHR - restingHR
        val zoneCounts = HashMap<Int, Int>()
        for (z in 0..5) zoneCounts[z] = 0
        val hrrVals = ArrayList<Double>(hrSeries.size)
        for (r in hrSeries) {
            val bpm = r.bpm.toDouble()
            val z = StrainScorer.zoneWeight(bpm, restingHR, hrReserve)
            zoneCounts[z] = (zoneCounts[z] ?: 0) + 1
            hrrVals.add(StrainScorer.pctHRR(bpm, restingHR, hrReserve))
        }
        val n = hrSeries.size.toDouble()
        val zonePct = HashMap<Int, Double>()
        for ((z, c) in zoneCounts) {
            zonePct[z] = round1(c.toDouble() / n * 100.0)
        }
        val avgHRR = round1(hrrVals.sum() / n)
        return zonePct to avgHRR
    }

    /** Round to one decimal place. All inputs here are non-negative (matches Swift `.rounded()`). */
    private fun round1(v: Double): Double = (v * 10).roundToLong() / 10.0

    /**
     * Second-pass merge over raw active runs (#303).
     *
     * Stitch run `i+1` onto the current span when the inter-run gap (start of the
     * next minus end of the current) is ≤ [bridgeGapS] AND HR stays elevated across
     * that gap — i.e. the athlete kept working through a brief motion lull rather than
     * resting. "Elevated" = the mean of the HR samples strictly inside the gap is
     * still above [hrFloor] (resting + HR_MARGIN_BPM). If the gap carries NO HR
     * samples it is treated as a same-effort sensor dropout and bridged; a real rest
     * always lands HR samples in the gap (the strap streams 1 Hz), so it fails the
     * elevation test and the two workouts stay separate. Runs must arrive sorted by
     * start (they do — built from a sorted timeline).
     */
    internal fun bridgeRuns(
        runs: List<Pair<Long, Long>>,
        hrSeg: List<HrSample>,
        hrFloor: Double,
    ): List<Pair<Long, Long>> {
        if (runs.size <= 1) return runs
        val merged = ArrayList<Pair<Long, Long>>()
        var curStart = runs[0].first
        var curEnd = runs[0].second
        for (k in 1 until runs.size) {
            val next = runs[k]
            val gap = (next.first - curEnd).toDouble()
            var bridge = false
            if (gap <= bridgeGapS) {
                // HR samples strictly between the two runs (the lull itself).
                val gapHR = hrSeg.filter { it.ts > curEnd && it.ts < next.first }.map { it.bpm.toDouble() }
                bridge = if (gapHR.isEmpty()) {
                    true // sensor dropout mid-effort → same workout
                } else {
                    val meanGapHR = gapHR.sum() / gapHR.size.toDouble()
                    meanGapHR > hrFloor // still working → same workout
                }
            }
            if (bridge) {
                curEnd = maxOf(curEnd, next.second)
            } else {
                merged.add(curStart to curEnd)
                curStart = next.first
                curEnd = next.second
            }
        }
        merged.add(curStart to curEnd)
        return merged
    }

    /** Activity-class values the 5/MG strap uses for gait: 1 = walk, 2 = run (0 = still, null = 4.0). */
    internal fun isGait(activityClass: Int?): Boolean = activityClass == 1 || activityClass == 2

    /**
     * The stretches of a run where HR sits above [floor], as (firstTs, lastTs) spans. Consecutive
     * above-floor samples join while they are at most [bridgeGapS] apart, so the dips of a sets-and-rest
     * session stay inside one core. [hrSeries] must be sorted by ts. Twin of Swift `elevatedCores`.
     */
    internal fun elevatedCores(hrSeries: List<HrSample>, floor: Double): List<Pair<Long, Long>> {
        val cores = ArrayList<Pair<Long, Long>>()
        var cur: Pair<Long, Long>? = null
        for (s in hrSeries) {
            if (s.bpm.toDouble() <= floor) continue
            val c = cur
            cur = if (c != null && (s.ts - c.second).toDouble() <= bridgeGapS) {
                c.first to s.ts
            } else {
                if (c != null) cores.add(c)
                s.ts to s.ts
            }
        }
        cur?.let { cores.add(it) }
        return cores
    }

    /** Activity-tier bar for a piece [gaitPieces] cut from a bout that already qualified (Swift twin). */
    internal const val pieceElevatedFrac = 0.25
    /** A minute counts as walking when at least this many of its seconds carry a gait tag. */
    internal const val gaitMinuteTicks = 45
    /** A walking streak must last this long to split a bout; shorter ones are moves between sets. */
    internal const val gaitStreakMinS = 300L

    /**
     * Cut [start]..[end] at the edges of its sustained walking streaks, or null when there is nothing to
     * cut. Byte-for-byte twin of Swift `gaitPieces` (see its doc for the rules). [gaitTs] must be sorted.
     */
    internal fun gaitPieces(
        start: Long, end: Long, gaitTs: List<Long>,
        isWalkPace: (Long, Long) -> Boolean = { _, _ -> true },
    ): List<Pair<Long, Long>>? {
        if (gaitTs.isEmpty() || end - start < gaitStreakMinS) return null
        val n = ((end - start) / 60 + 1).toInt()
        val ticks = IntArray(n)
        var i = gaitTs.indexOfFirst { it >= start }.let { if (it < 0) gaitTs.size else it }
        while (i < gaitTs.size && gaitTs[i] <= end) { ticks[((gaitTs[i] - start) / 60).toInt()]++; i++ }
        val walking = BooleanArray(n) { ticks[it] >= gaitMinuteTicks }
        for (m in 1 until maxOf(1, n - 1)) if (!walking[m] && walking[m - 1] && walking[m + 1]) walking[m] = true
        var streaks = ArrayList<Pair<Int, Int>>()
        var m = 0
        while (m < n) {
            if (!walking[m]) { m++; continue }
            var e = m
            while (e + 1 < n && walking[e + 1]) e++
            if ((e - m + 1) * 60 >= gaitStreakMinS) streaks.add(m to e)
            m = e + 1
        }
        if (streaks.isEmpty()) return null
        val joinGapMin = activityMinMin.toInt()
        val joined = arrayListOf(streaks[0])
        for (k in 1 until streaks.size) {
            val s = streaks[k]
            val last = joined[joined.size - 1]
            if (s.first - last.second - 1 < joinGapMin) joined[joined.size - 1] = last.first to s.second else joined.add(s)
        }
        streaks = ArrayList(joined.filter { isWalkPace(start + it.first * 60L, minOf(end, start + it.second * 60L + 59)) })
        if (streaks.isEmpty()) return null
        val cuts = arrayListOf(0L)
        for ((a, b) in streaks) { cuts.add(a * 60L); cuts.add((b + 1) * 60L) }
        cuts.add(end - start + 1)
        val pieces = ArrayList<Pair<Long, Long>>()
        var otherS = 0L
        for (k in 0 until cuts.size - 1) {
            val a = minOf(cuts[k], end - start)
            val b = minOf(cuts[k + 1], end - start + 1)
            if (b <= a) continue
            pieces.add((start + a) to (start + b - 1))
            if (k % 2 == 0) otherS = maxOf(otherS, b - a)
        }
        if (otherS.toDouble() < activityMinMin * 60.0 - motionSmoothS) return null
        return pieces
    }

    /** Longest rest that can sit inside one non-walking session (Swift twin, N=1 tuning). */
    const val stitchMaxGapS: Long = 20 * 60
    /** Share of a gap's minutes that must hold an HR reading, unless [stitchMaxDropoutS] allows it. */
    internal const val stitchMinGapCoveragePct = 50.0
    /** Share of a piece's minutes at walking cadence that makes it a walk. */
    internal const val stitchWalkMinuteFrac = 0.5
    /** 2026-11-18: the most unseen time a stitch may cross — a grip dropout, not the strap coming off. */
    internal const val stitchMaxDropoutS: Long = 10 * 60

    /** Minutes of [start]..[end] holding at least [gaitMinuteTicks] gait seconds, as a per-minute flag. */
    internal fun walkingMinutes(start: Long, end: Long, gaitTs: List<Long>): BooleanArray {
        if (end < start) return BooleanArray(0)
        val ticks = IntArray(((end - start) / 60 + 1).toInt())
        for (t in gaitTs) if (t in start..end) ticks[((t - start) / 60).toInt()]++
        return BooleanArray(ticks.size) { ticks[it] >= gaitMinuteTicks }
    }

    /** May the rest between two non-walking pieces be bridged? Twin of Swift `canStitchGap`. */
    internal fun canStitchGap(a: Long, b: Long, hasGaitEvidence: Boolean, gaitTs: List<Long>, hrTs: List<Long>): Boolean {
        if (!hasGaitEvidence || b - a > stitchMaxGapS) return false
        if (b <= a) return true
        val cover = hrCoveragePct(hrTs.filter { it in a..b }, a, b) ?: 0.0
        if (cover < stitchMinGapCoveragePct) {
            val unseenS = ((b - a + 59) / 60 * 60).toDouble() * (100.0 - cover) / 100.0
            if (unseenS > stitchMaxDropoutS.toDouble()) return false
        }
        var run = 0
        for (walking in walkingMinutes(a, b, gaitTs)) {
            run = if (walking) run + 1 else 0
            if (run * 60 >= gaitStreakMinS) return false
        }
        return true
    }

    /**
     * #148: back-date a confirmed run's start over the warm-up. Motion leads HR at the onset of
     * the first effort — cardiac warm-up climbs over minutes, so the HR-AND-motion gate clips the
     * leading "moving but HR not yet elevated" stretch (the reporter's first 10-15 min). Once a run
     * has ALREADY QUALIFIED on its HR-elevated core, extend the start backward across contiguous
     * above-[motionThreshold] samples, stopping at the first motion gap > [mergeGapS] (a real pause)
     * or the series start. Same motion gate as detection — recovers the warm-up without inventing
     * activity, and can't bridge a genuine rest into the workout. [coreStart] is an active-sample ts,
     * so it exists in [motionTs]; [smooth] is index-aligned to [motionTs].
     */
    internal fun backdatedStart(coreStart: Long, motionTs: List<Long>, smooth: List<Double>): Long {
        // indexOfFirst (not binarySearch): mirrors Swift's firstIndex exactly, so duplicate same-second
        // motion timestamps resolve to the SAME index on both platforms (byte-parity).
        var i = motionTs.indexOfFirst { it >= coreStart }
        if (i !in motionTs.indices) return coreStart
        var start = coreStart
        var prevTs = motionTs[i]
        while (i > 0) {
            i--
            if (smooth[i] <= motionThreshold) break                    // motion dropped → warm-up start
            if ((prevTs - motionTs[i]).toDouble() > mergeGapS) break   // real pause → stop
            start = motionTs[i]
            prevTs = motionTs[i]
        }
        return start
    }

    // ---- Public API ----

    /**
     * Detect workouts from the 1 Hz HR + gravity store. Twin of Swift `WorkoutDetector.detect`: the same
     * gates, the same splitting (elevated cores, walking-streak pieces), the same back-dating and the same
     * stitch, so both platforms return the same sessions for the same streams.
     *
     * Not yet twinned (pre-existing, from the Swift side of 09baea0b / b0e54e9f): each session's zones,
     * Effort and calories here weight samples equally, where Swift weights them by credited seconds and
     * passes Effort a minimum span. At 1 Hz the two agree; across gaps they can differ.
     *
     * @param hr heart-rate stream (required; empty → []).
     * @param gravity gravity stream (required; empty → []).
     * @param restingHR day resting-HR baseline (bpm). null → derived as the 10th
     *   percentile of the day's HR.
     * @param maxHR HRmax (bpm). null → estimated via StrainScorer.estimateHRmax.
     * @param age used only for the Tanaka fallback when maxHR is null.
     * @param profile when provided, per-bout calories are estimated.
     * @param steps the strap's step stream. A second tagged walk or run passes the motion gate even when
     *   the gravity delta does not, and walking streaks cut a bout into pieces. null keeps the gravity-only
     *   gate and no gait splitting.
     */
    fun detect(
        hr: List<HrSample>,
        gravity: List<GravitySample>,
        restingHR: Double? = null,
        maxHR: Double? = null,
        age: Double? = null,
        profile: UserProfile? = null,
        // #1545: TRIMP recipe for each bout's Effort (see the Swift twin).
        effortMethod: StrainScorer.Method = StrainScorer.Method.EDWARDS,
        // #1545: receives the gate-by-gate counts for THIS call.
        funnel: ((DetectionFunnel) -> Unit)? = null,
        steps: List<StepSample>? = null,
    ): List<ExerciseSession> {
        val f = DetectionFunnel()
        try {
            val hrSeg = cleanHR(hr)
            val motion = activitySeries(gravity)
            f.hrSamples = hrSeg.size
            f.motionSamples = motion.size
            if (hrSeg.isEmpty() || motion.isEmpty()) return emptyList()

            val restHR = restingHR ?: deriveRestingHR(hrSeg)
            val hrFloor = restHR + hrMarginBPM
            f.restingHR = restHR
            f.hrFloor = hrFloor

            val effMaxHR: Double?
            val hrmaxSource: String
            if (maxHR != null) {
                effMaxHR = maxHR
                hrmaxSource = "caller"
            } else {
                val (est, src) = StrainScorer.estimateHRmax(hrSeg.map { it.bpm.toDouble() }, age)
                effMaxHR = if (est == 0.0) null else est
                hrmaxSource = src
            }

            val hrTs = hrSeg.map { it.ts }
            val hrBpm = hrSeg.map { it.bpm.toDouble() }
            val smooth = smoothedIntensity(motion, motionSmoothS)
            val motionTs = motion.map { it.ts }
            // 2026-09-26 (Swift): the strap's gait tag is a direct walking signal; a quiet-arm walk passes.
            val gaitTs = (steps ?: emptyList()).asSequence().filter { isGait(it.activityClass) }.map { it.ts }.toHashSet()

            val activeTs = ArrayList<Long>()
            for (idx in motion.indices) {
                val p = motion[idx]
                if (smooth[idx] <= motionThreshold && p.ts !in gaitTs) continue
                f.motionPassed++
                val bpm = nearest(hrTs, hrBpm, p.ts, alignToleranceS)
                if (bpm == null) { f.hrMissing++; continue }
                if (bpm <= hrFloor) { f.hrTooLow++; continue }
                activeTs.add(p.ts)
            }
            f.active = activeTs.size
            if (activeTs.isEmpty()) return emptyList()

            val rawRuns = ArrayList<Pair<Long, Long>>()
            var runStart = activeTs[0]
            var prev = activeTs[0]
            for (k in 1 until activeTs.size) {
                val ts = activeTs[k]
                if ((ts - prev).toDouble() > mergeGapS) { rawRuns.add(runStart to prev); runStart = ts }
                prev = ts
            }
            rawRuns.add(runStart to prev)
            f.runs = rawRuns.size

            val runs = bridgeRuns(rawRuns, hrSeg, hrFloor)
            f.bridged = runs.size
            if (runs.isNotEmpty()) {
                val durs = runs.map { maxOf(0L, it.second - it.first) }
                f.longestRunS = durs.max().toInt()
                f.meanRunS = (durs.sum() / durs.size).toInt()
            }

            val minDurS = minExerciseMin * 60.0
            // Every reported stat comes from one window, so a stitched or back-dated session cannot show
            // zones from its core beside avg HR and calories from the whole.
            fun makeSession(from: Long, to: Long, activityTier: Boolean): ExerciseSession? {
                val window = hrSeg.filter { it.ts in from..to }
                if (window.isEmpty()) return null
                var zones: Map<Int, Double> = emptyMap()
                var hrr: Double? = null
                val m = effMaxHR
                if (m != null && m > restHR) { val (z, h) = boutIntensity(window, restHR, m); zones = z; hrr = h }
                var kcal: Double? = null
                var kj: Double? = null
                if (profile != null) {
                    val (k, j) = Calories.estimateBoutCalories(window, profile, effMaxHR, restHR)
                    kcal = k; kj = j
                }
                return ExerciseSession(
                    start = from, end = to,
                    avgHR = window.sumOf { it.bpm.toDouble() } / window.size.toDouble(),
                    peakHR = window.maxOf { it.bpm },
                    strain = StrainScorer.strain(window, effMaxHR, restHR, effortMethod, profile?.sex ?: "male"),
                    durationS = (to - from).toDouble(),
                    zoneTimePct = zones, avgHRRPct = hrr, hrmax = effMaxHR, hrmaxSource = hrmaxSource,
                    caloriesKcal = kcal, caloriesKJ = kj,
                    hrCoveragePct = hrCoveragePct(window.map { it.ts }, from, to),
                    isActivityTier = activityTier,
                )
            }
            fun z2plus(z: Map<Int, Double>): Double = (2..5).sumOf { z[it] ?: 0.0 } / 100.0

            data class Entry(val start: Long, val end: Long, val coreSplit: Boolean, val gaitSplit: Boolean, val root: Int)
            val queue = ArrayList(runs.mapIndexed { i, r -> Entry(r.first, r.second, true, true, i) })
            val splitRoots = HashSet<Int>()
            val keptRoots = HashSet<Int>()
            val gaitSorted = gaitTs.sorted()
            val sessions = ArrayList<ExerciseSession>()
            var qi = 0
            var prevRunEnd = Long.MIN_VALUE
            while (qi < queue.size) {
                val (start, end, coreSplit, gaitSplit, root) = queue[qi]
                val isRun = coreSplit && gaitSplit
                qi++
                val backdateFloor = prevRunEnd
                if (isRun) prevRunEnd = end + 1
                if ((end - start).toDouble() < minDurS - motionSmoothS) { if (isRun) f.droppedShort++; continue }
                val core = hrSeg.filter { it.ts in start..end }
                if (core.isEmpty()) { f.droppedNoHR++; continue }

                var zonePct: Map<Int, Double> = emptyMap()
                val m = effMaxHR
                if (m != null && m > restHR) zonePct = boutIntensity(core, restHR, m).first

                var isActivityTier = false
                // Fail closed (Swift b0e54e9f): with no usable HRmax there are no zones, so z2+ reads 0 and
                // the run must pass the gates below, which also need an HRmax.
                if (z2plus(zonePct) < minIntensityZ2Plus) {
                    if (m != null && m > restHR && (end - start).toDouble() >= activityMinMin * 60.0 - motionSmoothS) {
                        val activityFloor = restHR + activityHRRFraction * (m - restHR)
                        val elevated = core.count { it.bpm.toDouble() > activityFloor }
                        val frac = elevated.toDouble() / core.size.toDouble()
                        isActivityTier = frac >= (if (gaitSplit) activityElevatedFrac else pieceElevatedFrac)
                    }
                    if (!isActivityTier) {
                        if (coreSplit && m != null && m > restHR) {
                            val cores = elevatedCores(core, restHR + activityHRRFraction * (m - restHR))
                            if (cores.any { (it.second - it.first).toDouble() >= activityMinMin * 60.0 - motionSmoothS }) {
                                if (isRun) f.splitRuns++
                                splitRoots.add(root)
                                queue.addAll(qi, cores.map { Entry(it.first, it.second, false, gaitSplit, root) })
                                continue
                            }
                        }
                        if (isRun) f.droppedLowIntensity++
                        continue
                    }
                }

                if (gaitSplit) {
                    val pieces = gaitPieces(start, end, gaitSorted) { a, b ->
                        val mm = effMaxHR
                        if (mm == null || mm <= restHR) true
                        else z2plus(boutIntensity(hrSeg.filter { it.ts in a..b }, restHR, mm).first) < minIntensityZ2Plus
                    }
                    if (pieces != null) {
                        if (isRun) f.splitRuns++
                        splitRoots.add(root)
                        queue.addAll(qi, pieces.map { Entry(it.first, it.second, coreSplit, false, root) })
                        continue
                    }
                }

                // Only a bridged run is back-dated over its warm-up, never past the previous run's end (#148).
                val effStart = if (isRun) maxOf(backdatedStart(start, motionTs, smooth), backdateFloor) else start
                val session = makeSession(effStart, end, isActivityTier)
                if (session == null) { f.droppedNoHR++; continue }
                sessions.add(session)
                keptRoots.add(root)
                if (!isRun) f.splitKept++
            }
            f.splitDropped = (splitRoots - keptRoots).size

            // Rejoin pieces of one session that a low-HR rest (or a grip dropout) split apart. A walk piece
            // is never a side of a join, and a walking streak in the gap blocks it.
            fun isWalk(w: ExerciseSession): Boolean {
                val minutes = walkingMinutes(w.start, w.end, gaitSorted)
                val frac = minutes.count { it }.toDouble() / maxOf(1, minutes.size).toDouble()
                return frac >= stitchWalkMinuteFrac && z2plus(w.zoneTimePct) < minIntensityZ2Plus
            }
            val hasGaitEvidence = (steps ?: emptyList()).any { it.activityClass != null }
            val stitched = ArrayList<ExerciseSession>()
            for (w in sessions.sortedBy { it.start }) {
                val last = stitched.lastOrNull()
                val joined = if (last != null && !isWalk(last) && !isWalk(w) &&
                    canStitchGap(last.end, w.start, hasGaitEvidence, gaitSorted, hrTs)
                ) makeSession(last.start, maxOf(last.end, w.end), last.isActivityTier && w.isActivityTier) else null
                if (joined != null) stitched[stitched.size - 1] = joined else stitched.add(w)
            }
            f.kept = stitched.size
            f.keptActivity = stitched.count { it.isActivityTier }
            return stitched
        } finally {
            funnel?.invoke(f)
        }
    }

    /**
     * 2026-09-21: deterministic `{"z1":…,"z5":…}` serialization of a bout's [zoneTimePct] map for
     * `WorkoutRow.zonesJSON` — the same object shape the WHOOP CSV importer writes, so a detected row
     * renders zones exactly like an imported one. Keys are emitted in fixed z1…z5 order; zone 0
     * (below-zone-1 time) is dropped, matching the import contract that exports only z1…z5. Returns
     * null when no zone-1+ content exists so the row keeps `zonesJSON = null`, the same behavior an
     * import with no zone columns has. Byte-parity twin of Swift `WorkoutDetector.zonesJSON(from:)`.
     */
    fun zonesJSON(zoneTimePct: Map<Int, Double>): String? {
        val parts = ArrayList<String>(5)
        var any = false
        for (z in 1..5) {
            val v = zoneTimePct[z] ?: 0.0
            if (v > 0) any = true
            parts.add("\"z$z\":$v")
        }
        return if (any) "{" + parts.joinToString(",") + "}" else null
    }
}

/**
 * HR-based calorie estimation (Keytel 2005 active + revised Harris–Benedict BMR).
 * APPROXIMATE — not laboratory calorimetry, not medical advice.
 *
 * Faithful port of the `Calories` enum that ships inside WorkoutDetector.swift.
 */
object Calories {
    /** Whole-day BMR + activity-above-rest split over supported sample intervals. */
    data class DayEnergyEstimate(
        val restingKcal: Double,
        val activeKcal: Double,
        val observedSeconds: Double,
    ) {
        val totalKcal: Double get() = restingKcal + activeKcal
    }


    /** Sex-specific BMR + active-EE coefficients. Mirrors Swift `Calories.Coeffs`. */
    data class Coeffs(
        val restingAlpha: Double,
        val restingWeight: Double,
        /** Applied to height in METRES. */
        val restingHeight: Double,
        val restingAge: Double,
        // Keytel 2005 base (fitness-blind) active model: EE(kJ/min) = alpha + hr·HR + wt·W + age·A.
        val workoutHR: Double,
        val workoutWeight: Double,
        val workoutAge: Double,
        val workoutAlpha: Double,
        // Keytel 2005 fitness-ADJUSTED active model, which reads VO2max and is the more accurate form
        // the authors published: EE(kJ/min) = fitAlpha + fitHR·HR + fitVO2·VO2max + fitWeight·W + fitAge·A.
        // Used only when a resting HR is known (so a Uth VO2max can be derived); otherwise the base
        // workout* model above, unchanged. (Keytel et al. 2005, J. Sports Sci. 23(3).)
        val fitHR: Double,
        val fitVO2: Double,
        val fitWeight: Double,
        val fitAge: Double,
        val fitAlpha: Double,
    )

    val male = Coeffs(
        restingAlpha = 88.362, restingWeight = 13.397, restingHeight = 479.9,
        restingAge = 5.677, workoutHR = 0.6309, workoutWeight = 0.1988,
        workoutAge = 0.2017, workoutAlpha = -55.0969,
        fitHR = 0.634, fitVO2 = 0.404, fitWeight = 0.394, fitAge = 0.271, fitAlpha = -95.7735,
    )
    val female = Coeffs(
        restingAlpha = 447.593, restingWeight = 9.247, restingHeight = 309.8,
        restingAge = 4.33, workoutHR = 0.4472, workoutWeight = -0.1263,
        workoutAge = 0.0740, workoutAlpha = -20.4022,
        fitHR = 0.450, fitVO2 = 0.380, fitWeight = 0.103, fitAge = 0.274, fitAlpha = -59.3954,
    )
    // Nonbinary = the male/female midpoint, the same convention the base workout* coeffs use.
    val nonbinary = Coeffs(
        restingAlpha = 267.9775, restingWeight = 11.322, restingHeight = 394.85,
        restingAge = 5.0035, workoutHR = 0.53905, workoutWeight = 0.03625,
        workoutAge = 0.13785, workoutAlpha = -37.74955,
        fitHR = 0.542, fitVO2 = 0.392, fitWeight = 0.2485, fitAge = 0.2725, fitAlpha = -77.58445,
    )

    const val activeHRRFraction: Double = 0.30

    /**
     * Whole-day active gate ([estimateDayCalories] only). The Keytel 2005 equation is
     * validated for genuine EXERCISE HR; applying it to ordinary low-intensity daytime HR
     * (walking, stairs, standing — typically ~95–110 bpm) across the WHOLE day credits the
     * full gross-exercise rate to every elevated second and over-counts by ~1000+ kcal
     * (community "Calories too high"). The bout path keeps the 0.30 detector fraction —
     * Keytel is appropriate for a real detected/manual workout — but the day path raises the
     * gate to 50% HRR so the gross rate only applies at genuine exercise-level HR. Used only when no awake
     * resting HR is known ([UserProfile.awakeRestingHR]); see [dayActiveAwakeHRRFraction].
     */
    const val dayActiveHRRFraction: Double = 0.50
    /**
     * Whole-day active gate once an awake resting HR is known: the flex point of the Flex-HR method
     * (Spurr et al. 1988; Ceesay et al. 1989), below which heart rate does not track energy and resting
     * energy is used. 30% of the heart-rate reserve above the AWAKE resting HR is the ACSM lower bound
     * of light-intensity activity (Garber et al. 2011, Table 4: 2 METs, 57% HRmax), the lowest stage
     * Keytel 2005 was fitted on. The sleeping floor is not a resting HR for this purpose: 50% above it
     * sat near 121 bpm on real data (62% HRmax), so ordinary walking credited nothing and a 6,400-step
     * day read 6 kcal active against 409 on an Apple Watch. Twin of Swift `Calories.dayActiveAwakeHRRFraction`.
     */
    const val dayActiveAwakeHRRFraction: Double = 0.30
    /**
     * Longest gap one reading may count toward `observedSeconds`, the day's coverage figure. Resting energy
     * is BMR over the credited span whatever the strap saw, and ACTIVE energy is capped tighter, at the
     * inferred cadence (see [estimateDayEnergy]): a gap is evidence of a missing sensor, never of exercise.
     */
    const val dayMaxObservedGapS: Double = 60.0
    const val dayMaxObservedSpanS: Double = 86_400.0
    const val workoutDivisor: Double = 251.04 // 60 s/min × 4.184 kJ/kcal

    fun resolveCoeffs(sex: String): Coeffs = when (sex.lowercase()) {
        "male" -> male
        "female" -> female
        "nonbinary" -> nonbinary
        else -> nonbinary
    }

    fun restingKcalPerS(c: Coeffs, weightKg: Double, heightCm: Double, age: Double): Double {
        val heightM = heightCm / 100.0
        val bmr = c.restingAlpha + c.restingWeight * weightKg + c.restingHeight * heightM - c.restingAge * age
        return maxOf(0.0, bmr) / 86_400.0
    }

    /**
     * Resting HR while awake: the Stress Monitor's own wake reference, the median of the prior days' wake
     * floors. A single day's floor is never used (real data stored 120.7 bpm for a day), so too little
     * history gives null rather than one day's value. Twin of Swift `Calories.awakeRestingHR`.
     */
    fun awakeRestingHR(priorFloors: List<Double?>): Double? =
        StressMonitor.wakeReference(priorFloors, todayFloor = null)?.floorHR

    /**
     * Uth–Sørensen VO2max estimate (ml·kg⁻¹·min⁻¹) ≈ 15.3 · HRmax / HRrest. Returns null when no
     * usable resting HR — the caller then keeps the base (fitness-blind) Keytel model, so a strap with
     * no resting baseline is scored exactly as before. A function of HRmax + resting HR ONLY, so every
     * call site resolves it locally and day derivation stays deterministic (no cross-day dependency).
     * (Uth et al. 2004, Eur. J. Appl. Physiol. 91.)
     */
    fun vo2maxFor(hrmax: Double, restingHR: Double?): Double? {
        if (restingHR == null || restingHR <= 0.0 || hrmax <= 0.0) return null
        return 15.3 * hrmax / restingHR
    }

    /**
     * Active energy rate (kcal/s). With [vo2max] present, uses the Keytel 2005 fitness-ADJUSTED
     * equation (personalizes beyond age/weight/sex); with null, the base fitness-blind Keytel model,
     * byte-identical to before. HR is capped at HRmax in both, as the base model always did.
     */
    fun activeKcalPerS(c: Coeffs, hr: Double, hrmax: Double, weightKg: Double, age: Double, vo2max: Double? = null): Double {
        val eeKjMin = if (vo2max != null) {
            c.fitHR * minOf(hr, hrmax) + c.fitVO2 * vo2max + c.fitWeight * weightKg +
                c.fitAge * age + c.fitAlpha
        } else {
            c.workoutHR * minOf(hr, hrmax) + c.workoutWeight * weightKg +
                c.workoutAge * age + c.workoutAlpha
        }
        return maxOf(0.0, eeKjMin) / workoutDivisor
    }

    /**
     * Estimate (kcal, kJ) for a workout bout. Each sample is weighted by the ELAPSED time to
     * the next sample (capped at [mergeGapS]), so a sparse, non-1 Hz stream is counted over
     * real seconds rather than undercounted as one second per sample.
     *
     * This elapsed-time weighting is justified ONLY for the bout path: a bout's intra-sample
     * gaps are motion-gated and ≤ [mergeGapS] (150 s) by construction, so each gap really is
     * continuous active/resting time. The whole-day estimator deliberately does NOT use it
     * (see [estimateDayCalories]) — its raw, non-gap-filled day HR union would otherwise
     * credit up to 150 s of active burn to a single isolated elevated sample.
     *
     * @param hrSamples the bout's HR samples (any order; sorted by ts here).
     * @param profile weight/height/age/sex for the BMR + active-EE coefficients.
     * @param hrmax effective HRmax (bpm); null → 220.
     * @param restingHR resting HR (bpm); null → 60.
     */
    fun estimateBoutCalories(
        hrSamples: List<HrSample>,
        profile: UserProfile,
        hrmax: Double?,
        restingHR: Double?,
    ): Pair<Double, Double> {
        val weightKg = if (profile.weightKg > 0) profile.weightKg else 70.0
        val heightCm = if (profile.heightCm > 0) profile.heightCm else 170.0
        val age = if (profile.age > 0) profile.age else 30.0
        val coeffs = resolveCoeffs(profile.sex)

        val effHRmax = hrmax ?: 220.0
        val effResting = restingHR ?: 60.0
        val activeThreshold = effResting + activeHRRFraction * (effHRmax - effResting)

        val restingRate = restingKcalPerS(coeffs, weightKg, heightCm, age)
        // Fitness anchor (Uth VO2max) when a resting HR is known → the Keytel fitness-adjusted rate;
        // null restingHR → base model, unchanged. Computed once (constant across the bout).
        val vo2max = vo2maxFor(effHRmax, restingHR)

        // Weight each sample by the ACTUAL elapsed time to the next sample, not a flat 1 s.
        // restingRate / activeKcalPerS are per-SECOND rates, so summing one per sample only
        // equals real energy when the stream is exactly 1 Hz. A sparse WHOOP 5/MG bout can run
        // far below 1 sample/s, which previously undercounted energy roughly in proportion to
        // the coverage gap (calories collapsing toward ~1 kcal, #137). Each interval is capped
        // at mergeGapS (150 s) — the detector's own "still continuous, not resting" threshold —
        // so a brief dropout is fully counted but a wear gap can't inflate one reading. At a
        // steady 1 Hz every interval is ~1 s: behaviour is unchanged.
        val ordered = hrSamples.sortedBy { it.ts }
        var totalKcal = 0.0
        for (i in ordered.indices) {
            val bpm = ordered[i].bpm.toDouble()
            val dur: Double = if (i < ordered.size - 1) {
                val gap = (ordered[i + 1].ts - ordered[i].ts).toDouble()
                if (gap > 0) min(gap, WorkoutDetector.mergeGapS) else 1.0
            } else {
                1.0 // last sample carries one representative second
            }
            totalKcal += if (bpm < activeThreshold) {
                restingRate * dur
            } else {
                activeKcalPerS(coeffs, bpm, effHRmax, weightKg, age, vo2max) * dur
            }
        }
        return totalKcal to (totalKcal * 4.184)
    }

    /**
     * APPROXIMATE whole-day resting + active energy estimate from the full day's HR
     * samples. Supported high-HR intervals add only the Keytel energy ABOVE the resting floor.
     *
     * Without an awake resting HR the gate is [dayActiveHRRFraction] (50% HRR above the caller's
     * resting HR). At 30% of the reserve above the SLEEPING floor the gate fell to ~94 bpm and
     * ordinary daytime HR over-counted by ~1000+ kcal (community "Calories too high"). Measured from
     * the awake resting HR, 30% is the flex point instead (see [dayActiveAwakeHRRFraction]).
     *
     * Cadence is inferred from the median positive timestamp gap and capped at
     * [dayMaxObservedGapS]. A high-HR sample carries active energy to the next sample for at
     * most that cadence, never a whole disconnect, so a 30 s sparse stream and a 1 Hz stream
     * covering the same activity produce comparable energy.
     *
     * Resting energy is BMR over [creditedSeconds] (the whole span when null, whatever the strap saw):
     * metabolism does not stop when the strap comes off. `observedSeconds` reports coverage and does not
     * scale either figure.
     *
     * With [UserProfile.awakeRestingHR] the gate is [dayActiveAwakeHRRFraction] above that awake HR, and
     * the Keytel fitness term reads [UserProfile.vo2max], else Uth on the awake HR. Uth 2004 measured
     * resting HR awake and supine, so the sleeping floor overstated VO2max by about half on real data (64
     * against a measured 42 ml/kg/min). Without an awake HR the day keeps the old inputs:
     * [dayActiveHRRFraction] above the caller's resting HR and Uth on it.
     *
     * This is an on-device estimate from heart rate alone — NOT laboratory calorimetry,
     * NOT Apple/WHOOP cloud parity, NOT medical advice. Twin of Swift `Calories.estimateDayEnergy`.
     *
     * @param hrSamples the whole day's timestamped HR samples.
     * @param profile weight/height/age/sex for the BMR + active-EE coefficients, plus the energy anchors.
     * @param hrmax effective HRmax (bpm); null → 220.
     * @param restingHR resting HR (bpm); null → 60.
     * @param creditedSeconds seconds of BMR to credit; null → [maxSpanSeconds].
     */
    fun estimateDayEnergy(
        hrSamples: List<HrSample>,
        profile: UserProfile,
        hrmax: Double?,
        restingHR: Double?,
        maxSpanSeconds: Double = 86_400.0,
        creditedSeconds: Double? = null,
    ): DayEnergyEstimate {
        if (hrSamples.isEmpty()) return DayEnergyEstimate(0.0, 0.0, 0.0)

        val weightKg = if (profile.weightKg > 0) profile.weightKg else 70.0
        val heightCm = if (profile.heightCm > 0) profile.heightCm else 170.0
        val age = if (profile.age > 0) profile.age else 30.0
        val coeffs = resolveCoeffs(profile.sex)

        val effHRmax = hrmax ?: 220.0
        val awake = profile.awakeRestingHR?.takeIf { it > 0.0 }
        val referenceHR = awake ?: restingHR
        val effResting = referenceHR ?: 60.0
        val gateFraction = if (awake == null) dayActiveHRRFraction else dayActiveAwakeHRRFraction
        val activeThreshold = effResting + gateFraction * (effHRmax - effResting)

        val restingRate = restingKcalPerS(coeffs, weightKg, heightCm, age)
        // Fitness anchor for the Keytel fitness-adjusted rate, constant across the day. No resting HR at
        // all → the base model. A measured VO2max is used only beside an awake HR, so a day without one
        // is scored exactly as before.
        val vo2max = (if (awake == null) null else profile.vo2max) ?: vo2maxFor(effHRmax, referenceHR)

        // Ties are REACHABLE: hrSample is keyed (deviceId, ts) and the day feed unions devices, so a
        // two-strap day carries two readings for the same second. Only the LAST of a tied run gets the
        // interval (the earlier ones measure a zero gap), so tie order decides the day's active energy.
        // Ordering ties by DESCENDING bpm hands the interval to the LOWER reading — the conservative
        // direction for a path whose history is over-counting. Sorting on ts alone left this to the
        // sort's stability, which Kotlin guarantees and Swift explicitly does not.
        val ordered = hrSamples.sortedWith(compareBy<HrSample> { it.ts }.thenByDescending { it.bpm })
        val positiveGaps = ordered.zipWithNext { a, b -> (b.ts - a.ts).toDouble() }
            .filter { it > 0.0 }
            .sorted()
        val nominalSampleS = if (positiveGaps.isEmpty()) {
            1.0
        } else {
            val mid = positiveGaps.size / 2
            val median = if (positiveGaps.size % 2 == 0) {
                (positiveGaps[mid - 1] + positiveGaps[mid]) / 2.0
            } else {
                positiveGaps[mid]
            }
            minOf(median, dayMaxObservedGapS)
        }
        val observedSeconds = minOf(
            maxOf(0.0, maxSpanSeconds),
            positiveGaps.fold(nominalSampleS) { total, gap ->
                total + minOf(gap, dayMaxObservedGapS)
            },
        )
        val restingKcal = restingRate * maxOf(0.0, creditedSeconds ?: maxSpanSeconds)

        var activeKcal = 0.0
        for (i in ordered.indices) {
            // Active carry is capped at the INFERRED CADENCE, not at the wider resting cap. A 30 s
            // stream still carries its full 30 s (the cadence bug this fixes), and a 1 Hz day carries
            // 1 s so the legacy total is reproduced exactly — but a dropout in an otherwise dense day
            // no longer credits a full minute of exercise to the last reading before it. That was the
            // objection the flat one-second model was written to avoid, and capping active at the
            // cadence answers it rather than narrowing it from 150 s to 60 s.
            val durationS = if (i < ordered.size - 1) {
                val gap = (ordered[i + 1].ts - ordered[i].ts).toDouble()
                if (gap > 0.0) minOf(gap, nominalSampleS) else 0.0
            } else {
                nominalSampleS
            }
            val bpm = ordered[i].bpm.toDouble()
            if (bpm < activeThreshold) continue
            val grossRate = activeKcalPerS(coeffs, bpm, effHRmax, weightKg, age, vo2max)
            activeKcal += maxOf(0.0, grossRate - restingRate) * durationS
        }
        return DayEnergyEstimate(restingKcal, activeKcal, observedSeconds)
    }

    /** Backward-compatible total-kcal facade for the stored daily metric. */
    fun estimateDayCalories(
        hrSamples: List<HrSample>,
        profile: UserProfile,
        hrmax: Double?,
        restingHR: Double?,
    ): Double {
        return estimateDayEnergy(hrSamples, profile, hrmax, restingHR).totalKcal
    }
}
