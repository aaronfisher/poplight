import PoplightKit
import SwiftUI

struct MenuBarView: View {
    @Environment(BLEManager.self) private var ble
    @Environment(LabState.self) private var lab
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Poplight", systemImage: "lamp.desk")
                    .font(.headline)
                Spacer()
                Text(ble.stateDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if ble.connections.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No lights connected")
                        .foregroundStyle(.secondary)
                    Text("Open the Lab to scan for your Poplights. Controls appear here once the protocol is known.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                ForEach(ble.sortedConnections) { connection in
                    LightRow(connection: connection)
                }
            }

            Divider()

            Button {
                openLab()
            } label: {
                Label("Open Lab…", systemImage: "wrench.and.screwdriver")
            }
            .keyboardShortcut("l")

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Poplight", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(width: 320)
    }

    private func openLab() {
        openWindow(id: LabState.windowID)
        NSApp.activate()
    }
}

private struct LightRow: View {
    @Environment(BLEManager.self) private var ble
    let connection: BLEConnection

    var body: some View {
        HStack {
            Circle()
                .fill(connection.status.isConnected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(connection.name)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if connection.status.isConnected {
                Button("Disconnect") { ble.disconnect(connection.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Connect") { ble.connect(connection.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var statusText: String {
        switch connection.status {
        case .connecting: "connecting…"
        case .connected: "connected"
        case .discovering: "discovering services…"
        case .ready: "ready · \(connection.allCharacteristics.count) characteristics"
        case .disconnected(let reason): reason.map { "disconnected: \($0)" } ?? "disconnected"
        }
    }
}
