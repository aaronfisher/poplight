import PoplightKit
import SwiftUI

struct LabView: View {
    @Environment(BLEManager.self) private var ble
    @Environment(LabState.self) private var lab

    var body: some View {
        NavigationSplitView {
            LabSidebar()
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            if let id = lab.selectedID {
                if let connection = ble.connections[id] {
                    ConnectionDetailView(connection: connection)
                } else if let peripheral = ble.discovered(id) {
                    DiscoveredDetailView(peripheral: peripheral)
                } else {
                    ContentUnavailableView("Gone", systemImage: "antenna.radiowaves.left.and.right.slash", description: Text("This peripheral is no longer in the scan list."))
                }
            } else {
                ContentUnavailableView("Pick a peripheral", systemImage: "antenna.radiowaves.left.and.right", description: Text("Start a scan, then select a device to see its advertisement or connect and browse its GATT database."))
            }
        }
        .navigationTitle("Poplight Lab")
    }
}

struct LabSidebar: View {
    @Environment(BLEManager.self) private var ble
    @Environment(LabState.self) private var lab

    var body: some View {
        @Bindable var lab = lab
        List(selection: $lab.selectedID) {
            Section {
                HStack {
                    Button {
                        ble.toggleScan()
                    } label: {
                        Label(ble.isScanning ? "Stop scan" : "Start scan", systemImage: ble.isScanning ? "stop.circle" : "dot.radiowaves.left.and.right")
                    }
                    .disabled(ble.state != .poweredOn)
                    if ble.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Button("Clear") { ble.clearDiscovered() }
                        .controlSize(.small)
                }
                TextField("Filter by name or UUID", text: $lab.filterText)
                    .textFieldStyle(.roundedBorder)
                Toggle("Only named devices", isOn: $lab.onlyNamed)
                    .toggleStyle(.checkbox)
                Text(ble.stateDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Scan")
            }

            if !ble.connections.isEmpty {
                Section("Connections") {
                    ForEach(ble.sortedConnections) { connection in
                        ConnectionSidebarRow(connection: connection)
                            .tag(connection.id)
                    }
                }
            }

            Section("Discovered (\(filtered.count))") {
                ForEach(filtered) { peripheral in
                    DiscoveredRow(peripheral: peripheral)
                        .tag(peripheral.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var filtered: [DiscoveredPeripheral] {
        let needle = lab.filterText.trimmingCharacters(in: .whitespaces)
        return ble.discovered
            .filter { ble.connections[$0.id] == nil }
            .filter { !lab.onlyNamed || $0.name != nil || $0.advertisement.localName != nil }
            .filter { needle.isEmpty || $0.displayName.localizedCaseInsensitiveContains(needle) || $0.id.uuidString.localizedCaseInsensitiveContains(needle) }
            .sorted { a, b in
                if a.looksLikePoplight != b.looksLikePoplight { return a.looksLikePoplight }
                return a.rssi > b.rssi
            }
    }
}

private struct DiscoveredRow: View {
    let peripheral: DiscoveredPeripheral

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if peripheral.looksLikePoplight {
                        Image(systemName: "lamp.desk.fill").foregroundStyle(.orange)
                    }
                    Text(peripheral.displayName)
                        .fontWeight(peripheral.looksLikePoplight ? .semibold : .regular)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(peripheral.rssi) dBm")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let company = peripheral.advertisement.manufacturerCompanyName { parts.append(company) }
        if !peripheral.advertisement.serviceUUIDs.isEmpty {
            parts.append(peripheral.advertisement.serviceUUIDs.map(\.uuidString).joined(separator: " "))
        }
        if parts.isEmpty { parts.append(String(peripheral.id.uuidString.prefix(8))) }
        return parts.joined(separator: " · ")
    }
}

private struct ConnectionSidebarRow: View {
    let connection: BLEConnection

    var body: some View {
        HStack {
            Circle()
                .fill(connection.status.isConnected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if connection.status == .connecting || connection.status == .discovering {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var status: String {
        switch connection.status {
        case .connecting: "connecting…"
        case .connected: "connected"
        case .discovering: "discovering…"
        case .ready: "\(connection.services.count) services · \(connection.log.count) log lines"
        case .disconnected: "disconnected"
        }
    }
}

struct DiscoveredDetailView: View {
    @Environment(BLEManager.self) private var ble
    let peripheral: DiscoveredPeripheral

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text(peripheral.displayName).font(.title2.bold())
                    Text(peripheral.id.uuidString).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    ble.connect(peripheral.id)
                } label: {
                    Label("Connect", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("RSSI").foregroundStyle(.secondary)
                    Text("\(peripheral.rssi) dBm")
                }
                GridRow {
                    Text("Packets").foregroundStyle(.secondary)
                    Text("\(peripheral.packets) · first \(peripheral.firstSeen.formatted(date: .omitted, time: .standard)) · last \(peripheral.lastSeen.formatted(date: .omitted, time: .standard))")
                }
                ForEach(Array(peripheral.advertisement.details.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0).foregroundStyle(.secondary)
                        Text(row.1).font(.body.monospaced()).textSelection(.enabled)
                    }
                }
            }
            Spacer()
        }
        .padding(20)
    }
}
