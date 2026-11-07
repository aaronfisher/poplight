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
                ForEach(store.lights) { light in
                    CompactLightRow(light: light)
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

private struct CompactLightRow: View {
    let light: PoplightLight
    @State private var brightness: Double = 99

    private var enabled: Bool { light.isReady && PoplightProtocol.isKnown }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(light.isReady ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(light.name)
                Spacer()
                if let battery = light.state.batteryPercent {
                    Text("\(battery)%").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("", isOn: Binding(get: { light.state.isOn ?? false }, set: { light.setPower($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!enabled)
            }
            Slider(value: $brightness, in: 1...99, step: 1) { editing in
                if !editing { light.setBrightness(Int(brightness)) }
            }
            .controlSize(.small)
            .disabled(!enabled)
        }
        .onChange(of: light.state.brightness) { _, value in
            if let value { brightness = Double(value) }
        }
    }
}
