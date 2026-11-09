import Foundation

public struct DiscoveredRing: Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var rssi: Int?
    public var likelyRing: Bool
    public var connectedToSystem: Bool
    public var remembered: Bool

    public init(id: UUID, name: String, rssi: Int? = nil, likelyRing: Bool,
                connectedToSystem: Bool = false, remembered: Bool = false) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.likelyRing = likelyRing
        self.connectedToSystem = connectedToSystem
        self.remembered = remembered
    }
    public var discoveryDescription: String {
        if connectedToSystem { return likelyRing ? "Connected to iPhone · possible PEAQ ring" : "Connected to iPhone · unverified device" }
        if remembered { return "Saved ring connection" }
        return likelyRing ? "Possible PEAQ ring" : "Unverified Bluetooth device"
    }
}

/// Merges system-connected, previously known, and advertising devices without hiding
/// connected candidates that have an unexpected name or no signal-strength reading.
public struct RingDiscovery {
    private var candidates: [UUID: DiscoveredRing] = [:]
    public init() {}
    public var count: Int { candidates.count }
    public mutating func reset() { candidates.removeAll() }
    public mutating func record(_ candidate: DiscoveredRing) {
        guard var existing = candidates[candidate.id] else { candidates[candidate.id] = candidate; return }
        if candidate.name != "Unnamed device" { existing.name = candidate.name }
        existing.rssi = candidate.rssi ?? existing.rssi
        existing.likelyRing = existing.likelyRing || candidate.likelyRing
        existing.connectedToSystem = existing.connectedToSystem || candidate.connectedToSystem
        existing.remembered = existing.remembered || candidate.remembered
        candidates[candidate.id] = existing
    }
    public func visible(showAllDevices: Bool) -> [DiscoveredRing] {
        candidates.values.filter { showAllDevices || $0.likelyRing || $0.connectedToSystem || $0.remembered }
            .sorted {
                if $0.connectedToSystem != $1.connectedToSystem { return $0.connectedToSystem }
                if $0.likelyRing != $1.likelyRing { return $0.likelyRing }
                if ($0.rssi ?? -999) != ($1.rssi ?? -999) { return ($0.rssi ?? -999) > ($1.rssi ?? -999) }
                return $0.id.uuidString < $1.id.uuidString
            }
    }
    public static func matchesRing(name: String, services: [String]) -> Bool {
        if name.localizedCaseInsensitiveContains("PSR") || name.localizedCaseInsensitiveContains("PEAQ") { return true }
        return services.contains {
            let uuid = $0.uppercased()
            return RingWire.applicationProfiles.contains(where: { $0.service == uuid }) || uuid == RingWire.advertisedService || uuid == "0000BAA0-0000-1000-8000-00805F9B34FB"
        }
    }
}
