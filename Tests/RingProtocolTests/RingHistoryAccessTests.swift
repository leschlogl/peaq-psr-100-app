import XCTest
@testable import RingProtocol

final class RingHistoryAccessTests: XCTestCase {
    func testConnectedChannelAllowsSyncWithoutPrototypeGates() {
        let access = RingHistoryAccess.resolve(connected: true, channelReady: true)
        XCTAssertEqual(access, .ready)
        XCTAssertTrue(access.canRequest)
    }
    func testBatteryConnectionStillNeedsHistoryChannel() {
        XCTAssertEqual(RingHistoryAccess.resolve(connected: true, channelReady: false), .channelUnavailable)
        XCTAssertFalse(RingHistoryAccess.resolve(connected: true, channelReady: false).canRequest)
    }
    func testDisconnectedRingCannotSendRequests() {
        XCTAssertEqual(RingHistoryAccess.resolve(connected: false, channelReady: true), .disconnected)
    }
    func testVerifiedIOSServiceProfileAndTokenFreeProbeExcludeSessionWrites() {
        XCTAssertEqual(RingWire.service, "4CDABAA0-2CEA-C0C1-B38D-A0481AE60A97")
        XCTAssertEqual(RingWire.write, "4CDABAA1-2CEA-C0C1-B38D-A0481AE60A97")
        XCTAssertEqual(RingWire.notify, "4CDABAA2-2CEA-C0C1-B38D-A0481AE60A97")
        let commands = RingWire.historyQueries()
        XCTAssertEqual(commands.count, 29)
        for command in commands {
            XCTAssertEqual(command[1], 0x21)
            let prefix = Array(command.dropFirst(8).prefix(4))
            XCTAssertNotEqual(prefix, [0x83, 0, 1, 0])
            XCTAssertNotEqual(prefix, [4, 0, 0x44, 0])
            XCTAssertNotEqual(prefix, [2, 0, 0x20, 0])
        }
    }
}
