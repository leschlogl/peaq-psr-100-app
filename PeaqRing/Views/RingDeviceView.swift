import SwiftUI

struct RingDeviceView: View {
    @EnvironmentObject private var ring: RingBluetooth
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
                        Button(ring.isSyncing ? "Cancel sync" : "Sync history", systemImage: "arrow.triangle.2.circlepath") {
                            if ring.isSyncing { ring.cancelSync() } else { ring.sync() }
                        }.disabled(!ring.historyReady)
                        Button("Disconnect", role: .destructive) { ring.disconnect() }
                    } else if !ring.selectedID.isEmpty {
                        Button(ring.isConnecting ? "Cancel connection" : "Reconnect") {
                            if ring.isConnecting { ring.disconnect() } else { ring.reconnect() }
                        }
                    }
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
                Section("History sync") {
                    Text(ring.historyAccess.title).font(.headline)
                    if !ring.historyReady {
                        Text(ring.historyAccess.explanation).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(ring.syncMessage).font(.footnote)
                    if let last = ring.lastSync { LabeledContent("Last successful sync", value: last.formatted(date: .abbreviated, time: .shortened)) }
                }
                Section {
                    NavigationLink("Connection diagnostics") { DiagnosticsView() }
                    if !ring.selectedID.isEmpty {
                        Button("Forget connection", role: .destructive) { ring.forget() }
                    }
                } footer: { Text("Forgetting disconnects the ring. Local history remains associated with its original connection.") }
            }
            .navigationTitle("My ring")
        }
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
