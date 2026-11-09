import Foundation

public enum RingDeviceInformation {
    /// The 01/13 reply to version query 01/12 starts with three version bytes,
    /// followed by platform and serial fields.
    public static func firmwareVersion(_ body: Data) -> String? {
        guard (7...64).contains(body.count) else { return nil }
        return body.prefix(3).map(String.init).joined(separator: ".")
    }

    /// Extract the six address bytes from a pairing identity response.
    public static func bluetoothAddress(subcommand: UInt8, body: Data) -> String? {
        let bytes = Array(body)
        let offset: Int
        switch subcommand {
        case 1: guard (20...21).contains(bytes.count) else { return nil }; offset = 14
        case 2: guard (12...13).contains(bytes.count) else { return nil }; offset = 6
        default: return nil
        }
        let address = bytes[offset..<offset + 6]
        guard !address.allSatisfy({ $0 == 0 }), !address.allSatisfy({ $0 == 255 }) else { return nil }
        return address.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
