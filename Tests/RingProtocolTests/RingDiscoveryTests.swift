import XCTest
@testable import RingProtocol

final class RingDiscoveryTests: XCTestCase {
    func testSystemConnectedUnnamedRingIsVisibleWithoutAdvertisements() {
        var catalog = RingDiscovery()
        let id = UUID()
        catalog.record(DiscoveredRing(id: id, name: "Unnamed device", likelyRing: false, connectedToSystem: true))
        XCTAssertEqual(catalog.visible(showAllDevices: false).map(\.id), [id])
        XCTAssertNil(catalog.visible(showAllDevices: false).first?.rssi)
        XCTAssertEqual(catalog.visible(showAllDevices: false).first?.discoveryDescription, "Connected to iPhone · unverified device")
    }
    func testAdvertisementMergesWithoutLosingSystemConnectionAndRingMatch() {
        var catalog = RingDiscovery()
        let id = UUID()
        catalog.record(DiscoveredRing(id: id, name: "Unnamed device", likelyRing: true, connectedToSystem: true))
        catalog.record(DiscoveredRing(id: id, name: "My Ring", rssi: -55, likelyRing: false))
        XCTAssertEqual(catalog.count, 1)
        let result = catalog.visible(showAllDevices: false).first!
        XCTAssertEqual(result.name, "My Ring")
        XCTAssertEqual(result.rssi, -55)
        XCTAssertTrue(result.connectedToSystem)
        XCTAssertTrue(result.likelyRing)
    }
    func testShowAllIncludesAdvertisementsReceivedBeforeToggle() {
        var catalog = RingDiscovery()
        catalog.record(DiscoveredRing(id: UUID(), name: "Unexpected firmware name", rssi: -45, likelyRing: false))
        XCTAssertTrue(catalog.visible(showAllDevices: false).isEmpty)
        XCTAssertEqual(catalog.visible(showAllDevices: true).count, 1)
        XCTAssertTrue(catalog.visible(showAllDevices: false).isEmpty)
    }
    func testRememberedDevicesStayVisibleAndSystemConnectionsSortFirst() {
        var catalog = RingDiscovery()
        let connected = UUID()
        let remembered = UUID()
        catalog.record(DiscoveredRing(id: remembered, name: "Unnamed device", likelyRing: false, remembered: true))
        catalog.record(DiscoveredRing(id: connected, name: "Unknown", likelyRing: false, connectedToSystem: true))
        let result = catalog.visible(showAllDevices: false)
        XCTAssertEqual(result.map(\.id), [connected, remembered])
        XCTAssertEqual(result.last?.discoveryDescription, "Saved ring connection")
        catalog.reset()
        XCTAssertTrue(catalog.visible(showAllDevices: true).isEmpty)
    }
    func testRingEvidenceIncludesUUIDsButDoesNotTreatBatteryServiceAsRingIdentity() {
        XCTAssertTrue(RingDiscovery.matchesRing(name: "PSR 100", services: []))
        XCTAssertTrue(RingDiscovery.matchesRing(name: "Unknown", services: ["baa0"]))
        XCTAssertTrue(RingDiscovery.matchesRing(name: "Unknown", services: ["0000baa0-0000-1000-8000-00805f9b34fb"]))
        XCTAssertTrue(RingDiscovery.matchesRing(name: "Unknown", services: [RingWire.service.lowercased()]))
        XCTAssertFalse(RingDiscovery.matchesRing(name: "Headphones", services: ["180F", "180A"]))
    }
}
