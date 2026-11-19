import XCTest
@testable import Strand
import WhoopProtocol

/// End-to-end routing for the WHOOP 5/MG battery pack's own charge: an intact pushed event reaches
/// `LiveState`, the shared displayability gate refuses an impossible value, and both detach and link
/// teardown clear the reading. The event payloads are the same real-hardware vectors pinned by the
/// Swift/Kotlin protocol twins; only the verified WHOOP 5 envelope is assembled here.
@MainActor
final class FrameRouterBatteryPackTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
    }

    /// WHOOP 5/MG EVENT: type @8, event @10, unix timestamp @12, opaque event payload @16.
    private func eventFrame(_ event: UInt8, payload: [UInt8] = []) -> [UInt8] {
        var inner: [UInt8] = [48, 1, event, 0, 0, 0, 0, 0] + payload
        let pad = (4 - inner.count % 4) % 4
        if pad > 0 { inner += [UInt8](repeating: 0, count: pad) }

        let declaredLength = inner.count + 4
        var frame: [UInt8] = [0xAA, 0x01,
                              UInt8(declaredLength & 0xFF), UInt8((declaredLength >> 8) & 0xFF),
                              0x00, 0x01]
        let headerCRC = crc16Modbus(Array(frame[0..<6]))
        frame += [UInt8(headerCRC & 0xFF), UInt8(headerCRC >> 8)]
        frame += inner
        let payloadCRC = crc32(inner)
        frame += [UInt8(payloadCRC & 0xFF), UInt8((payloadCRC >> 8) & 0xFF),
                  UInt8((payloadCRC >> 16) & 0xFF), UInt8((payloadCRC >> 24) & 0xFF)]
        return frame
    }

    /// Real WHOOP MG event-109 payload, fw 50.39.1.0: pack WBB5AP0000001 at 56.9%.
    private let packEvent569 = "f5481c000100005e005301574242354150303030303030310000003902010c00"

    private func router(_ live: LiveState) -> FrameRouter {
        let router = FrameRouter(state: live)
        router.family = .whoop5
        return router
    }

    func testIntactPushedPackEventPublishesItsOwnCharge() {
        let live = LiveState()
        let frame = eventFrame(UInt8(BatteryPackInfo.packInfoEvent), payload: bytes(packEvent569))
        XCTAssertTrue(parseFrame(frame, family: .whoop5).ok, "fixture must pass the full integrity gate")

        router(live).handle(frame: frame)

        XCTAssertEqual(live.packSocPct ?? -1, 56.9, accuracy: 1e-9)
        XCTAssertNil(live.charging, "pack presence must not claim that current is flowing")
        XCTAssertNil(live.batteryPct, "the pack gauge must not overwrite the strap gauge")
    }

    func testImpossiblePackChargeDoesNotReachLiveState() {
        var payload = bytes(packEvent569)
        payload[27] = 0xE9 // record base 4 + SoC offset 23: 1001 tenths = 100.1%
        payload[28] = 0x03

        let live = LiveState()
        router(live).handle(frame: eventFrame(UInt8(BatteryPackInfo.packInfoEvent), payload: payload))

        XCTAssertNil(live.packSocPct)
    }

    /// A 5/MG BATTERY_LEVEL payload (soc u16 @21, mV u16 @25) with the byte 4.0's charge bit shifts to (@30)
    /// at 0, as it read through 85 real charge sessions. 43.2 %, 3986 mV: the 2026-10-25 07:58 reading.
    private func batteryLevel5() -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 16)
        p[5] = 0xB0; p[6] = 0x01      // 432 tenths
        p[9] = 0x92; p[10] = 0x0F     // 3986 mV
        return p
    }

    func testAWhoop5BatteryEventDoesNotClearAChargingEdge() {
        let live = LiveState()
        let r = router(live)
        r.handle(frame: eventFrame(21)) // BATTERY_PACK_CONNECTED: a pack is on, not yet charging
        XCTAssertNil(live.charging, "an attached pack is not charging; a depleted one never raises 7")
        r.handle(frame: eventFrame(7))  // CHARGING_ON
        XCTAssertEqual(live.charging, true)
        r.handle(frame: eventFrame(3, payload: batteryLevel5()))
        XCTAssertEqual(live.batteryPct ?? -1, 43.2, accuracy: 1e-9, "the fixture is a real battery event")
        XCTAssertEqual(live.charging, true, "the 5/MG event has no charging bit to reset the edge with")
        r.handle(frame: eventFrame(8))  // CHARGING_OFF
        XCTAssertEqual(live.charging, false)
    }

    func testPackDetachAndDisconnectClearTheReading() {
        let live = LiveState()
        let r = router(live)
        r.handle(frame: eventFrame(UInt8(BatteryPackInfo.packInfoEvent), payload: bytes(packEvent569)))
        XCTAssertNotNil(live.packSocPct)

        r.handle(frame: eventFrame(22)) // BATTERY_PACK_REMOVED
        XCTAssertNil(live.packSocPct)
        XCTAssertEqual(live.charging, false)

        r.handle(frame: eventFrame(UInt8(BatteryPackInfo.packInfoEvent), payload: bytes(packEvent569)))
        XCTAssertNotNil(live.packSocPct)
        live.clearBiometrics()          // the disconnect path's live-state teardown
        XCTAssertNil(live.packSocPct)
    }
}
