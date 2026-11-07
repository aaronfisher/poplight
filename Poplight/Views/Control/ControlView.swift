import PoplightKit
import SwiftUI

/// Main window: one card per light.
struct ControlView: View {
    @Environment(BLEManager.self) private var ble
    @Environment(LightStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var showAdd = false

    var body: some View {
        Group {
            if store.lights.isEmpty {
                ContentUnavailableView {
                    Label("No lights yet", systemImage: "lamp.desk")
                } description: {
                    Text("Add a Poplight to control it from here.")
                } actions: {
                    Button("Add Light…") { showAdd = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        if !PoplightProtocol.isKnown {
                            ProtocolBanner()
                        }
                        ForEach(store.lights) { light in
                            LightCard(light: light)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAdd = true
                } label: {
                    Label("Add Light", systemImage: "plus")
                }
            }
            ToolbarItem {
                Button {
                    openWindow(id: LabState.windowID)
                } label: {
                    Label("Lab", systemImage: "wrench.and.screwdriver")
                }
            }
            ToolbarItem {
                Text(ble.stateDescription)
                    .font(.caption)
                    .foregroundStyle(ble.state == .poweredOn ? Color.secondary : Color.red)
            }
        }
        .sheet(isPresented: $showAdd) {
            AddLightSheet()
        }
        .onAppear { store.connectAll() }
    }
}

struct ProtocolBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Protocol not decoded yet").fontWeight(.semibold)
                Text("The app connects to the lights, but the command bytes are still unknown, so the controls below send nothing. See PROTOCOL.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LightCard: View {
    @Environment(LightStore.self) private var store
    let light: PoplightLight
    @State private var brightness: Double = 100
    @State private var isRenaming = false
    @State private var newName = ""

    private var controlsEnabled: Bool { light.isReady && PoplightProtocol.isKnown }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(light.isReady ? Color.green : light.isConnected ? Color.yellow : Color.secondary)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(light.name).font(.headline)
                    HStack(spacing: 6) {
                        Text(light.statusText)
                        if let battery = light.state.batteryPercent {
                            Label("\(battery)%", systemImage: batterySymbol(battery))
                        }
                        if let remaining = light.state.sleepTimerRemaining, remaining > 0 {
                            Label("\(remaining / 60) min", systemImage: "timer")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { light.state.isOn ?? false },
                    set: { light.setPower($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!controlsEnabled)
            }

            HStack(spacing: 10) {
                Image(systemName: "sun.min")
                Slider(value: $brightness, in: 1...100, step: 1) { editing in
                    if !editing { light.setBrightness(Int(brightness)) }
                }
                Image(systemName: "sun.max")
                Text("\(Int(brightness))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
            .disabled(!controlsEnabled)

            HStack {
                Picker("Warmth", selection: Binding(
                    get: { light.state.colorTemperature ?? .neutral },
                    set: { light.setColorTemperature($0) }
                )) {
                    Text("Warm").tag(PoplightColorTemperature.warm)
                    Text("Neutral").tag(PoplightColorTemperature.neutral)
                    Text("Cool").tag(PoplightColorTemperature.cool)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)

                Spacer()

                Menu {
                    Button("Off") { light.setSleepTimer(minutes: nil) }
                    ForEach([15, 30, 60, 120], id: \.self) { minutes in
                        Button("\(minutes) min") { light.setSleepTimer(minutes: minutes) }
                    }
                } label: {
                    Label("Timer", systemImage: "timer")
                }
                .fixedSize()
            }
            .disabled(!controlsEnabled)

            if let error = light.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            if light.isConnected {
                Button("Disconnect") { light.disconnect() }
            } else {
                Button("Connect") { light.connect() }
            }
            Button("Refresh status") { light.refresh() }.disabled(!controlsEnabled)
            Button("Rename…") { newName = light.name; isRenaming = true }
            Divider()
            Button("Remove", role: .destructive) { store.remove(light.id) }
        }
        .alert("Rename light", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Save") { store.rename(light.id, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: light.state.brightness) { _, value in
            if let value { brightness = Double(value) }
        }
        .onAppear {
            if let value = light.state.brightness { brightness = Double(value) }
        }
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
