import XCTest
@testable import Strand

/// The raw IMU fail-safe runs only when no capture is in flight, and the 5/MG allowlist used to admit
/// 81/82/106 only while one was, so the fail-safe's stop pair never reached the wire.
final class Whoop5RawDataCommandGateTests: XCTestCase {
    func testFailSafeStopPairIsAdmittedWithNoCaptureInFlight() {
        for command in [WhoopCommand.stopRawData, .toggleIMUMode] {
            XCTAssertTrue(BLEManager.whoop5AdmitsRawDataCommand(command, captureInFlight: false,
                                                                failSafeStopInFlight: true))
        }
    }

    func testStartStaysCaptureOnly() {
        XCTAssertFalse(BLEManager.whoop5AdmitsRawDataCommand(.startRawData, captureInFlight: false,
                                                             failSafeStopInFlight: true))
        XCTAssertTrue(BLEManager.whoop5AdmitsRawDataCommand(.startRawData, captureInFlight: true,
                                                            failSafeStopInFlight: false))
    }

    func testNothingAdmittedOutsideBothWindows() {
        for command in [WhoopCommand.startRawData, .stopRawData, .toggleIMUMode] {
            XCTAssertFalse(BLEManager.whoop5AdmitsRawDataCommand(command, captureInFlight: false,
                                                                 failSafeStopInFlight: false))
        }
        XCTAssertFalse(BLEManager.whoop5AdmitsRawDataCommand(.toggleRealtimeHR, captureInFlight: true,
                                                             failSafeStopInFlight: true))
    }
}
