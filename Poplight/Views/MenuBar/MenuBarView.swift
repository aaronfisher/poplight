import PoplightKit
import SwiftUI

struct MenuBarView: View {
    @Environment(BLEManager.self) private var ble
    @Environment(LightStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Poplight", systemImage: "lamp.desk").font(.headline)
                Spacer()
                Text(ble.stateDescription).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            if store.lights.isEmpty {
                Text("No lights added yet.").foregroundStyle(.secondary)
            } else {
                if store.lights.count > 1 {
                    CompactRow(title: "All Lights", lights: store.lights, isGroup: true)
                }
                ForEach(store.groups) { group in
                    CompactRow(title: group.name, lights: store.members(of: group), isGroup: true)
                }
                ForEach(store.lights) { light in
                    CompactRow(title: light.name, lights: [light], isGroup: false)
                }
            }

            Divider()

            Button {
                openWindow(id: "main")
                NSApp.activate()
            } label: {
                Label("Open Poplight", systemImage: "macwindow")
            }
            .keyboardShortcut("o")

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
}

private struct CompactRow: View {
    @Environment(LightStore.self) private var store
    let title: String
    let lights: [PoplightLight]
    let isGroup: Bool
    @State private var brightness: Double = 99

    private var enabled: Bool { lights.contains(where: \.isReady) && PoplightProtocol.isKnown }
    private var isOn: Bool { lights.contains { $0.state.isOn == true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if isGroup {
                    Image(systemName: "rectangle.3.group").foregroundStyle(.secondary)
                } else {
                    Circle()
                        .fill(lights.first?.isReady == true ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                }
                Text(title).fontWeight(isGroup ? .semibold : .regular)
                Spacer()
                if !isGroup, let battery = lights.first?.state.batteryPercent {
                    Text("\(battery)%").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("", isOn: Binding(get: { isOn }, set: { store.send(.power($0), to: lights) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!enabled)
            }
            Slider(value: $brightness, in: 1...99, step: 1) { editing in
                if !editing { store.send(.brightness(Int(brightness)), to: lights) }
            }
            .controlSize(.small)
            .disabled(!enabled)
        }
        .onChange(of: lights.first?.state.brightness) { _, value in
            if !isGroup, let value { brightness = Double(value) }
        }
    }
}
