// swift-tools-version:5.9
import PackageDescription

// WorkoutBench — an offline replay harness for workout detection.
//
// Replays `WorkoutDetector` and `WorkoutTypeClassifier` over the real, already-decoded days held in a
// NOOP SQLite database, one local calendar day at a time (the shape `AnalyticsEngine.analyzeDay` uses),
// and scores the result against the workouts that database carries as labels: rows the wearer logged,
// imported, or recorded on another device.
//
// The database path is ALWAYS a command-line argument — no health data lives in this repository, and
// none is ever written back. The tool is read-only (`SQLITE_OPEN_READONLY` + `immutable=1`).
let package = Package(
    name: "workoutbench",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/StrandAnalytics"),
        .package(path: "../../Packages/WhoopProtocol"),
    ],
    targets: [
        .executableTarget(name: "workoutbench", dependencies: ["StrandAnalytics", "WhoopProtocol"]),
        // The scoring primitives are pure functions over time spans, so they are unit-testable without a
        // database. `swift test` here needs no health data and no `--db` argument.
        .testTarget(name: "workoutbenchTests", dependencies: ["workoutbench"]),
    ]
)
