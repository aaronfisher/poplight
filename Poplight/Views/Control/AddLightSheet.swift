import PoplightKit
import SwiftUI

/// Scan for Poplights and add them to the store.
struct AddLightSheet: View {
    @Environment(BLEManager.self) private var ble
    @Environment(LightStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add a Poplight").font(.title3.bold())
                Spacer()
                if ble.isScanning { ProgressView().controlSize(.small) }
                Toggle("Show all devices", isOn: $showAll).toggleStyle(.checkbox)
            }
            Text("Turn the light on and keep it within a few metres. Quit the official Poplight app first; the light accepts one connection at a time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(candidates) { peripheral in
                HStack {
                    VStack(alignment: .leading) {
                        Text(peripheral.displayName)
                        Text("\(peripheral.rssi) dBm · \(peripheral.id.uuidString.prefix(8))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.light(peripheral.id) != nil {
                        Text("Added").foregroundStyle(.secondary)
                    } else {
                        Button("Add") {
                            store.add(id: peripheral.id, name: defaultName(for: peripheral))
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView("Scanning…", systemImage: "dot.radiowaves.left.and.right", description: Text(ble.state == .poweredOn ? "No Poplight found yet." : ble.stateDescription))
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear { if ble.state == .poweredOn { ble.startScan() } }
        .onChange(of: ble.state) { _, state in if state == .poweredOn, !ble.isScanning { ble.startScan() } }
        .onDisappear { if ble.isScanning { ble.stopScan() } }
    }

    private var candidates: [DiscoveredPeripheral] {
        ble.discovered
            .filter { showAll || $0.looksLikePoplight }
            .sorted { a, b in
                if a.looksLikePoplight != b.looksLikePoplight { return a.looksLikePoplight }
                return a.rssi > b.rssi
            }
    }

    private func defaultName(for peripheral: DiscoveredPeripheral) -> String {
        let base = peripheral.looksLikePoplight ? "Poplight" : peripheral.displayName
        let taken = Set(store.lights.map(\.name))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
