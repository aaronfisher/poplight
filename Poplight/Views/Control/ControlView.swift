import PoplightKit
import SwiftUI

/// Main window: groups first, then one card per light.
struct ControlView: View {
    @Environment(BLEManager.self) private var ble
    @Environment(LightStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var showAdd = false
    @State private var showNewGroup = false
    @State private var editingGroup: LightGroup?

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
                        if store.lights.count > 1 {
                            GroupCard(title: "All Lights", lights: store.lights)
                        }
                        ForEach(store.groups) { group in
                            GroupCard(title: group.name, lights: store.members(of: group), group: group) {
                                editingGroup = group
                            }
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
                Menu {
                    Button("Add Light…") { showAdd = true }
                    Button("New Group…") { showNewGroup = true }
                        .disabled(store.lights.count < 2)
                } label: {
                    Label("Add", systemImage: "plus")
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
        .sheet(isPresented: $showAdd) { AddLightSheet() }
        .sheet(isPresented: $showNewGroup) { GroupEditorSheet() }
        .sheet(item: $editingGroup) { group in GroupEditorSheet(existing: group) }
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
    @State private var brightness: Double = 99
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
                ControlsPanel.powerSwitch(isOn: light.state.isOn ?? false, enabled: controlsEnabled) { light.setPower($0) }
            }

            ControlsPanel(
                isOn: light.state.isOn ?? false,
                warmth: light.state.colorTemperature ?? .neutral,
                enabled: controlsEnabled,
                brightness: $brightness,
                onPower: { light.setPower($0) },
                onBrightness: { light.setBrightness($0) },
                onWarmth: { light.setColorTemperature($0) },
                onTimer: { light.setSleepTimer(minutes: $0) }
            )

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
            Button("Refresh battery") { light.refresh() }.disabled(!controlsEnabled)
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
