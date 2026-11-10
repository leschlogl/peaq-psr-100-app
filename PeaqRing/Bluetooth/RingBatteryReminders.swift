import Foundation
import UserNotifications

struct RingBatteryReading: Codable, Equatable {
    enum Source: String, Codable { case standard, vendor }

    let percent: Int
    let date: Date
    let source: Source
}

struct RingBatteryReminderState: Codable, Equatable {
    static let thresholds = [10, 15, 20, 25, 30]

    var enabled = false
    private(set) var threshold = 20
    private(set) var latest: RingBatteryReading?
    private(set) var reminded = false

    mutating func setThreshold(_ value: Int) {
        if Self.thresholds.contains(value) { threshold = value }
    }

    @discardableResult
    mutating func accept(_ reading: RingBatteryReading, vendorExpected: Bool = true) -> Bool {
        guard (0...100).contains(reading.percent),
              !vendorExpected || latest?.source != .vendor || reading.source == .vendor else { return false }
        latest = reading
        return true
    }

    mutating func evaluateFreshReading() -> Bool {
        guard let latest else { return false }
        if latest.percent > threshold {
            reminded = false
            return false
        }
        return canRemind
    }

    var canRemind: Bool { enabled && !reminded && latest.map { $0.percent <= threshold } == true }

    mutating func setReminded(_ value: Bool) { reminded = value }

    static func load(ringID: String, defaults: UserDefaults = .standard) -> Self {
        guard !ringID.isEmpty, let data = defaults.data(forKey: key(ringID)),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return saved
    }

    func save(ringID: String, defaults: UserDefaults = .standard) {
        guard !ringID.isEmpty, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(ringID))
    }

    private static func key(_ ringID: String) -> String { "batteryReminder.\(ringID)" }
}

final class RingBatteryNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    private static let shared = RingBatteryNotificationPresenter()
    private static let prefix = "peaqring.low-battery."

    static func install() {
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = shared }
    }

    static func canDeliver(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    static func deliver(percent: Int, id: UUID, center: UNUserNotificationCenter) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Ring battery is low"
        content.body = "Your PEAQ ring is at \(percent)%."
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: prefix + id.uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix(Self.prefix) ? [.banner, .list, .sound] : []
    }
}
