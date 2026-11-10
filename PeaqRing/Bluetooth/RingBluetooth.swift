import Foundation
import CoreBluetooth
import Combine
import UIKit

struct RingLog: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
}

enum RingConnectionError: LocalizedError {
    case unavailable, tooLong, writeFailed, noToken
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The ring is not ready. Connect and enable notifications first."
        case .tooLong: return "This command exceeds the ring’s supported Bluetooth write size."
        case .writeFailed: return "The ring did not acknowledge the Bluetooth write."
        case .noToken: return "Save a session token in Settings before trying history sync."
        }
    }
}

@MainActor
final class RingBluetooth: NSObject, ObservableObject {
    static let shared = RingBluetooth()
    @Published private(set) var status = "Connect your ring"
    @Published private var discovery = RingDiscovery()
    var nearby: [DiscoveredRing] { discovery.visible(showAllDevices: showAllDevices) }
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var historyReady = false
    @Published private(set) var isSyncing = false
    @Published private(set) var battery: Int?
    @Published private(set) var deviceRevisions: [String: String] = [:]
    @Published private(set) var ringFirmwareVersion: String?
    @Published private(set) var bluetoothAddress: String?
    @Published private(set) var logs: [RingLog] = []
    @Published private(set) var selectedID: String = UserDefaults.standard.string(forKey: "ringID") ?? ""
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncHistory: [RingSyncEntry] = []
    @Published private(set) var syncMessage = "History has not been synced yet."
    @Published private(set) var receivedReadings = 0
    @Published private(set) var hasSessionToken = false
    @Published private(set) var tokenFreeHistoryConfirmed = false
    private var decodedMetricCounts: [String: Int] = [:]
    @Published private(set) var notificationCount = 0
    @Published private(set) var decodedReadingCount = 0
    @Published private(set) var rejectedFrames = 0
    @Published var showAllDevices = false
    @Published var intervalMinutes = max(5, UserDefaults.standard.integer(forKey: "intervalMinutes") == 0 ? 15 : UserDefaults.standard.integer(forKey: "intervalMinutes")) {
        didSet { UserDefaults.standard.set(intervalMinutes, forKey: "intervalMinutes"); BackgroundRefresh.schedule() }
    }
    private var central: CBCentralManager?
    private var devices: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var batteryTracker = RingBatteryTracker()
    private var batteryCharacteristic: CBCharacteristic?
    @Published private(set) var historyRevision = 0
    private var historySessionID = UUID()
    private var activeHistoryWorker: RingHistoryWorker?
    private var historyWorker: RingHistoryWorker? {
        if let activeHistoryWorker { return activeHistoryWorker }
        guard let store = try? RingStore.shared.get() else { return nil }
        let worker = RingHistoryWorker(container: store.container) { [weak self] update in
            self?.applyHistory(update)
        }
        worker.beginSession(historySessionID, ringID: selectedID)
        activeHistoryWorker = worker
        return worker
    }
    private var diagnosticTask: Task<Void, Never>?
    private let diagnosticQueue = DispatchQueue(label: "com.peaqring.diagnostics", qos: .utility)
    private var scanTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var writeTimeout: Task<Void, Never>?
    private var backgroundLease: UIBackgroundTaskIdentifier = .invalid
    private var lastAttempt: Date?
    private var syncStorageFailed = false
    private var syncImports = RingImportChanges()
    private var syncInterruption = RingSyncEntry.Outcome.interrupted
    static let reconnectPausedKey = "automaticReconnectPaused"
    private(set) var autoReconnect = !UserDefaults.standard.bool(forKey: RingBluetooth.reconnectPausedKey)
    private var pendingScan = false
    private var serviceDiscoveryInProgress = false

