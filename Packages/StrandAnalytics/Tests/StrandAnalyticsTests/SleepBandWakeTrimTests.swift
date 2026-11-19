import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The night ends where the strap's own band says the wearer woke for good (`offsetTrimmedToBandWake`).
///
/// The field shape: the wearer wakes, lies still in bed for most of an hour, and NOOP keeps scoring it as
/// sleep (mostly REM) until they get up, while the band reads 3 ("up") from the awakening on. A snooze the
/// band keeps scoring 2 ("asleep") is real sleep and must not move.
final class SleepBandWakeTrimTests: XCTestCase {
    let d0 = 1_791_936_000 // 2026-10-14 00:00 UTC

    private func band(_ a: Int, _ b: Int, _ state: Int) -> [(ts: Int, state: Int)] {
        stride(from: a, to: b, by: 1).map { (ts: $0, state: state) }
    }
    private func period(_ a: Int, _ b: Int) -> SleepStager.Period {
        SleepStager.Period(stage: "sleep", start: a, end: b)
    }

    // MARK: - the helper

    func testTerminalAwakeRunEndsTheNightAtItsFirstSample() {
        let s = d0, w = d0 + 7 * 3600, e = w + 50 * 60
        let p = SleepStager.offsetTrimmedToBandWake(period(s, e), bandSleepState: band(s, w, 2) + band(w, e + 600, 3))
        XCTAssertEqual(p.start, s)
        XCTAssertEqual(p.end, w)
    }

    /// Band 0 ("wake") counts as awake too, and the run may mix 3 and 0.
    func testWakeAndUpBothCountAsAwake() {
        let s = d0, w = d0 + 7 * 3600, e = w + 30 * 60
        let p = SleepStager.offsetTrimmedToBandWake(
            period(s, e), bandSleepState: band(s, w, 2) + band(w, w + 900, 3) + band(w + 900, e, 0))
        XCTAssertEqual(p.end, w)
    }

    /// The snooze: the band never leaves "asleep", so the night keeps its end.
    func testBandStillAsleepAtTheEndLeavesTheNight() {
        let s = d0, e = d0 + 8 * 3600
        let p = SleepStager.offsetTrimmedToBandWake(period(s, e), bandSleepState: band(s, e + 300, 2))
        XCTAssertEqual(p.end, e)
    }

    /// A mid-night awakening the band returns from is not terminal.
    func testAwakeningTheBandReturnsFromIsUntouched() {
        let s = d0, w = d0 + 5 * 3600, back = w + 20 * 60, e = d0 + 8 * 3600
        let p = SleepStager.offsetTrimmedToBandWake(
            period(s, e), bandSleepState: band(s, w, 2) + band(w, back, 3) + band(back, e, 2))
        XCTAssertEqual(p.end, e)
    }

    /// Under `terminalBandWakeMinMin` inside the night the trim would sit inside the band's own lag.
    func testShortTerminalRunIsIgnored() {
        let s = d0, e = d0 + 8 * 3600, w = e - (SleepStager.terminalBandWakeMinMin * 60 - 30)
        let p = SleepStager.offsetTrimmedToBandWake(period(s, e), bandSleepState: band(s, w, 2) + band(w, e, 3))
        XCTAssertEqual(p.end, e)
    }

    /// "Still" (1) is ambiguous: a terminal run containing it is not the strap saying awake.
    func testStillBreaksTheAwakeRun() {
        let s = d0, w = d0 + 7 * 3600, e = w + 40 * 60
        let p = SleepStager.offsetTrimmedToBandWake(
            period(s, e), bandSleepState: band(s, w, 2) + band(w, w + 600, 3) + band(w + 600, w + 660, 1) + band(w + 660, e, 3))
        XCTAssertEqual(p.end, w + 660, "the run restarts after the last non-awake sample")
    }

    /// A hole in the band stream is not evidence of anything, so the trim declines.
    func testGapInTheAwakeRunDeclines() {
        let s = d0, w = d0 + 7 * 3600, e = w + 40 * 60, hole = SleepStager.unobservedGapMin * 60
        let p = SleepStager.offsetTrimmedToBandWake(
            period(s, e), bandSleepState: band(s, w, 2) + band(w, w + 300, 3) + band(w + 300 + hole, e, 3))
        XCTAssertEqual(p.end, e)
        let tail = SleepStager.offsetTrimmedToBandWake(
            period(s, e), bandSleepState: band(s, w, 2) + band(w, e - hole, 3))
        XCTAssertEqual(tail.end, e, "the run must reach the night's end")
    }

    func testNoBandOrAllAwakeBandIsANoOp() {
        let s = d0, e = d0 + 8 * 3600
        XCTAssertEqual(SleepStager.offsetTrimmedToBandWake(period(s, e), bandSleepState: []).end, e)
        XCTAssertEqual(SleepStager.offsetTrimmedToBandWake(period(s, e), bandSleepState: band(s, e, 3)).end, e)
    }

