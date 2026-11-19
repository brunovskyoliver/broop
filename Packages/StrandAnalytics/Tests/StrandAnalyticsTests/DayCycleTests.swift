import XCTest
@testable import StrandAnalytics

final class DayCycleTests: XCTestCase {
    func testDefaultsAndCalendarMode() {
        XCTAssertEqual(DayCycleMode.persisted(nil), .sleepOnset)
        XCTAssertEqual(DayCycleMode.persisted("midnight"), .midnight)
        let window = DayCycleResolver.activeWindow(mode: .midnight, latestSleep: nil, now: 86_500,
                                                   offsetSec: 0)
        XCTAssertEqual(window.startInclusive, 86_400)
        XCTAssertEqual(window.source, .calendar)
    }

    func testSleepOnsetCycleStaysOpenAcrossMidnight() {
        let sleep = DayCycleWindow(id: "sleep", startInclusive: 20 * 3_600, endExclusive: 0,
                                   displayDay: "1970-01-01", source: .detectedSleep)
        let fallback = DayCycleResolver.fallbackMidnight(after: sleep.startInclusive, offsetSec: 0)
        XCTAssertEqual(fallback, 2 * 86_400)
        let active = DayCycleResolver.activeWindow(mode: .sleepOnset, latestSleep: sleep,
                                                   now: fallback, offsetSec: 0)
        XCTAssertEqual(active.source, .detectedSleep)
        XCTAssertEqual(active.startInclusive, sleep.startInclusive)
    }

    /// Both branches of the 18-hour fallback rule, which neither platform pinned.
    ///
    /// `fallbackMidnight` returns the first midnight at least `minSyntheticMidnightAgeSeconds` after onset.
    /// Because the candidate is `floor(minimum / day) * day`, it is at or BELOW `minimum` always — so the
    /// direct branch is reachable only on exact equality, when onset sits precisely 18 h before a midnight.
    /// Every existing case here and on Kotlin used an onset that rolls, so a `>=` quietly weakened to `>`
    /// would have moved that boundary a full day and nothing would have failed.
    func testFallbackTakesTheMidnightExactlyEighteenHoursAfterOnset() {
        // 06:00 + 18 h lands exactly on the next midnight: taken directly, not rolled past.
        XCTAssertEqual(DayCycleResolver.fallbackMidnight(after: 6 * 3_600, offsetSec: 0), 86_400)
    }

    /// The rolling branch at a different onset from the case above, so the two are not the same test twice.
    func testFallbackRollsWhenTheNextMidnightIsTooSoon() {
        // 23:00 + 18 h overshoots the next midnight, so the one after it wins.
        XCTAssertEqual(DayCycleResolver.fallbackMidnight(after: 23 * 3_600, offsetSec: 0), 2 * 86_400)
    }

    /// The boundary is LOCAL midnight, not UTC midnight — and until now nothing said so. Every
    /// day-cycle case on both platforms passed a zero offset, so the whole offset arithmetic, which is
    /// the part that decides which local day a boundary lands on, was unpinned. This repo has already
    /// had days re-bucket on travel once, so it is worth a case rather than an argument.
    ///
    /// 06:00 local at UTC-5 is 11:00 UTC. Plus 18 h is 05:00 UTC the next day, which IS local midnight
    /// there, so the direct branch takes it: 104_400 = 29 h UTC = 00:00 local. A resolver that floored
    /// to UTC midnight would answer 86_400 and be a day out for a third of the planet.
    func testFallbackLandsOnLocalMidnightNotUTC() {
        let offsetSec = -5 * 3_600
        let onsetLocal0600 = 6 * 3_600 - offsetSec
        XCTAssertEqual(DayCycleResolver.fallbackMidnight(after: onsetLocal0600, offsetSec: offsetSec),
                       104_400)
    }

    func testAbsoluteCapStillUsesSyntheticMidnight() {
        let sleep = DayCycleWindow(id: "sleep", startInclusive: 0, endExclusive: 0,
                                   displayDay: "1970-01-01", source: .detectedSleep)
        XCTAssertEqual(DayCycleResolver.activeWindow(mode: .sleepOnset, latestSleep: sleep,
                                                     now: 40 * 3_600, offsetSec: 0).source,
                       .syntheticMidnight)
    }