    private override init() {
        super.init()
        // Retire prototype switches, including existing installations that left them off.
        for key in ["experimentalSync", "autoSync", "demoMode"] { UserDefaults.standard.removeObject(forKey: key) }
        if !selectedID.isEmpty {
            lastSync = UserDefaults.standard.object(forKey: "lastSync.\(selectedID)") as? Date
            syncHistory = RingSyncEntry.load(ringID: selectedID)
            tokenFreeHistoryConfirmed = UserDefaults.standard.bool(forKey: "tokenFreeHistory.\(selectedID)")
            refreshSessionTokenState()
            activate()
        }
        log(selectedID.isEmpty ? "No remembered ring selection. Select a ring to reconnect." : "Remembered ring selection loaded.")
    }
    func activate() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.peaqring.central"])
    }
    func log(_ message: String) {
        logs.append(RingLog(message: message))
        if logs.count > 250 { logs.removeFirst(logs.count - 250) }
        // Coalesce discovery/notification bursts and do all report formatting and
        // atomic file writes away from the main queue.
        guard diagnosticTask == nil else { return }
        diagnosticTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            let header = self.diagnosticHeader, entries = self.logs
            self.diagnosticTask = nil
            self.diagnosticQueue.async {
                guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
                let report = header + entries.map {
                    "\($0.date.formatted(date: .omitted, time: .standard))  \($0.message)"
                }.joined(separator: "\n")
                try? report.write(to: caches.appendingPathComponent("PeaqRing-diagnostics.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    var historyAccess: RingHistoryAccess {
        .resolve(connected: isConnected, channelReady: historyReady)
    }
    func refreshSessionTokenState() {
        hasSessionToken = !selectedID.isEmpty && !TokenVault.read(ringID: selectedID).isEmpty
    }
    var diagnosticText: String {
        diagnosticHeader + logs.map {
            "\($0.date.formatted(date: .omitted, time: .standard))  \($0.message)"
        }.joined(separator: "\n")
    }
    private var diagnosticHeader: String {
        let snapshot = [
            "My PEAQ diagnostics",
            "No tokens or raw health packets are included.",
            "",
            "App connected: \(isConnected)",
            "Remembered ring selected: \(!selectedID.isEmpty)",
            "Battery available: \(battery != nil)",
            "Standard battery percent: \(batteryTracker.standardPercent.map(String.init) ?? "unavailable")",
            "Ring battery percent: \(batteryTracker.ringPercent.map(String.init) ?? "unavailable")",
            "History write characteristic: \(writeCharacteristic != nil)",
            "History notify characteristic: \(notifyCharacteristic != nil)",
            "History notifications active: \(notifyCharacteristic?.isNotifying == true)",
            "Session token accessible: \(hasSessionToken)",
            "Token-free history previously received: \(tokenFreeHistoryConfirmed)",
            "Decoded metric counts: \(decodedMetricCounts.keys.sorted().map { "\($0)=\(decodedMetricCounts[$0]!)" }.joined(separator: ", "))",
            "Automatic sync enabled: true",
            "History access: \(historyAccess.title)",
            "Sync in progress: \(isSyncing)",
            "History notifications this connection: \(notificationCount)",
            "Decoded readings this connection: \(decodedReadingCount)",
            "Rejected frames: \(rejectedFrames)",
            "Last history result: \(syncMessage)",
            ""
        ]
        return snapshot.joined(separator: "\n")
    }

    func scan() {
        activate()
        guard !isConnected, !isConnecting else { return }
        guard central?.state == .poweredOn else { pendingScan = true; return }
        pendingScan = false
        discovery.reset()
        devices.removeAll()
        includePreviouslyKnownDevices()
        // Unfiltered foreground scan also finds rings whose advertisement differs by firmware.
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        status = nearby.isEmpty ? "Checking iPhone connections and nearby rings…" : "Choose a device · also checking nearby rings…"
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.stopScan()
        }
    }
    func stopScan() {
        pendingScan = false
        scanTask?.cancel()
        central?.stopScan()
        isScanning = false
        if !isConnected && !isConnecting {
            status = nearby.isEmpty ? "No matching devices found. Try showing other Bluetooth devices." : "Choose your ring"
            log("Discovery finished: \(discovery.count) candidates, \(nearby.count) visible.")
        }
    }
    private func includePreviouslyKnownDevices() {
        guard let central, central.state == .poweredOn else { return }
        let ringServices = (RingWire.applicationProfiles.map(\.service) + [RingWire.advertisedService]).map { CBUUID(string: $0) }
        let matches = central.retrieveConnectedPeripherals(withServices: ringServices)
        // The standard services broaden discovery for firmware with a different app-service UUID.
        // They identify candidates, not a confirmed ring. Never automatically select one.
        let otherConnected = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "180F"), CBUUID(string: "180A")])
        for candidate in matches { recordKnown(candidate, connectedToSystem: true, matchesRingService: true) }
        for candidate in otherConnected { recordKnown(candidate, connectedToSystem: true) }
        log("System-connected lookup: \(Set((matches + otherConnected).map(\.identifier)).count) candidates; \(matches.count) match known ring services.")
        if let id = UUID(uuidString: selectedID) {
            for candidate in central.retrievePeripherals(withIdentifiers: [id]) {
                recordKnown(candidate, connectedToSystem: candidate.state == .connected, remembered: true)
            }
        }
    }
    private func recordKnown(_ candidate: CBPeripheral, connectedToSystem: Bool, matchesRingService: Bool = false, remembered: Bool = false) {
        devices[candidate.identifier] = candidate
        let name = candidate.name ?? "Unnamed device"
        discovery.record(DiscoveredRing(id: candidate.identifier, name: name,
            likelyRing: matchesRingService || RingDiscovery.matchesRing(name: name, services: []),
            connectedToSystem: connectedToSystem, remembered: remembered))
    }
    func connect(_ id: UUID) {
        guard let candidate = devices[id], !isConnected, !isConnecting else { return }
        stopScan()
        autoReconnect = true
        UserDefaults.standard.removeObject(forKey: Self.reconnectPausedKey)
        if selectedID != id.uuidString {
            selectedID = id.uuidString
            UserDefaults.standard.set(selectedID, forKey: "ringID")
            battery = nil
            lastSync = UserDefaults.standard.object(forKey: "lastSync.\(selectedID)") as? Date
            syncHistory = RingSyncEntry.load(ringID: selectedID)
            syncMessage = "History has not been synced yet."
            lastAttempt = nil
            tokenFreeHistoryConfirmed = UserDefaults.standard.bool(forKey: "tokenFreeHistory.\(selectedID)")
        }
        refreshSessionTokenState()
        beginConnection(candidate)
    }
    private func beginConnection(_ candidate: CBPeripheral) {
        guard central?.state == .poweredOn else { return }
        peripheral = candidate
        candidate.delegate = self
        isConnecting = true
        status = "Connecting…"
        central?.connect(candidate)
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, let self, self.isConnecting else { return }
            self.autoReconnect = false
            self.central?.cancelPeripheralConnection(candidate)
            self.isConnecting = false
            self.status = "Connection timed out. Close the other ring app and try again."
        }
    }
    func reconnect() {
        autoReconnect = true
        UserDefaults.standard.removeObject(forKey: Self.reconnectPausedKey)
        reconnectIfAllowed()
    }
    func reconnectIfAllowed() {
        guard autoReconnect else { return }
        activate()
        guard central?.state == .poweredOn, !selectedID.isEmpty, !isConnected, !isConnecting,
              let id = UUID(uuidString: selectedID) else { return }
        if let known = central?.retrievePeripherals(withIdentifiers: [id]).first {
            beginConnection(known)
        } else { scan() }
    }
    func disconnect() {
        autoReconnect = false
        UserDefaults.standard.set(true, forKey: Self.reconnectPausedKey)
        BackgroundRefresh.schedule()
        cancelSync()
        stopScan()
        connectionTask?.cancel()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        clearConnection()
        status = "Disconnected"
    }
    func forget() {
        disconnect()
        selectedID = ""
        hasSessionToken = false
        tokenFreeHistoryConfirmed = false
        UserDefaults.standard.removeObject(forKey: "ringID")
        lastSync = nil
        syncHistory = []
        lastAttempt = nil
        status = "Connect your ring"
        // History and Keychain token remain associated with their original peripheral ID.
    }
    private func discoverRingServices(_ ring: CBPeripheral) {
        guard central?.state == .poweredOn, ring.state == .connected, !serviceDiscoveryInProgress else { return }
        serviceDiscoveryInProgress = true
        ring.delegate = self
        status = "Connected · discovering services"
        log("Requesting service discovery after Bluetooth became ready.")
        ring.discoverServices(nil)
    }
    private func historyChannelBecameReady() {
        if historyReady { syncIfDue() }
    }
    private func clearConnection() {
        isConnected = false
        isConnecting = false
        historyReady = false
        serviceDiscoveryInProgress = false
        battery = nil
        batteryTracker = RingBatteryTracker()
        deviceRevisions = [:]
        ringFirmwareVersion = nil; bluetoothAddress = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        batteryCharacteristic = nil
        resetHistorySession()
        peripheral = nil
        resolveWrite(.failure(RingConnectionError.unavailable))
    }
    func readBattery(requestRingStatus: Bool = true) {
        guard isConnected else { return }
        if let batteryCharacteristic { peripheral?.readValue(for: batteryCharacteristic) }
        // The normal sync queue includes the ring's battery query. Reuse it to
        // serialize writes rather than overlapping independent write operations.
        if requestRingStatus && historyReady && !isSyncing { sync() }
    }
    func resumeForeground() {
        refreshSessionTokenState()
        if !isConnected && !isConnecting && !isScanning && !selectedID.isEmpty { reconnectIfAllowed() }
        syncIfDue()
    }
    func syncIfDue() {
        guard historyReady, !isSyncing else { return }
        let elapsed = Date().timeIntervalSince(lastAttempt ?? .distantPast)
        if elapsed >= Double(intervalMinutes) * 60 { sync() }
    }
    func requestSync() {
        if isConnected {
            sync()
        } else if !selectedID.isEmpty && !isConnecting {
            lastAttempt = nil
            reconnect()
        }
    }

    func sync() {
        guard !isSyncing else { return }
        refreshSessionTokenState()
        let ringID = selectedID
        guard historyAccess.canRequest else {
            syncMessage = historyAccess.explanation
            log("History request skipped: \(historyAccess.title).")
            return
        }
        guard let worker = historyWorker else {
            completeSync(.storageFailure, ringID: ringID)
            return
        }
        let token = TokenVault.read(ringID: selectedID)
        let useTokenFreeQueries = tokenFreeHistoryConfirmed || token.isEmpty
        let commands: [Data]
        do {
            commands = useTokenFreeQueries ? RingWire.historyQueries() : try RingWire.historyCommands(token: token)
        }
        catch { completeSync(.credentials, ringID: ringID); return }
        log(useTokenFreeQueries ? "Starting token-free history queries." : "Starting experimental session and history requests. Authentication is not yet confirmed.")
        lastAttempt = Date()
        isSyncing = true
        receivedReadings = 0
        syncStorageFailed = false
        syncImports = RingImportChanges()
        syncInterruption = .interrupted
        resetHistorySession()
        syncMessage = "Requesting ring history…"
        backgroundLease = UIApplication.shared.beginBackgroundTask(withName: "Ring history sync") { [weak self] in
            Task { @MainActor in self?.cancelSync() }
        }
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishSync() }
            do {
                for command in commands {
                    try Task.checkCancellation()
                    try await self.write(command)
                    try await Task.sleep(for: .milliseconds(80))
                }
                self.syncMessage = "Listening for history…"
                try await Task.sleep(for: .seconds(18))
                await worker.flush()
                try Task.checkCancellation()
                if self.syncStorageFailed {
                    self.completeSync(.storageFailure, ringID: ringID)
                } else if self.receivedReadings > 0 {
                    if useTokenFreeQueries {
                        UserDefaults.standard.set(true, forKey: "tokenFreeHistory.\(ringID)")
                        if self.selectedID == ringID { self.tokenFreeHistoryConfirmed = true }
                    }
                    self.completeSync(self.syncImports.isEmpty ? .noChanges : .imported,
                                      ringID: ringID, changes: self.syncImports)
                } else {
                    self.completeSync(.noResponse, ringID: ringID)
                }
                self.log("History attempt finished: \(self.receivedReadings) decoded readings processed; token-free=\(useTokenFreeQueries).")
                self.readBattery(requestRingStatus: false)
            } catch {
                await worker.flush()
                let outcome = Task.isCancelled || error is CancellationError ? self.syncInterruption : .connectionFailure
                self.completeSync(outcome, ringID: ringID)
            }
        }
    }
    func cancelSync(connectionLost: Bool = false) {
        if connectionLost && syncTask?.isCancelled == false { syncInterruption = .connectionFailure }
        syncTask?.cancel()
        resolveWrite(.failure(CancellationError()))
    }

    private func completeSync(_ outcome: RingSyncEntry.Outcome, ringID: String, changes: RingImportChanges = RingImportChanges()) {
        let entry = RingSyncEntry(outcome: outcome, changes: changes)
        let history = RingSyncEntry.record(entry, ringID: ringID)
        if outcome.successful { UserDefaults.standard.set(entry.date, forKey: "lastSync.\(ringID)") }
        guard selectedID == ringID else { return }
        syncHistory = history
        if outcome.successful { lastSync = entry.date }
        syncMessage = entry.detail
        if !outcome.successful { log("\(entry.outcome.title): \(entry.detail)") }
    }
    private func finishSync() {
        isSyncing = false
        syncTask = nil
        if backgroundLease != .invalid { UIApplication.shared.endBackgroundTask(backgroundLease); backgroundLease = .invalid }
    }
    private func resetHistorySession() {
        historySessionID = UUID()
        activeHistoryWorker?.beginSession(historySessionID, ringID: selectedID)
    }
    private func applyHistory(_ update: RingHistoryUpdate) {
        // Saved data remains visible even if the connection changed while the
        // background batch was committing; progress belongs to its own session.
        if update.changed { historyRevision &+= 1 }
        guard update.sessionID == historySessionID, update.ringID == selectedID else { return }
        notificationCount += update.notifications
        decodedReadingCount += update.decoded
        rejectedFrames = update.rejectedFrames
        for (metric, count) in update.metricCounts { decodedMetricCounts[metric, default: 0] += count }
        if let value = update.battery {
            batteryTracker.receiveRing(value); battery = batteryTracker.percent
            log("Ring battery-status response received.")
        }
        if let version = update.firmwareVersion {
            ringFirmwareVersion = version
            log("Ring firmware version: \(version)")
        }
        if let address = update.bluetoothAddress {
            bluetoothAddress = address
            log("Ring Bluetooth address received.")
        }
        if isSyncing {
            receivedReadings += update.saved
            syncImports.merge(update.imports)
        }
        if update.storageFailed {
            syncStorageFailed = true
            syncMessage = "History arrived but could not be saved. Check available iPhone storage."
            log("History batch could not be saved.")
        }
        for message in update.blockMessages { log(message) }
        log("Background batch: \(update.notifications) notifications; \(update.saved) readings saved; \(update.rejectedFrames) rejected frames total.")
    }
    private func write(_ data: Data) async throws {
        guard let peripheral, let char = writeCharacteristic, isConnected else { throw RingConnectionError.unavailable }
        let type: CBCharacteristicWriteType = char.properties.contains(.write) ? .withResponse : .withoutResponse
        guard data.count <= peripheral.maximumWriteValueLength(for: type) else { throw RingConnectionError.tooLong }
        if type == .withoutResponse {
            let deadline = Date().addingTimeInterval(5)
            while !peripheral.canSendWriteWithoutResponse {
                try Task.checkCancellation()
                guard Date() < deadline else { throw RingConnectionError.writeFailed }
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            peripheral.writeValue(data, for: char, type: type)
        } else {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writeContinuation = continuation
                peripheral.writeValue(data, for: char, type: type)
                writeTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    self?.resolveWrite(.failure(RingConnectionError.writeFailed))
                }
            }
        }
    }
    private func resolveWrite(_ result: Result<Void, Error>) {
        writeTimeout?.cancel()
        writeTimeout = nil
        let pending = writeContinuation
        writeContinuation = nil
        pending?.resume(with: result)
    }
}

