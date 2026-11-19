import Foundation

public enum DayCycleMode: String, CaseIterable, Sendable {
    case sleepOnset = "sleep_onset"
    case midnight = "midnight"

    public static let storageKey = "noop.dayCycleMode"
    /// Kotlin twin: `DayCycleMode.fromPersisted`.
    public static func persisted(_ value: String?) -> DayCycleMode {
        value.flatMap(Self.init(rawValue:)) ?? .sleepOnset
    }
}

public struct DayCycleWindow: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case detectedSleep, editedSleep, syntheticMidnight, calendar }
    public let id: String
    public let startInclusive: Int
    public let endExclusive: Int
    public let displayDay: String
    public let source: Source

    public init(id: String, startInclusive: Int, endExclusive: Int, displayDay: String, source: Source) {
        self.id = id; self.startInclusive = startInclusive; self.endExclusive = endExclusive
        self.displayDay = displayDay; self.source = source
    }
}

public enum DayCycleResolver {
    public static let minSyntheticMidnightAgeSeconds = 18 * 3_600
    public static let absoluteMaxOpenSeconds = 40 * 3_600

    /// Kotlin twin: `DayCycleResolver.calendarWindow`.
    public static func calendarWindow(now: Int, offsetSec: Int) -> DayCycleWindow {
        let local = now + offsetSec
        let dayNumber = Int(floor(Double(local) / Double(SleepStageTotals.secondsPerDay)))
        let start = dayNumber * SleepStageTotals.secondsPerDay - offsetSec
        let day = AnalyticsEngine.dayString(start, offsetSec: offsetSec)
        return DayCycleWindow(id: "calendar:\(day)", startInclusive: start, endExclusive: now,
                              displayDay: day, source: .calendar)
    }

    /// Kotlin twin: `DayCycleResolver.fallbackMidnightAfter`.
    public static func fallbackMidnight(after start: Int, offsetSec: Int) -> Int {
        let minimum = start + minSyntheticMidnightAgeSeconds
        let local = minimum + offsetSec
        let dayNumber = Int(floor(Double(local) / Double(SleepStageTotals.secondsPerDay)))
        let midnight = dayNumber * SleepStageTotals.secondsPerDay - offsetSec
        return midnight >= minimum ? midnight : (dayNumber + 1) * SleepStageTotals.secondsPerDay - offsetSec
    }

    /// A cycle boundary with the calendar day whose row it fills (the day its main sleep ends on).
    public struct WakeDayBoundary: Equatable, Sendable {
        public let sleepId: String
        public let onset: Int
        public let wakeDay: String
        public init(sleepId: String, onset: Int, wakeDay: String) {
            self.sleepId = sleepId; self.onset = onset; self.wakeDay = wakeDay
        }
    }

    /// A calendar day that no main sleep ends on, cut out of the cycle that would otherwise run across it.
    public struct UncoveredDay: Equatable, Sendable {
        /// `synthetic:<day>`, the same id the open-cycle cap in `activeWindow` gives the same day.
        public let sleepId: String
        /// Local midnight at the start of `day`.
        public let onset: Int
        public let day: String
        /// The boundary whose cycle the day was cut from.
        public let splitFrom: String
    }

    /// Calendar days that fall strictly between two consecutive wake days, or between the last wake day
    /// and the calendar day of `now`, each with a boundary at its own local midnight.
    ///
    /// A night with no detected main sleep (strap on the charger, a night spent awake) has no boundary,
    /// so the cycle before it ran to the NEXT night's onset: one row carried two days of steps, Effort and
    /// energy and the following row was empty (2026-11-08 and 2026-11-13 on real data). Cutting at the
    /// orphan day's midnight is the window the Home screens already read for that day, since a day with
    /// no onset marker falls back to its calendar bound. Consecutive wake days yield nothing, so ordinary
    /// cycles are unchanged. Only days that have fully started are cut, and the day of `now` is never
    /// cut by this rule: a sleep ending later today may still claim it. The live cap in `activeWindow`
    /// covers the open cycle before that, and its boundary must be passed in so the day counts as claimed.
    ///
    /// Kotlin twin: `DayCycleResolver.uncoveredDays`.
    public static func uncoveredDays(_ boundaries: [WakeDayBoundary], now: Int,
                                     offsetSec: Int) -> [UncoveredDay] {
        var ids = Set<String>()
        let ordered = boundaries.filter { $0.onset <= now && ids.insert($0.sleepId).inserted }
            .sorted { $0.onset != $1.onset ? $0.onset < $1.onset : $0.sleepId < $1.sleepId }
        let claimed = Set(ordered.map(\.wakeDay))
        let today = AnalyticsEngine.dayString(now, offsetSec: offsetSec)
        var output: [UncoveredDay] = []
        for index in ordered.indices {
            let item = ordered[index]
            let nextDay = index + 1 < ordered.count ? ordered[index + 1].wakeDay : today
            let nextOnset = index + 1 < ordered.count ? ordered[index + 1].onset : now
            let dayStart = AnalyticsEngine.dayStartUtcSeconds(item.wakeDay)
            // A malformed key parses to 0; walking from 1970 would invent decades of days.
            guard AnalyticsEngine.dayString(dayStart) == item.wakeDay else { continue }
            var midnight = dayStart + SleepStageTotals.secondsPerDay - offsetSec
            while midnight < nextOnset {
                let day = AnalyticsEngine.dayString(midnight, offsetSec: offsetSec)
                guard day < nextDay else { break }
                if midnight > item.onset && !claimed.contains(day) {
                    output.append(UncoveredDay(sleepId: "synthetic:\(day)", onset: midnight, day: day,
                                               splitFrom: item.sleepId))
                }
                midnight += SleepStageTotals.secondsPerDay
            }
        }
        return output
    }

    /// Kotlin twin: `DayCycleResolver.activeWindow`.
    public static func activeWindow(mode: DayCycleMode, latestSleep: DayCycleWindow?, now: Int,
                                    offsetSec: Int) -> DayCycleWindow {
        guard mode == .sleepOnset, let latestSleep else { return calendarWindow(now: now, offsetSec: offsetSec) }
        let age = now - latestSleep.startInclusive
        let fallback = fallbackMidnight(after: latestSleep.startInclusive, offsetSec: offsetSec)
        // Sleep-onset mode stays anchored across midnight unconditionally: only the absolute safety cap
        // may synthesize a fallback boundary. An earlier design gated this on whether awake coverage was
        // reliable and carried a `reliableAwakeCoverage` parameter for it; the gate was dropped but the
        // parameter survived, unread on both platforms and passed `false` by every one of its five call
        // sites. Removed rather than left looking like a switch someone could flip.
        guard age < absoluteMaxOpenSeconds else {
            let day = AnalyticsEngine.dayString(fallback, offsetSec: offsetSec)
            return DayCycleWindow(id: "synthetic:\(day)", startInclusive: fallback, endExclusive: now,
                                  displayDay: day, source: .syntheticMidnight)
        }
        return DayCycleWindow(id: latestSleep.id, startInclusive: latestSleep.startInclusive,
                              endExclusive: now, displayDay: latestSleep.displayDay, source: latestSleep.source)
    }
}
