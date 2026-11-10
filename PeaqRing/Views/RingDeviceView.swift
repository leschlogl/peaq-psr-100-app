import SwiftUI

struct RingDeviceView: View {
    @EnvironmentObject private var ring: RingBluetooth
    @Environment(\.timeZone) private var timeZone
    @State private var freshness: RingDataFreshness?
    @State private var freshnessRingID = ""
    @State private var freshnessFailed = false
    private var batterySymbol: String {
        guard let percentage = ring.battery else { return "battery.0percent" }
        let level = Int((Double(min(max(percentage, 0), 100)) / 25).rounded()) * 25
        return "battery.\(level)percent"
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 18) {
                        Image(systemName: "circle.circle").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(.mint)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PEAQ PSR 100").font(.headline)
                            Text(ring.historyReady ? "Connected" : ring.status).font(.subheadline).foregroundStyle(.secondary)
                            if let battery = ring.battery { Label("\(battery)% battery", systemImage: batterySymbol).font(.caption) }
                        }
                    }.padding(.vertical, 12)
                    if ring.isConnected {
                        Button("Refresh battery", systemImage: batterySymbol) { ring.readBattery() }
                        Button("Disconnect", role: .destructive) { ring.disconnect() }
                    } else if !ring.selectedID.isEmpty {
                        Button(ring.isConnecting ? "Cancel connection" : "Reconnect") {
                            if ring.isConnecting { ring.disconnect() } else { ring.reconnect() }
                        }
                    }
                }
                if !ring.selectedID.isEmpty {
                    syncSection
                    freshnessSection
                }
                if !ring.isConnected && !ring.isConnecting {
                    Section("Available devices") {
                        Button(ring.isScanning ? "Stop scanning" : "Find my ring", systemImage: "antenna.radiowaves.left.and.right") {
                            if ring.isScanning { ring.stopScan() } else { ring.scan() }
                        }
                        Toggle("Show other Bluetooth devices", isOn: $ring.showAllDevices)
                        ForEach(ring.nearby) { device in
                            Button { ring.connect(device.id) } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(device.name)
                                        Text(device.discoveryDescription).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if device.connectedToSystem {
                                        Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(.mint)
                                            .accessibilityLabel("Connected to iPhone")
                                    } else if let rssi = device.rssi {
                                        Text("\(rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if ring.isScanning { ProgressView("Checking connected and nearby devices…") }
                    }
                }
                Section("Device information") {
                    LabeledContent("Current version", value: ring.ringFirmwareVersion ?? ring.deviceRevisions["2A26"] ?? "Not identified")
                    if let software = ring.deviceRevisions["2A28"] {
                        LabeledContent("Software revision", value: software)
                    }
                    if let hardware = ring.deviceRevisions["2A27"] {
                        LabeledContent("Hardware revision", value: hardware)
                    }
                }
                Section {
                    NavigationLink("Connection diagnostics") { DiagnosticsView() }
                    if !ring.selectedID.isEmpty {
                        Button("Forget connection", role: .destructive) { ring.forget() }
                    }
                } footer: { Text("Forgetting disconnects the ring. Local history remains associated with its original connection.") }
            }
            .navigationTitle("My ring")
            .task(id: "\(ring.selectedID)|\(ring.historyRevision)|\(timeZone.identifier)") {
                let ringID = ring.selectedID
                if freshnessRingID != ringID {
                    freshness = nil
                    freshnessRingID = ringID
                }
                freshnessFailed = false
                guard !ringID.isEmpty else { return }
                do {
                    var calendar = Calendar.current
                    calendar.timeZone = timeZone
                    let result = try await RingSnapshotLoader.freshness(container: RingStore.shared.get().container,
                        ringID: ringID, calendar: calendar)
                    guard !Task.isCancelled, ring.selectedID == ringID else { return }
                    freshness = result
                } catch {
                    guard !Task.isCancelled, ring.selectedID == ringID else { return }
                    freshness = nil
                    freshnessFailed = true
                }
            }
        }
    }

    private var syncSection: some View {
        let latest = ring.syncHistory.first
        return Section("Sync") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if ring.isSyncing {
                        ProgressView("Syncing…")
                    } else if let latest {
                        Text(latest.outcome.title)
                            .font(.headline)
                            .foregroundStyle(latest.outcome == .imported ? Color.mint : (latest.outcome.successful ? .primary : .yellow))
                        Text(latest.detail).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(ring.historyReady ? "Ready to sync" : "Ring not ready").font(.headline)
                    }
                    if ring.isConnected && !ring.historyReady {
                        Text(ring.historyAccess.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    if ring.isSyncing { ring.cancelSync() } else { ring.requestSync() }
                } label: {
                    Text(ring.isSyncing ? "Cancel" : (latest?.outcome.successful == false ? "Try again" : "Sync now"))
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.mint)
                .disabled(ring.isConnecting || (ring.isConnected && !ring.historyReady && !ring.isSyncing))
            }
            LabeledContent("Last successful sync", value: dateLabel(ring.lastSync, missing: "Never"))
            NavigationLink("Sync history") { RingSyncHistoryView() }
        }
    }

    private var freshnessSection: some View {
        Section("Latest saved readings") {
            if freshnessRingID == ring.selectedID, let freshness {
                LabeledContent("Sleep", value: dateLabel(freshness.sleepDay, includeTime: false))
                LabeledContent("Activity", value: dateLabel(freshness.activity))
                LabeledContent("Heart", value: dateLabel(freshness.heart))
            } else if freshnessFailed {
                Text("Couldn’t load saved reading dates.").foregroundStyle(.secondary)
            } else {
                ProgressView("Checking saved readings…")
            }
        }
    }

    private func dateLabel(_ date: Date?, missing: String = "No readings", includeTime: Bool = true) -> String {
        let format = Date.FormatStyle(date: .abbreviated, time: includeTime ? .shortened : .omitted, timeZone: timeZone)
        return date?.formatted(format) ?? missing
    }
}

private struct RingSyncHistoryView: View {
    @EnvironmentObject private var ring: RingBluetooth

    var body: some View {
        List {
            if ring.syncHistory.isEmpty {
                ContentUnavailableView("No sync attempts yet", systemImage: "clock.arrow.circlepath")
            }
            ForEach(ring.syncHistory) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.outcome.title).font(.headline)
                    Text(entry.detail).font(.subheadline).foregroundStyle(.secondary)
                    Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Sync history")
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var ring: RingBluetooth
    var body: some View {
        List {
            Section {
                ShareLink(item: ring.diagnosticText) { Label("Share diagnostics", systemImage: "square.and.arrow.up") }
                LabeledContent("History access", value: ring.historyAccess.title)
                LabeledContent("History notifications", value: "\(ring.notificationCount)")
                LabeledContent("Decoded readings", value: "\(ring.decodedReadingCount)")
                LabeledContent("Rejected packets", value: "\(ring.rejectedFrames)")
            } footer: {
                Text("Includes discovered service identifiers and packet counts. Tokens and raw health readings are excluded. A bounded diagnostic report is also saved in the app’s local cache for direct inspection through your paired Mac.")
            }
            Section("Latest events") {
                if ring.logs.isEmpty { Text("Connect your ring to collect diagnostics.").foregroundStyle(.secondary) }
                ForEach(ring.logs.reversed()) { log in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(log.message).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text(log.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("Diagnostics")
    }
}
