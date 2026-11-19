import XCTest
import WhoopProtocol
@testable import WhoopStore

/// A WHOOP 5.0/MG battery row has no charging bit of its own, so the store fills it from the strap's
/// charger edges at insert, across batches. Twin of Kotlin `ChargerStateRepositoryTest`.
final class ChargerStateStoreTests: XCTestCase {
    private func event(_ ts: Int, _ kind: String) -> WhoopEvent { WhoopEvent(ts: ts, kind: kind, payload: [:]) }
    private func battery(_ ts: Int, _ soc: Double, charging: Bool? = nil) -> BatterySample {
        BatterySample(ts: ts, soc: soc, mv: 3990, charging: charging)
    }
    private func charging(_ store: WhoopStore) async throws -> Bool? {
        try await store.latestBattery(deviceId: "s")?.charging
    }

    func testRowsTakeTheLatestChargerEdgeAcrossBatches() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "s", mac: nil, name: nil)

        // No edge yet: unknown, not "not charging".
        _ = try await store.insert(Streams(battery: [battery(50, 40)]), deviceId: "s")
        let unknown = try await charging(store)
        XCTAssertNil(unknown)

        // 2026-10-25 07:57:06: the pack goes on; the first BATTERY_LEVEL lands a minute later, same batch.
        _ = try await store.insert(Streams(events: [event(100, "BATTERY_PACK_CONNECTED(21)"), event(100, "CHARGING_ON(7)")],
                                           battery: [battery(158, 43.2)]), deviceId: "s")
        let on = try await charging(store)
        XCTAssertEqual(on, true)

        // A later batch with no edge of its own still reads the stored one.
        _ = try await store.insert(Streams(battery: [battery(188, 43.8)]), deviceId: "s")
        let carried = try await charging(store)
        XCTAssertEqual(carried, true)

        // Off the charger, then a WHOOP 4.0 sample whose own bit stands.
        _ = try await store.insert(Streams(events: [event(4_000, "CHARGING_OFF(8)")],
                                           battery: [battery(4_030, 97)]), deviceId: "s")
        let off = try await charging(store)
        XCTAssertEqual(off, false)
        _ = try await store.insert(Streams(battery: [battery(4_060, 97, charging: true)]), deviceId: "s")
        let own = try await charging(store)
        XCTAssertEqual(own, true)

        // A reboot clears the state until the strap raises an edge again.
        _ = try await store.insert(Streams(events: [event(5_000, "BOOT(15)")], battery: [battery(5_030, 96)]),
                                   deviceId: "s")
        let afterBoot = try await charging(store)
        XCTAssertNil(afterBoot)
    }
}
