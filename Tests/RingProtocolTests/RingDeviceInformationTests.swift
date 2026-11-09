import XCTest
@testable import RingProtocol

final class RingDeviceInformationTests: XCTestCase {
    func testLiveFirmwareResponseMatchesReportedDeviceVersionAndIsNotArchived() {
        let body: [UInt8] = [0,1,4,100,0,149,71,1,1,6,1]
        let frame = RingWire.frame(kind: 0x31, sequence: 7, payload: [1,0,0x13,0,11] + body)
        var decoder = RingDecoder()
        XCTAssertTrue(decoder.ingest(frame.prefix(10)).isEmpty)
        XCTAssertNil(decoder.firmwareVersion)
        XCTAssertTrue(decoder.ingest(frame.dropFirst(10)).isEmpty)
        XCTAssertEqual(decoder.firmwareVersion, "0.1.4")
        XCTAssertTrue(decoder.receivedBlocks.isEmpty)
        var bad = frame; bad[bad.count - 1] ^= 1
        _ = decoder.ingest(bad)
        XCTAssertNil(decoder.firmwareVersion)
        XCTAssertNil(RingDeviceInformation.firmwareVersion(Data([0,1,4])))
    }

    func testIdentityLayoutsOnlyReturnAddressAndRejectUnknownOrTruncatedLayouts() {
        let address: [UInt8] = [0xC1,0x12,0x23,0x34,0x45,0x56]
        for (sub, offset): (UInt8, Int) in [(1,14),(2,6)] {
            let body = Data(Array(repeating: UInt8(0xAA), count: offset) + address)
            XCTAssertEqual(RingDeviceInformation.bluetoothAddress(subcommand: sub, body: body), "C1:12:23:34:45:56")
            XCTAssertNil(RingDeviceInformation.bluetoothAddress(subcommand: sub, body: body.dropLast()))
            XCTAssertNil(RingDeviceInformation.bluetoothAddress(subcommand: sub, body: Data(repeating: 0, count: body.count)))
            XCTAssertNil(RingDeviceInformation.bluetoothAddress(subcommand: sub, body: Data(repeating: 255, count: body.count)))
        }
        XCTAssertNil(RingDeviceInformation.bluetoothAddress(subcommand: 0x41, body: Data(repeating: 1, count: 20)))
        XCTAssertEqual(Array(RingWire.deviceIdentityQuery().dropFirst(8)), [0x83,0,0x40,0,0])
    }
}