    func testUnsortedBandIsHandled() {
        let s = d0, w = d0 + 7 * 3600, e = w + 50 * 60
        let p = SleepStager.offsetTrimmedToBandWake(
            period(s, e), bandSleepState: (band(s, w, 2) + band(w, e, 3)).reversed())
        XCTAssertEqual(p.end, w)
    }

    // MARK: - parity oracle

    /// The generator the Kotlin twin's `oracleMatchesSwiftTwin` replays against this helper's stdout. Run
    /// here against the shipped helper so the Swift side cannot drift from the literal Kotlin pins: 300
    /// nights, 31 trimmed, 49 801 s trimmed in total.
    func testOracleGeneratorChecksumMatchesTheKotlinLiteral() {
        var x: UInt64 = 0x9E3779B97F4A7C15
        func next(_ n: Int) -> Int {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return Int((x >> 33) % UInt64(n))
        }
        var trimmed = 0, trimmedS = 0
        for _ in 0..<300 {
            let start = 1_800_000_000 + next(86_400)
            let len = 2 * 3600 + next(7 * 3600)
            let end = start + len
            var band: [(ts: Int, state: Int)] = []
            var t = start - next(1800)
            let stopAt = end + next(1800)
            let tailFrom = end - next(90 * 60)
            let tailState = [0, 3, 3, 1, 2][next(5)]
            while t < stopAt {
                var state = 2
                if t >= tailFrom { state = tailState } else if next(40) == 0 { state = next(4) }
                if t >= tailFrom && next(25) == 0 { state = next(4) }
                let runLen = 1 + next(t >= tailFrom ? 400 : 1500)
                var u = t
                while u < t + runLen && u < stopAt {
                    band.append((ts: u, state: state))
                    u += next(60) == 0 ? 200 + next(300) : 1 + next(20)
                }
                t = u
            }
            if next(4) == 0 { band.reverse() }
            let p = SleepStager.offsetTrimmedToBandWake(period(start, end), bandSleepState: band)
            if p.end != end { trimmed += 1; trimmedS += end - p.end }
        }
        XCTAssertEqual(trimmed, 31)
        XCTAssertEqual(trimmedS, 49_801)
    }

    // MARK: - through detectSleep

    private func moving(_ a: Int, _ b: Int) -> [GravitySample] {
        stride(from: a, to: b, by: 1).map {
            GravitySample(ts: $0, x: sin(Double($0)) * 0.3, y: cos(Double($0) * 1.7) * 0.3, z: 0.9)
        }
    }
    private func still(_ a: Int, _ b: Int) -> [GravitySample] {
        stride(from: a, to: b, by: 1).map { GravitySample(ts: $0, x: 0.1, y: 0.2, z: 0.97) }
    }
    private func hr(_ a: Int, _ b: Int, _ bpm: Int) -> [HRSample] {
        stride(from: a, to: b, by: 1).map { HRSample(ts: $0, bpm: bpm + (($0 / 97) % 5) - 2) }
    }

    /// Awake and still in bed for 50 minutes after waking, band "up" throughout: the night ends at the
    /// awakening rather than when the wearer gets up.
    func testAwakeInBedAfterWakingEndsAtTheBandAwakening() throws {
        let a = d0 + 18 * 3600, s = d0 + 23 * 3600, w = d0 + 30 * 3600 + 1800, up = w + 50 * 60, e = d0 + 33 * 3600
        let grav = moving(a, s) + still(s, up) + moving(up, e)
        let beats = hr(a, s, 75) + hr(s, w, 52) + hr(w, up, 60) + hr(up, e, 80)
        let bandState = band(a, s + 900, 0) + band(s + 900, w, 2) + band(w, up + 600, 3) + band(up + 600, e, 0)
        let before = try XCTUnwrap(SleepStager.detectSleep(hr: beats, gravity: grav, useSleepStagerV2: true).first)
        let after = try XCTUnwrap(SleepStager.detectSleep(hr: beats, gravity: grav, bandSleepState: bandState,
                                                          useSleepStagerV2: true).first)
        XCTAssertGreaterThan(before.end, w + 30 * 60, "without the band the still tail stays in the night")
        XCTAssertEqual(after.end, w)
        XCTAssertEqual(after.start, before.start)
    }

    /// Same night, but the band keeps scoring the post-alarm doze asleep: nothing moves.
    func testSnoozeTheBandScoresAsleepKeepsItsEnd() throws {
        let a = d0 + 18 * 3600, s = d0 + 23 * 3600, w = d0 + 30 * 3600 + 1800, up = w + 50 * 60, e = d0 + 33 * 3600
        let grav = moving(a, s) + still(s, up) + moving(up, e)
        let beats = hr(a, s, 75) + hr(s, up, 52) + hr(up, e, 80)
        let bandState = band(a, s + 900, 0) + band(s + 900, up + 120, 2) + band(up + 120, e, 3)
        let without = try XCTUnwrap(SleepStager.detectSleep(hr: beats, gravity: grav, useSleepStagerV2: true).first)
        let with = try XCTUnwrap(SleepStager.detectSleep(hr: beats, gravity: grav, bandSleepState: bandState,
                                                         useSleepStagerV2: true).first)
        XCTAssertEqual(with, without)
    }
}
