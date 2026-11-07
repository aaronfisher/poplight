import PoplightKit
import SwiftUI

/// A card that controls several lights at once. `group == nil` is the implicit "All Lights".
struct GroupCard: View {
    @Environment(LightStore.self) private var store
    let title: String
    let lights: [PoplightLight]
    var group: LightGroup?
    var onEdit: (() -> Void)?
    @State private var brightness: Double = 99

    private var ready: [PoplightLight] { lights.filter(\.isReady) }
    private var enabled: Bool { !ready.isEmpty }
    private var anyOn: Bool { lights.contains { $0.state.isOn == true } }
    private var warmth: PoplightColorTemperature {
        let values = Set(lights.compactMap(\.state.colorTemperature))
        return values.count == 1 ? values.first! : .neutral
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group")
                    .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ControlsPanel.powerSwitch(isOn: anyOn, enabled: enabled) { on in
                    store.send(.power(on), to: lights)
                }
            }
            ControlsPanel(
                isOn: anyOn,
                warmth: warmth,
                enabled: enabled,
                brightness: $brightness,
                onPower: { store.send(.power($0), to: lights) },
                onBrightness: { store.send(.brightness($0), to: lights) },
                onWarmth: { store.send(.colorTemperature($0), to: lights) },
                onTimer: { store.send(.sleepTimer(seconds: $0 * 60), to: lights) }
            )
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.35)))
        .contextMenu {
            if let group {
                Button("Edit Group…") { onEdit?() }
                Divider()
                Button("Delete Group", role: .destructive) { store.removeGroup(group.id) }
            }
        }
    }

    private var subtitle: String {
        var parts = ["\(ready.count) of \(lights.count) connected"]
        let batteries = lights.compactMap(\.state.batteryPercent)
        if let lowest = batteries.min() { parts.append("lowest battery \(lowest)%") }
        if lights.isEmpty { parts = ["no lights in this group"] }
        return parts.joined(separator: " · ")
    }
}

/// Create or edit a group.
struct GroupEditorSheet: View {
    @Environment(LightStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var existing: LightGroup?
    @State private var name: String
    @State private var selected: Set<UUID>

    init(existing: LightGroup? = nil) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _selected = State(initialValue: Set(existing?.lightIDs ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New Group" : "Edit Group").font(.title3.bold())
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("Lights").font(.subheadline).foregroundStyle(.secondary)
            ForEach(store.lights) { light in
                Toggle(light.name, isOn: Binding(
                    get: { selected.contains(light.id) },
                    set: { if $0 { selected.insert(light.id) } else { selected.remove(light.id) } }
                ))
                .toggleStyle(.checkbox)
            }
            if store.lights.isEmpty {
                Text("Add lights first.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Create" : "Save") {
                    let ids = store.lights.map(\.id).filter { selected.contains($0) }
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if var group = existing {
                        group.name = trimmed
                        group.lightIDs = ids
                        store.updateGroup(group)
                    } else {
                        store.addGroup(name: trimmed, lightIDs: ids)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}
