import Foundation

public struct RingBatteryStatus: Equatable {
    public let percent: Int
    public let stateCode: UInt8
    public init(percent: Int, stateCode: UInt8) { self.percent = percent; self.stateCode = stateCode }
}

/// Some firmware leaves standard 2A19 unchanged. Once a live vendor-status
/// response arrives, a later standard read must not overwrite it. Reset on disconnect.
public struct RingBatteryTracker {
    public private(set) var standardPercent: Int?
    public private(set) var ringPercent: Int?
    public var percent: Int? { ringPercent ?? standardPercent }
    public init() {}
    public mutating func receiveStandard(_ value: Int) {
        if (0...100).contains(value) { standardPercent = value }
    }
    public mutating func receiveRing(_ value: Int) {
        if (0...100).contains(value) { ringPercent = value }
    }
}
