import Foundation

public enum RingHistoryAccess: Equatable {
    case disconnected, channelUnavailable, ready
    public static func resolve(connected: Bool, channelReady: Bool) -> Self {
        guard connected else { return .disconnected }
        return channelReady ? .ready : .channelUnavailable
    }
    public var title: String {
        switch self {
        case .disconnected: return "Waiting for your ring"
        case .channelUnavailable: return "Preparing data connection"
        case .ready: return "Automatic sync is on"
        }
    }
    public var explanation: String {
        switch self {
        case .disconnected: return "Your readings will sync when the ring is connected."
        case .channelUnavailable: return "Battery can be read separately. If the data connection stays unavailable, check Connection diagnostics."
        case .ready: return "Readings sync when you connect and at your preferred interval. You can also refresh them manually."
        }
    }
    public var canRequest: Bool { self == .ready }
}