// CBCentralManager is created with queue: .main; delegate calls are main-queue confined.
extension RingBluetooth: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            status = "Ready to connect"
            if let peripheral, peripheral.state == .connected, isConnected {
                discoverRingServices(peripheral)
            } else if pendingScan { scan() }
            else { reconnectIfAllowed() }
        case .poweredOff: cancelSync(connectionLost: true); clearConnection(); isScanning = false; status = "Turn on Bluetooth to connect your ring."
        case .unauthorized: cancelSync(connectionLost: true); clearConnection(); isScanning = false; status = "Allow Bluetooth access in iPhone Settings to connect your ring."
        case .unsupported: cancelSync(connectionLost: true); clearConnection(); isScanning = false; status = "Bluetooth is unavailable. Use a physical iPhone for ring connections."
        default: cancelSync(connectionLost: true); clearConnection(); isScanning = false; status = "Waiting for Bluetooth…"
        }
        log("Bluetooth state: \(central.state.rawValue)")
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Unnamed device"
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        devices[peripheral.identifier] = peripheral
        discovery.record(DiscoveredRing(id: peripheral.identifier, name: name,
            rssi: RSSI.intValue == 127 ? nil : RSSI.intValue,
            likelyRing: RingDiscovery.matchesRing(name: name, services: services.map(\.uuidString)),
            remembered: peripheral.identifier.uuidString == selectedID))
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier.uuidString == selectedID, peripheral === self.peripheral else { central.cancelPeripheralConnection(peripheral); return }
        connectionTask?.cancel()
        isConnecting = false
        isConnected = true
        // Confirm the remembered selection whenever the connection succeeds,
        // including connections recovered from iOS rather than a scan selection.
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "ringID")
        notificationCount = 0
        decodedReadingCount = 0
        decodedMetricCounts = [:]
        discoverRingServices(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        connectionTask?.cancel()
        cancelSync(connectionLost: true)
        clearConnection()
        status = "Could not connect. Close the other ring app and try again."
        log("Connection failed.")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        connectionTask?.cancel()
        cancelSync(connectionLost: true)
        clearConnection()
        status = "Ring disconnected"
        log("Ring disconnected.")
        reconnectIfAllowed()
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard autoReconnect,
              let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let ring = restored.first(where: { $0.identifier.uuidString == selectedID }) else { return }
        peripheral = ring
        devices[ring.identifier] = ring
        ring.delegate = self
        if ring.state == .connected {
            isConnected = true
            UserDefaults.standard.set(ring.identifier.uuidString, forKey: "ringID")
            // Restored peripherals arrive before centralManagerDidUpdateState.
            // Wait for poweredOn before issuing GATT operations.
            if central.state == .poweredOn { discoverRingServices(ring) }
        } else if ring.state == .connecting { isConnecting = true }
        else { beginConnection(ring) }
        log("Restored Bluetooth connection state.")
    }
}

