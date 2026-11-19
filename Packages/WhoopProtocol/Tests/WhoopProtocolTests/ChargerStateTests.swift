import XCTest
@testable import WhoopProtocol

/// `ChargerState.resolve`: a battery sample with no charging bit takes the state of the latest charger edge
/// at or before it. The timeline mirrors a real 5/MG morning (2026-10-25: pack on at 07:57:06, SoC 43 → 97 %
/// by 09:09) plus the cases a real log has: a sample in the same second as an edge, a boot, a pack attached
/// with no CHARGING_ON (read as unknown, not charging), a removal beside a charging edge, and a 4.0 sample
/// that reads its own bit. Twin of Kotlin `ChargerStateTest`.
final class ChargerStateTests: XCTestCase {
    private let edges: [ChargerState.Edge] = [
        .init(ts: 100, kind: "CHARGING_ON(7)"), .init(ts: 100, kind: "BATTERY_PACK_CONNECTED(21)"),
        .init(ts: 150, kind: "DOUBLE_TAP(14)"),
        .init(ts: 200, kind: "CHARGING_OFF(8)"),
        .init(ts: 300, kind: "CHARGING_ON(7)"),
        .init(ts: 400, kind: "BOOT(15)"),
        .init(ts: 500, kind: "BATTERY_PACK_CONNECTED(21)"),
        .init(ts: 600, kind: "BATTERY_PACK_REMOVED(22)"), .init(ts: 600, kind: "CHARGING_ON(7)"),
    ]

    private func sample(_ ts: Int, _ charging: Bool? = nil) -> BatterySample {
        BatterySample(ts: ts, soc: 50, mv: 3900, charging: charging)
    }

    private func render(_ v: Bool?) -> String { v.map { $0 ? "1" : "0" } ?? "nil" }

    /// The expected string is pasted verbatim into the Kotlin twin.
    func testResolveOracle() {
        let ts = [50, 100, 130, 200, 250, 300, 399, 400, 450, 500, 600, 700]
        // Fed in reverse, with the edges shuffled: neither order may change the answer.
        let resolved = ChargerState.resolve(ts.reversed().map { sample($0) }, edges: edges.reversed())
        let rows = resolved.reversed().map { "\($0.ts)=\(render($0.charging))" }.joined(separator: ",")
        XCTAssertEqual(rows, "50=nil,100=1,130=1,200=0,250=0,300=1,399=1,400=nil,450=nil,500=nil,600=1,700=1")
    }

    func testAFourZeroBitIsKeptAndNoEdgesLeaveNil() {
        let fourZero = [sample(150, false), sample(160, true)]
        XCTAssertEqual(ChargerState.resolve(fourZero, edges: edges), fourZero)
        XCTAssertEqual(ChargerState.resolve([sample(1_000)], edges: []).map(\.charging), [nil])
        XCTAssertEqual(ChargerState.resolve([sample(1_000)], edges: [.init(ts: 1, kind: "WRIST_ON(9)")])
            .map(\.charging), [nil])
    }

    func testEveryResolvedKindIsInTheStoreFilter() {
        for kind in ["CHARGING_ON(7)", "CHARGING_OFF(8)", "BATTERY_PACK_REMOVED(22)", "BOOT(15)"] {
            XCTAssertNotNil(ChargerState.effect(kind))
            XCTAssertTrue(ChargerState.kindPrefixes.contains { kind.hasPrefix($0) }, kind)
        }
        XCTAssertNil(ChargerState.effect("BOOTLOADER_ENTERED"), "a later schema name must not read as a boot")
        XCTAssertNil(ChargerState.effect("BATTERY_PACK_CONNECTED(21)"), "a pack attached is not charging")
    }
}