    func testCoverageSegmentsPreferPriorityWithoutCrossingDeviceCounters() {
        let window = PhysiologicalSteps.CycleWindow(sleepId: "night", onset: 100, endExclusive: 500)
        let segments = PhysiologicalSteps.ownerSegmentsFromCoverage(window, coverage: [
            .init(owner: "secondary", onset: 100, endExclusive: 350, priority: 1),
            .init(owner: "active", onset: 200, endExclusive: 500, priority: 0),
        ], fallbackOwner: "secondary")
        XCTAssertEqual(segments, [
            .init(owner: "secondary", onset: 100, endExclusive: 200),
            .init(owner: "active", onset: 200, endExclusive: 500),
        ])
    }

    // MARK: - Sleepless calendar days

    /// Europe/Copenhagen in November (CET), and the real main-sleep onsets from a phone database.
    private static let cet = 3_600
    private static func localMidnight(_ day: String) -> Int {
        AnalyticsEngine.dayStartUtcSeconds(day) - cet
    }
    private static func boundary(_ day: String, _ onset: Int) -> DayCycleResolver.WakeDayBoundary {
        .init(sleepId: "sleep:\(day)", onset: onset, wakeDay: day)
    }

    /// Splits the boundaries the way the integration does and returns the windows each day ends up owning.
    private static func windowsByDay(_ boundaries: [DayCycleResolver.WakeDayBoundary],
                                     now: Int) -> [String: PhysiologicalSteps.CycleWindow] {
        let uncovered = DayCycleResolver.uncoveredDays(boundaries, now: now, offsetSec: cet)
        var dayById = Dictionary(uniqueKeysWithValues: boundaries.map { ($0.sleepId, $0.wakeDay) })
        for item in uncovered { dayById[item.sleepId] = item.day }
        let all = boundaries.map { PhysiologicalSteps.CycleBoundary(sleepId: $0.sleepId, onset: $0.onset) }
            + uncovered.map { PhysiologicalSteps.CycleBoundary(sleepId: $0.sleepId, onset: $0.onset) }
        return Dictionary(uniqueKeysWithValues: PhysiologicalSteps.cycleWindows(all, now: now).map {
            (dayById[$0.sleepId]!, $0)
        })
    }

    /// Strap on the charger overnight: 11-08's cycle (onset 11-07 23:15) ran to 11-09 23:40 and 11-09
    /// had no row. 11-09 now owns its own midnight to the next onset; 11-08 stops at that midnight.
    func testChargerNightGivesTheOrphanDayItsOwnCycle() {
        let boundaries = [Self.boundary("2026-11-07", 1_794_001_906), Self.boundary("2026-11-08", 1_794_089_757),
                          Self.boundary("2026-11-10", 1_794_264_049), Self.boundary("2026-11-11", 1_794_344_183)]
        let now = 1_794_344_183 + 14 * 3_600
        let uncovered = DayCycleResolver.uncoveredDays(boundaries, now: now, offsetSec: Self.cet)
        XCTAssertEqual(uncovered, [.init(sleepId: "synthetic:2026-11-09", onset: Self.localMidnight("2026-11-09"),
                                         day: "2026-11-09", splitFrom: "sleep:2026-11-08")])
        let windows = Self.windowsByDay(boundaries, now: now)
        XCTAssertEqual(windows["2026-11-08"]?.endExclusive, Self.localMidnight("2026-11-09"))
        XCTAssertEqual(windows["2026-11-09"]?.onset, Self.localMidnight("2026-11-09"))
        XCTAssertEqual(windows["2026-11-09"]?.endExclusive, 1_794_264_049)
        XCTAssertEqual(windows["2026-11-10"], .init(sleepId: "sleep:2026-11-10", onset: 1_794_264_049,
                                                    endExclusive: 1_794_344_183))
    }

    /// Awake all night with the strap on: 11-13's cycle (onset 11-13 00:23) ran to 11-14 23:28.
    func testAwakeNightGivesTheOrphanDayItsOwnCycle() {
        let boundaries = [Self.boundary("2026-11-12", 1_794_434_096), Self.boundary("2026-11-13", 1_794_525_825),
                          Self.boundary("2026-11-15", 1_794_695_304), Self.boundary("2026-11-16", 1_794_777_173)]
        let now = 1_794_777_173 + 14 * 3_600
        let windows = Self.windowsByDay(boundaries, now: now)
        XCTAssertEqual(windows["2026-11-13"], .init(sleepId: "sleep:2026-11-13", onset: 1_794_525_825,
                                                    endExclusive: Self.localMidnight("2026-11-14")))
        XCTAssertEqual(windows["2026-11-14"], .init(sleepId: "synthetic:2026-11-14",
                                                    onset: Self.localMidnight("2026-11-14"),
                                                    endExclusive: 1_794_695_304))
        XCTAssertEqual(windows["2026-11-12"]?.endExclusive, 1_794_525_825)
    }