extension RingBluetooth: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral, isConnected else { return }
        serviceDiscoveryInProgress = false
        guard error == nil else { status = "Service discovery failed. Reconnect to retry."; log("Service discovery failed: \(error!.localizedDescription)"); return }
        log("Service discovery completed: \(peripheral.services?.count ?? 0) services.")
        for service in peripheral.services ?? [] {
            log("Service \(service.uuid.uuidString)")
            // Discovery is read-only. Only the known application channel is ever written.
            // In particular, FE59 is not used as a fallback write channel.
            peripheral.discoverCharacteristics(nil, for: service)
        }
        if !(peripheral.services ?? []).contains(where: { service in RingWire.applicationProfiles.contains { service.uuid == CBUUID(string: $0.service) } }) {
            status = "Connected · history service not found"
            syncMessage = "This firmware needs a different service mapping. Share the diagnostics to investigate."
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, isConnected else { return }
        guard error == nil else { log("Characteristic discovery failed for \(service.uuid.uuidString): \(error!.localizedDescription)"); return }
        for char in service.characteristics ?? [] {
            log("Characteristic \(char.uuid.uuidString) service=\(service.uuid.uuidString) properties=\(char.properties.rawValue)")
            if let profile = RingWire.applicationProfiles.first(where: { service.uuid == CBUUID(string: $0.service) }) {
                if char.uuid == CBUUID(string: profile.write), !char.properties.intersection([.write, .writeWithoutResponse]).isEmpty {
                    writeCharacteristic = char
                }
                if char.uuid == CBUUID(string: profile.notify), char.properties.contains(.notify) || char.properties.contains(.indicate) {
                    notifyCharacteristic = char
                    if char.isNotifying { historyReady = writeCharacteristic != nil }
                    else { peripheral.setNotifyValue(true, for: char) }
                }
            }
            if service.uuid == CBUUID(string: "180F"), char.uuid == CBUUID(string: "2A19"), char.properties.contains(.read) {
                batteryCharacteristic = char
                peripheral.readValue(for: char)
            }
            if service.uuid == CBUUID(string: "180A"),
               ["2A26", "2A27", "2A28"].contains(char.uuid.uuidString), char.properties.contains(.read) {
                peripheral.readValue(for: char)
            }
        }
        historyReady = writeCharacteristic != nil && notifyCharacteristic?.isNotifying == true
        if historyReady { status = "Connected · history channel ready"; historyChannelBecameReady() }
        else if RingWire.applicationProfiles.contains(where: { service.uuid == CBUUID(string: $0.service) }) { status = "Connected · preparing history channel" }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, isConnected else { return }
        guard characteristic === notifyCharacteristic else { return }
        historyReady = error == nil && characteristic.isNotifying && writeCharacteristic != nil
        status = historyReady ? "Connected · history channel ready" : "Connected · notifications unavailable"
        log(historyReady ? "History notifications enabled." : "History notifications unavailable.")
        if let error { log("Notification subscription error: \(error.localizedDescription)") }
        historyChannelBecameReady()
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, isConnected else { return }
        guard characteristic === writeCharacteristic else { return }
        resolveWrite(error.map { .failure($0) } ?? .success(()))
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, isConnected else { return }
        guard error == nil, let data = characteristic.value else { log("Characteristic read failed."); return }
        if characteristic.service?.uuid == CBUUID(string: "180A"),
           ["2A26", "2A27", "2A28"].contains(characteristic.uuid.uuidString) {
            // Revision strings are UTF-8. Do not interpret arbitrary identifiers as a MAC or security version.
            if data.count <= 128, let decoded = String(data: data, encoding: .utf8) {
                let value = decoded.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                if !value.isEmpty, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                    deviceRevisions[characteristic.uuid.uuidString] = value
                    log("Device revision \(characteristic.uuid.uuidString): \(value)")
                }
            }
            return
        }
        if characteristic === batteryCharacteristic {
            if let value = data.first, value <= 100 {
                batteryTracker.receiveStandard(Int(value)); battery = batteryTracker.percent
                log("Standard battery read succeeded.")
            }
            return
        }
        guard characteristic === notifyCharacteristic, peripheral.identifier.uuidString == selectedID else { return }
        historyWorker?.enqueue(data, sessionID: historySessionID)
    }
}
