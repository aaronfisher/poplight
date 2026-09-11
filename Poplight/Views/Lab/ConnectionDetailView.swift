import PoplightKit
import SwiftUI

struct ConnectionDetailView: View {
    @Environment(BLEManager.self) private var ble
    let connection: BLEConnection

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                GATTTreeView(connection: connection)
            }
            .frame(minHeight: 240)

            LogView(connection: connection)
                .frame(minHeight: 160)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name).font(.title2.bold())
                HStack(spacing: 8) {
                    Text(connection.id.uuidString).font(.caption.monospaced())
                    Text(statusText).font(.caption)
                    if connection.status.isConnected {
                        Text("max write \(connection.maximumWriteWithResponse) / \(connection.maximumWriteWithoutResponse)")
                            .font(.caption)
                    }
                    if let rssi = connection.rssi {
                        Text("\(rssi) dBm").font(.caption.monospacedDigit())
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if connection.status.isConnected {
                Button("Rediscover") { connection.discoverAll() }
                Button("RSSI") { connection.readRSSI() }
                Button("Disconnect", role: .destructive) { ble.disconnect(connection.id) }
            } else {
                Button("Connect") { ble.connect(connection.id) }
                    .buttonStyle(.borderedProminent)
                Button("Forget") { ble.forget(connection.id) }
            }
        }
        .padding(12)
    }

    private var statusText: String {
        switch connection.status {
        case .connecting: "connecting…"
        case .connected: "connected"
        case .discovering: "discovering…"
        case .ready: "ready"
        case .disconnected(let reason): reason.map { "disconnected · \($0)" } ?? "disconnected"
        }
    }
}

struct GATTTreeView: View {
    let connection: BLEConnection

    var body: some View {
        if connection.services.isEmpty {
            ContentUnavailableView(
                connection.status.isConnected ? "Discovering…" : "Not connected",
                systemImage: "list.bullet.indent",
                description: Text(connection.status.isConnected ? "Waiting for services." : "Connect to browse the GATT database.")
            )
        } else {
            List {
                ForEach(connection.services) { service in
                    Section {
                        ForEach(service.characteristics) { characteristic in
                            CharacteristicRow(connection: connection, characteristic: characteristic)
                        }
                    } header: {
                        HStack {
                            Text(service.label)
                            if !service.isPrimary {
                                Text("secondary").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct CharacteristicRow: View {
    let connection: BLEConnection
    let characteristic: GATTCharacteristic
    @State private var showWrite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(characteristic.label)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                ForEach(characteristic.propertyNames, id: \.self) { name in
                    Text(name)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if characteristic.canRead {
                    Button("Read") { connection.read(characteristic) }
                }
                if characteristic.canNotify {
                    Toggle("Notify", isOn: Binding(
                        get: { characteristic.isNotifying },
                        set: { connection.setNotify($0, for: characteristic) }
                    ))
                    .toggleStyle(.checkbox)
                }
                if characteristic.canWrite || characteristic.canWriteWithoutResponse {
                    Button("Write…") { showWrite = true }
                        .popover(isPresented: $showWrite, arrowEdge: .trailing) {
                            WritePopover(connection: connection, characteristic: characteristic)
                        }
                }
            }
            .controlSize(.small)

            if let value = characteristic.value {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(value.isEmpty ? "(empty)" : value.hexString)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    if let decoded = characteristic.decodedValue {
                        Text(decoded).font(.callout).foregroundStyle(.secondary)
                    } else if !value.isEmpty {
                        Text(value.asciiPreview).font(.callout.monospaced()).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let at = characteristic.valueUpdatedAt {
                        Text("\(at.formatted(date: .omitted, time: .standard)) · r\(characteristic.readCount) n\(characteristic.notifyCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            ForEach(characteristic.descriptors) { descriptor in
                HStack(spacing: 6) {
                    Text("↳ \(descriptor.label)")
                    if let v = descriptor.value { Text(v) }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct WritePopover: View {
    let connection: BLEConnection
    let characteristic: GATTCharacteristic
    @State private var hex = ""
    @State private var withResponse: Bool
    @State private var error: String?

    init(connection: BLEConnection, characteristic: GATTCharacteristic) {
        self.connection = connection
        self.characteristic = characteristic
        _withResponse = State(initialValue: characteristic.canWrite)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Write to \(characteristic.uuid.uuidString)").font(.headline)
            TextField("hex bytes, e.g. 01 a2 ff", text: $hex)
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit(send)
            HStack {
                Picker("Type", selection: $withResponse) {
                    if characteristic.canWrite { Text("With response").tag(true) }
                    if characteristic.canWriteWithoutResponse { Text("Without response").tag(false) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button("Send", action: send)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let value = characteristic.value, !value.isEmpty {
                Button("Use current value") { hex = value.hexString }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(14)
    }

    private func send() {
        guard let data = Data(hexLoose: hex) else {
            error = "Not valid hex (even number of hex digits)."
            return
        }
        error = nil
        connection.write(data, to: characteristic, withResponse: withResponse)
    }
}