    /// Splitting only adds seams: the windows still tile first onset → now with no gap and no overlap.
    func testSplittingNeitherDropsNorDoubleCountsTime() {
        let boundaries = [Self.boundary("2026-11-08", 1_794_089_757), Self.boundary("2026-11-10", 1_794_264_049),
                          Self.boundary("2026-11-13", 1_794_525_825), Self.boundary("2026-11-15", 1_794_695_304)]
        let now = 1_794_695_304 + 30 * 3_600
        let windows = Self.windowsByDay(boundaries, now: now).values.sorted { $0.onset < $1.onset }
        XCTAssertEqual(windows.first?.onset, 1_794_089_757)
        XCTAssertEqual(windows.last?.endExclusive, now)
        for (a, b) in zip(windows, windows.dropFirst()) { XCTAssertEqual(a.endExclusive, b.onset) }
        XCTAssertEqual(windows.reduce(0) { $0 + $1.endExclusive - $1.onset }, now - 1_794_089_757)
        XCTAssertEqual(Set(Self.windowsByDay(boundaries, now: now).keys), [
            "2026-11-08", "2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13", "2026-11-14",
            "2026-11-15"])
    }

    /// Consecutive wake days add nothing, however long the cycle: a 32 h cycle from a 20:00 onset to a
    /// 04:00 onset two calendar days later is an ordinary late night and the next day has its own row.
    func testConsecutiveWakeDaysAreNeverSplit() {
        let first = Self.localMidnight("2026-11-11") - 4 * 3_600
        let second = Self.localMidnight("2026-11-12") + 4 * 3_600
        XCTAssertEqual(second - first, 32 * 3_600)
        let long = [Self.boundary("2026-11-11", first), Self.boundary("2026-11-12", second)]
        XCTAssertEqual(DayCycleResolver.uncoveredDays(long, now: second + 3_600, offsetSec: Self.cet), [])
    }

    /// Today is never cut by this rule: a sleep ending later today may still claim it. Yesterday, which no
    /// sleep ended on, is.
    func testTodayIsLeftToTheOpenCycle() {
        let onset = Self.localMidnight("2026-11-09") - 3_600
        let now = Self.localMidnight("2026-11-11") + 9 * 3_600
        XCTAssertEqual(DayCycleResolver.uncoveredDays([Self.boundary("2026-11-09", onset)], now: now,
                                                      offsetSec: Self.cet).map(\.day), ["2026-11-10"])
        let early = Self.localMidnight("2026-11-10") + 9 * 3_600
        XCTAssertEqual(DayCycleResolver.uncoveredDays([Self.boundary("2026-11-09", onset)], now: early,
                                                      offsetSec: Self.cet), [])
    }

    /// The open-cycle cap's boundary claims its day, so the two rules never produce the same day twice.
    func testOpenCycleCapClaimsItsDay() {
        let onset = Self.localMidnight("2026-11-09") + 7 * 3_600
        let now = onset + 41 * 3_600
        let sleep = DayCycleWindow(id: "sleep:2026-11-09", startInclusive: onset, endExclusive: now,
                                   displayDay: "2026-11-09", source: .detectedSleep)
        let cap = DayCycleResolver.activeWindow(mode: .sleepOnset, latestSleep: sleep, now: now, offsetSec: Self.cet)
        XCTAssertEqual(cap.displayDay, "2026-11-11")
        let uncovered = DayCycleResolver.uncoveredDays(
            [Self.boundary("2026-11-09", onset),
             .init(sleepId: cap.id, onset: cap.startInclusive, wakeDay: cap.displayDay)],
            now: now, offsetSec: Self.cet)
        XCTAssertEqual(uncovered, [.init(sleepId: "synthetic:2026-11-10", onset: Self.localMidnight("2026-11-10"),
                                         day: "2026-11-10", splitFrom: "sleep:2026-11-09")])
    }

    func testMalformedWakeDayAndFutureBoundariesAreIgnored() {
        let now = Self.localMidnight("2026-11-12")
        XCTAssertEqual(DayCycleResolver.uncoveredDays([.init(sleepId: "x", onset: 0, wakeDay: "bogus")],
                                                      now: now, offsetSec: Self.cet), [])
        XCTAssertEqual(DayCycleResolver.uncoveredDays([Self.boundary("2026-11-20", now + 1)], now: now,
                                                      offsetSec: Self.cet), [])
    }
}
