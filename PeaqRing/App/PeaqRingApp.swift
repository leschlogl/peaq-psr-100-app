import SwiftUI
import BackgroundTasks

@main
struct PeaqRingApp: App {
    @UIApplicationDelegateAdaptor(RingAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    @StateObject private var references = ReferencePreferences.shared
    @StateObject private var bluetooth = RingBluetooth.shared
    @State private var store = RingStore.shared
    var body: some Scene {
        WindowGroup {
            switch store {
            case .success(let store):
                ContentView()
                    .environmentObject(bluetooth)
                    .environmentObject(references)
                    .modelContainer(store.container)
                    .preferredColorScheme(.dark)
                    .tint(.mint)
                    .task {
                        while !Task.isCancelled {
                            if phase == .active { bluetooth.syncIfDue() }
                            try? await Task.sleep(for: .seconds(30))
                        }
                    }
                    .onChange(of: phase) { _, value in
                        if value == .active { bluetooth.resumeForeground() }
                        if value == .background { BackgroundRefresh.schedule() }
                    }
            case .failure:
                ContentUnavailableView {
                    Label("Couldn’t open ring history", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Check available storage, then try again. Retrying keeps any existing history.")
                } actions: {
                    Button("Try again") { store = RingStore.retryOpening() }
                        .buttonStyle(.borderedProminent)
                }
                .preferredColorScheme(.dark)
                .tint(.mint)
            }
        }
    }
}

final class RingAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundRefresh.identifier, using: .main) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in BackgroundRefresh.run(task) }
        }
        return true
    }
}

@MainActor
enum BackgroundRefresh {
    static let identifier = "com.peaqring.refresh"
    static func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        let defaults = UserDefaults.standard
        guard !(defaults.string(forKey: "ringID") ?? "").isEmpty,
              !defaults.bool(forKey: RingBluetooth.reconnectPausedKey) else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        let savedInterval = defaults.integer(forKey: "intervalMinutes")
        let minutes = max(5, savedInterval == 0 ? 15 : savedInterval)
        request.earliestBeginDate = Date().addingTimeInterval(Double(minutes) * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { RingBluetooth.shared.log("Background refresh could not be scheduled. Foreground sync is available.") }
    }
    static func run(_ task: BGAppRefreshTask) {
        schedule()
        let ring = RingBluetooth.shared
        guard ring.autoReconnect, !ring.selectedID.isEmpty,
              (try? RingStore.shared.get()) != nil else {
            task.setTaskCompleted(success: false)
            return
        }
        let before = ring.lastSync
        let worker = Task { @MainActor in
            if !ring.isConnected { ring.reconnectIfAllowed() }
            let deadline = Date().addingTimeInterval(24)
            var requested = ring.isSyncing
            while Date() < deadline && !Task.isCancelled {
                if ring.historyReady && !requested {
                    ring.syncIfDue()
                    requested = true
                }
                if requested && !ring.isSyncing { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            // End partial work before the refresh budget expires. BLE restoration may reconnect later.
            if ring.isSyncing { ring.cancelSync() }
            task.setTaskCompleted(success: !Task.isCancelled && ring.lastSync != before)
        }
        task.expirationHandler = {
            worker.cancel()
        }
    }
}
