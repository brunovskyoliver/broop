import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class WorkoutAutoSaveTests: XCTestCase {

    private func session(durS: Int = 2700, coverage: Double? = 100, hrr: Double? = 46, tier: Bool = true)
        -> ExerciseSession {
        ExerciseSession(start: 1_000_000, end: 1_000_000 + durS, avgHR: 116, peakHR: 150, strain: 9,
                        durationS: Double(durS), zoneTimePct: [:], avgHRRPct: hrr, hrmax: 195,
                        hrmaxSource: "caller", caloriesKcal: 350, caloriesKJ: 1464, hrCoveragePct: coverage,
                        isActivityTier: tier)
    }

    private func features(motionVariance: Double) -> WorkoutClassFeatures {
        WorkoutClassFeatures(durationSec: 2700, meanHR: 116, peakHR: 150, meanHRRPct: 46, hrCV: 0.1,
                             stillFraction: 0.7, walkFraction: 0.3, runFraction: 0, tickCoverage: 1,
                             gaitStreakSec: 90, motionVariance: motionVariance, motionCV: 1, kcalPerMin: 7)
    }

    private func prediction(_ c: CoarseWorkoutClass, confidence: Double = 0.3, strength: Double = 0.55)
        -> WorkoutClassPrediction {
        WorkoutClassPrediction(predictedClass: c, confidence: confidence,
                               scores: [.strength: strength, .walk: 0.5, .run: 0.2, .cycle: 0.2, .ski: 0.1])
    }

    /// The lift as measured: strength or `other`, plausible strength score, motion in the lifting band.
    func testALiftIsSaved() {
        let f = features(motionVariance: 0.10)
        XCTAssertEqual(WorkoutAutoSave.verdict(session: session(), features: f, prediction: prediction(.strength)),
                       .save(token: "strength"))
        XCTAssertEqual(WorkoutAutoSave.verdict(session: session(), features: f, prediction: prediction(.other)),
                       .save(token: "strength"), "two of the eleven lifts came back other")
    }

    func testAWalkIsNeverSaved() {
        XCTAssertEqual(WorkoutAutoSave.verdict(session: session(), features: features(motionVariance: 0.10),
                                               prediction: prediction(.walk, confidence: 0.9)), .suggest)
    }

    /// The everyday bouts the bar exists to keep out: quiet motion, or an average under the activity floor.
    func testEverydayMovementStaysASuggestion() {
        XCTAssertEqual(WorkoutAutoSave.verdict(session: session(), features: features(motionVariance: 0.06),
                                               prediction: prediction(.strength)), .suggest)
        XCTAssertEqual(WorkoutAutoSave.verdict(session: session(hrr: 37), features: features(motionVariance: 0.10),
                                               prediction: prediction(.strength)), .suggest)
        XCTAssertEqual(WorkoutAutoSave.verdict(session: session(durS: 1100), features: features(motionVariance: 0.10),
                                               prediction: prediction(.strength)), .suggest)
        XCTAssertEqual(WorkoutAutoSave.verdict(session: session(coverage: 60), features: features(motionVariance: 0.10),
                                               prediction: prediction(.strength)), .suggest)
        XCTAssertEqual(WorkoutAutoSave.verdict(session: session(coverage: nil), features: features(motionVariance: 0.10),
                                               prediction: prediction(.strength)), .suggest)
        XCTAssertEqual(WorkoutAutoSave.verdict(session: session(), features: nil, prediction: nil), .suggest)
    }

    /// A run or ride needs a confident call and the zone-2 bar, not just the activity tier.
    func testCardioNeedsConfidenceAndTheZoneTwoBar() {
        let f = features(motionVariance: 0.03)
        XCTAssertEqual(WorkoutAutoSave.verdict(session: session(tier: false), features: f,
                                               prediction: prediction(.run, confidence: 0.5)), .save(token: "run"))
        XCTAssertEqual(WorkoutAutoSave.verdict(session: session(tier: false), features: f,
                                               prediction: prediction(.cycle, confidence: 0.5)), .save(token: "cycle"))
        XCTAssertEqual(WorkoutAutoSave.verdict(session: session(tier: true), features: f,
                                               prediction: prediction(.run, confidence: 0.5)), .suggest)
        XCTAssertEqual(WorkoutAutoSave.verdict(session: session(tier: false), features: f,
                                               prediction: prediction(.run, confidence: 0.3)), .suggest)
    }

    /// Every threshold, either side of it, in every combination: one character per case ('S' strength,
    /// 'R' run, 'C' cycle, '.' suggest). The Kotlin twin's WorkoutAutoSaveTest asserts the SAME literal,
    /// so neither platform can move a boundary alone.
    static func oracleGrid() -> String {
        var out = ""
        for durS in [1199, 1200] {
            for cov in [69.9, 70.0] {
                for hrr in [39.9, 40.0] {
                    for cls in [CoarseWorkoutClass.strength, .other, .walk, .ski, .run, .cycle] {
                        for str in [0.39, 0.40] {
                            for mv in [0.079, 0.08] {
                                for conf in [0.39, 0.40] {
                                    for tier in [true, false] {
                                        let s = ExerciseSession(
                                            start: 0, end: durS, avgHR: 120, peakHR: 150, strain: nil,
                                            durationS: Double(durS), zoneTimePct: [:], avgHRRPct: hrr, hrmax: 195,
                                            hrmaxSource: "caller", caloriesKcal: nil, caloriesKJ: nil,
                                            hrCoveragePct: cov, isActivityTier: tier)
                                        let f = WorkoutClassFeatures(
                                            durationSec: Double(durS), meanHR: 120, peakHR: 150, meanHRRPct: hrr,
                                            hrCV: 0.1, stillFraction: 0.7, walkFraction: 0.3, runFraction: 0,
                                            tickCoverage: 1, motionVariance: mv, motionCV: 1, kcalPerMin: 7)
                                        let p = WorkoutClassPrediction(predictedClass: cls, confidence: conf,
                                                                       scores: [.strength: str])
                                        switch WorkoutAutoSave.verdict(session: s, features: f, prediction: p) {
                                        case .save(let t): out += t == "strength" ? "S" : t == "run" ? "R" : "C"
                                        case .suggest: out += "."
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    func testOracleGrid() {
        let grid = Self.oracleGrid()
        XCTAssertEqual(grid.count, 768)
        XCTAssertEqual(grid, Self.expectedGrid)
    }

    static let expectedGrid = [
        "................................................................",
        "................................................................",
        "................................................................",
        "................................................................",
        "................................................................",
        "................................................................",
        "................................................................",
        "................................................................",
        "................................................................",
        "................................................................",
        "............................................SSSS............SSSS",
        "...................................R...R...R...R...C...C...C...C",
    ].joined()
}
