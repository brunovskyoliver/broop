import XCTest

@testable import workoutbench

/// The scoring primitives are pure functions over time spans, so they are pinned here on hand-built
/// spans — no database, no health data, no `--db` argument.
final class ScoringTests: XCTestCase {

    private func d(_ a: Int, _ b: Int, _ cls: String? = nil) -> DetectedSpan {
        DetectedSpan(span: Span(start: a, end: b), suggestedClass: cls)
    }

    func testUndetectedLabelScoresZeroWithNoErrors() {
        let s = Scoring.score(label: Span(start: 1000, end: 4000), detected: [d(5000, 6000)])
        XCTAssertEqual(s.coveredFrac, 0)
        XCTAssertEqual(s.pieces, 0)
        XCTAssertNil(s.startErrS)
        XCTAssertNil(s.classByOverlap)
    }

    /// A lift found as two pieces with the walk in attached: coverage counts only the label's own
    /// seconds, and the walk shows up as spill rather than as extra credit.
    func testFragmentedLabelWithSpill() {
        let label = Span(start: 1000, end: 4000)
        let s = Scoring.score(label: label, detected: [d(400, 2000, "walk"), d(2500, 4000, "strength")])
        XCTAssertEqual(s.coveredFrac, 2500.0 / 3000.0, accuracy: 1e-9)
        XCTAssertEqual(s.pieces, 2)
        XCTAssertEqual(s.spillS, 600)
        XCTAssertEqual(s.startErrS, -600)
        XCTAssertEqual(s.endErrS, 0)
        // 1500 strength seconds inside the label against 1000 walk seconds.
        XCTAssertEqual(s.classByOverlap, "strength")
    }

    /// Two detected sessions that overlap each other must not count the shared seconds twice.
    func testOverlappingPiecesCannotExceedFullCoverage() {
        let s = Scoring.score(label: Span(start: 0, end: 1000), detected: [d(0, 800), d(600, 1000)])
        XCTAssertEqual(s.coveredFrac, 1.0, accuracy: 1e-9)
    }

    func testClassTieIsBrokenByNameNotDictionaryOrder() {
        let s = Scoring.score(label: Span(start: 0, end: 1000),
                              detected: [d(0, 500, "walk"), d(500, 1000, "strength")])
        XCTAssertEqual(s.classByOverlap, "strength")
    }

    func testUnlabelledKeepsOnlySessionsTouchingNoLabel() {
        let out = Scoring.unlabelled([d(0, 100), d(900, 1100), d(5000, 6000)], labels: [Span(start: 1000, end: 2000)])
        XCTAssertEqual(out, [d(0, 100), d(5000, 6000)])
    }

    /// A watch workout and its hand-typed twin are one session; a different session beside it is kept.
    func testDedupCollapsesTwinsAndKeepsNeighbours() {
        let labels = [Span(start: 1000, end: 4000), Span(start: 1100, end: 3900), Span(start: 3950, end: 6000)]
        XCTAssertEqual(Scoring.dedup(labels, span: { $0 }), [labels[0], labels[2]])
    }

    func testSportFamilies() {
        XCTAssertEqual(SportFamily.of(sport: "Weightlifting"), .strength)
        XCTAssertEqual(SportFamily.of(sport: "TraditionalStrengthTraining"), .strength)
        XCTAssertEqual(SportFamily.of(sport: "Strength Training"), .strength)
        XCTAssertEqual(SportFamily.of(sport: "Walking"), .walk)
        XCTAssertEqual(SportFamily.of(sport: "Hiking"), .walk)
        XCTAssertEqual(SportFamily.of(sport: "Running"), .run)
        XCTAssertEqual(SportFamily.of(sport: "Cycling"), .cycle)
        XCTAssertEqual(SportFamily.of(sport: "Swimming"), .other)
    }
}
