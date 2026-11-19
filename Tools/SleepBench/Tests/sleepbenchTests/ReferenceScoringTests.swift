import XCTest

@testable import sleepbench

/// Section H's scoring is pure over segment arrays, so it is pinned on hand-built hypnograms: no database,
/// no health data, no `--reference` file.
final class ReferenceScoringTests: XCTestCase {

    private let t0 = 1_800_000_000   // a multiple of 30, so grid arithmetic below is exact

    // MARK: - parsing

    func testParseAcceptsHeaderFractionsAndVendorStageNames() throws {
        let csv = """
        start,end,stage
        \(t0).7,\(t0 + 600),Core
        \(t0 + 600),\(t0 + 900),N3

        \(t0 + 900),\(t0 + 1200),awake
        \(t0 + 1200),\(t0 + 1500),asleepUnspecified
        \(t0 - 60),\(t0 + 1500),InBed
        """
        let segs = try parseReferenceCSV(csv)
        XCTAssertEqual(segs.map(\.stage), ["inbed", "light", "deep", "wake", "sleep"])
        XCTAssertEqual(segs[1].start, t0, "fractional seconds truncate")
    }

    func testParseRejectsUnknownStageAndInvertedRow() {
        XCTAssertThrowsError(try parseReferenceCSV("\(t0),\(t0 + 30),dozing"))
        XCTAssertThrowsError(try parseReferenceCSV("\(t0 + 30),\(t0),light"))
    }

    // MARK: - nights

    func testNightsSplitOnLongGapAndInBedNeverStartsOne() {
        let segs = [
            RefSegment(start: t0, end: t0 + 3600, stage: "light"),
            RefSegment(start: t0 + 3600 + 600, end: t0 + 7200, stage: "rem"),          // 10 min gap: same night
            RefSegment(start: t0 + 7200 + 4 * 3600, end: t0 + 7200 + 5 * 3600, stage: "light"), // 4 h gap
            RefSegment(start: t0 + 30 * 3600, end: t0 + 31 * 3600, stage: "inbed"),    // overlaps nothing
        ]
        let nights = groupReferenceNights(segs)
        XCTAssertEqual(nights.count, 2)
        XCTAssertEqual(nights[0].count, 2)
        XCTAssertEqual(nights[1].count, 1)
    }

    // MARK: - grid labelling

    func testStagedBeatsInBedAndInBedOnlyIsWake() {
        let segs: [(start: Int, end: Int, stage: String)] = [
            (t0, t0 + 300, "inbed"),
            (t0 + 60, t0 + 120, "deep"),
        ]
        let l = labelsOnGrid(segs, gridStart: t0, n: 12)
        XCTAssertEqual(l, ["wake", "wake", "deep", "deep", "wake", "wake", "wake", "wake", "wake", "wake", "wake", "wake"])
    }

    func testEpochTakesTheStageCoveringItsStartInstant() {
        // A segment starting mid-epoch labels from the NEXT epoch on; one ending mid-epoch keeps that epoch.
        let l = labelsOnGrid([(t0 + 15, t0 + 75, "rem")], gridStart: t0, n: 4)
        XCTAssertEqual(l, ["wake", "rem", "rem", "wake"])
    }

    // MARK: - night score

    private func run(_ s: String, _ n: Int) -> [String] { [String](repeating: s, count: n) }

    /// The shape the wake-after-alarm report describes: identical nights except that NOOP keeps scoring REM
    /// for 20 minutes after the reference wakes. Offset error must be +20, TST error +20, onset 0.
    func testLateOffsetIsChargedAsMinutesAndAsSleepWakeDisagreement() {
        let ref = run("wake", 10) + run("light", 100) + run("wake", 40)
        let pred = run("wake", 10) + run("light", 100) + run("rem", 40)
        let s = scoreNight(ref: ref, pred: pred)
        XCTAssertEqual(s.onsetErr!, 0, accuracy: 1e-9)
        XCTAssertEqual(s.offsetErr!, 20, accuracy: 1e-9)
        XCTAssertEqual(s.tstErr, 20, accuracy: 1e-9)
        XCTAssertEqual(s.refTST, 50, accuracy: 1e-9)
        XCTAssertEqual(s.predStageMin["rem"]!, 20, accuracy: 1e-9)
        XCTAssertEqual(s.sleepWake.total, 150)
        XCTAssertEqual(s.sleepWake.accuracy, 110.0 / 150.0, accuracy: 1e-12)
    }

    func testEarlyOnsetIsNegative() {
        let ref = run("wake", 20) + run("light", 20)
        let pred = run("wake", 8) + run("light", 32)
        XCTAssertEqual(scoreNight(ref: ref, pred: pred).onsetErr!, -6, accuracy: 1e-9)
    }

    /// Unstaged reference sleep counts toward TST and sleep/wake, and is left out of the 4-class matrix.
    func testUnstagedReferenceSleepIsExcludedFromFourClassOnly() {
        let ref = run("sleep", 10) + run("deep", 10)
        let pred = run("light", 10) + run("deep", 10)
        let s = scoreNight(ref: ref, pred: pred)
        XCTAssertEqual(s.refTST, 10, accuracy: 1e-9)
        XCTAssertEqual(s.stage4.total, 10)
        XCTAssertEqual(s.stage4.accuracy, 1, accuracy: 1e-12)
        XCTAssertEqual(s.sleepWake.total, 20)
    }

    /// Kappa against a hand computation: 2x2 with po = 0.8, pe = 0.5*0.5 + 0.5*0.5 = 0.5 -> kappa 0.6.
    func testSleepWakeKappaMatchesHandComputation() {
        let ref = run("wake", 5) + run("light", 5)
        let pred = run("wake", 4) + run("light", 1) + run("wake", 1) + run("light", 4)
        XCTAssertEqual(scoreNight(ref: ref, pred: pred).sleepWake.kappa, 0.6, accuracy: 1e-12)
    }

    func testNoPredictedSleepHasNoOnsetOrOffsetError() {
        let s = scoreNight(ref: run("wake", 2) + run("rem", 4), pred: run("wake", 6))
        XCTAssertNil(s.onsetErr)
        XCTAssertNil(s.offsetErr)
        XCTAssertEqual(s.tstErr, -2, accuracy: 1e-9)
    }

    // MARK: - grid + baseline helpers

    func testSharedGridSpansBothHypnograms() {
        let g = sharedGrid(ref: [RefSegment(start: t0 + 60, end: t0 + 600, stage: "light")],
                           pred: [(t0, t0 + 615, "light")])!
        XCTAssertEqual(g.start, t0)
        XCTAssertEqual(g.n, 21)   // 615 s → 20.5 epochs, rounded up
    }

    func testAlwaysAsleepBaselineIsTheReferenceSleepShare() {
        var c = Confusion(classes: ["wake", "sleep"])
        for _ in 0..<3 { c.add(ref: "wake", pred: "sleep") }
        for _ in 0..<7 { c.add(ref: "sleep", pred: "wake") }
        XCTAssertEqual(alwaysAsleepAccuracy(c), 0.7, accuracy: 1e-12)
    }

    func testMinuteCoverageCountsMinutesWithASample() {
        XCTAssertEqual(minuteCoverage([t0, t0 + 10, t0 + 130], from: t0, to: t0 + 240), 0.5, accuracy: 1e-12)
    }
}
