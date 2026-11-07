import Foundation
import Observation
import PoplightKit

/// A named set of lights controlled together. Purely app-side: commands fan out to each member.
struct LightGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var lightIDs: [UUID]
}

/// The lights and groups the user has set up, persisted as JSON in Application Support.
@Observable
final class LightStore {
    private struct Record: Codable {
        var id: UUID
        var name: String
    }

    private(set) var lights: [PoplightLight] = []
    private(set) var groups: [LightGroup] = []
    @ObservationIgnored private let manager: BLEManager
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let groupsURL: URL

    init(manager: BLEManager) {
        self.manager = manager
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Poplight", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("lights.json")
        groupsURL = base.appendingPathComponent("groups.json")
        load()
    }

    // MARK: Groups

    func members(of group: LightGroup) -> [PoplightLight] {
        group.lightIDs.compactMap { light($0) }
    }

    func addGroup(name: String, lightIDs: [UUID]) {
        groups.append(LightGroup(name: name, lightIDs: lightIDs))
        saveGroups()
    }

    func updateGroup(_ group: LightGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index] = group
        saveGroups()
    }

    func removeGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        saveGroups()
    }

    /// Fan a command out to every ready light in `targets`.
    func send(_ command: PoplightCommand, to targets: [PoplightLight]) {
        for light in targets where light.isReady {
            light.send(command)
        }
    }

    func light(_ id: UUID) -> PoplightLight? {
        lights.first { $0.id == id }
    }

    @discardableResult
    func add(id: UUID, name: String) -> PoplightLight {
        if let existing = light(id) { return existing }
        let light = PoplightLight(id: id, name: name, manager: manager)
        lights.append(light)
        save()
        light.connect()
        return light
    }

    func remove(_ id: UUID) {
        guard let light = light(id) else { return }
        light.disconnect()
        manager.forget(id)
        lights.removeAll { $0.id == id }
        save()
        for index in groups.indices {
            groups[index].lightIDs.removeAll { $0 == id }
        }
        saveGroups()
    }

    func rename(_ id: UUID, to name: String) {
        guard let light = light(id) else { return }
        light.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? light.name : name
        save()
    }

    func connectAll() {
        for light in lights { light.connect() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        lights = records.map { PoplightLight(id: $0.id, name: $0.name, manager: manager) }
        if let data = try? Data(contentsOf: groupsURL),
           let saved = try? JSONDecoder().decode([LightGroup].self, from: data) {
            groups = saved
        }
    }

    private func saveGroups() {
        if let data = try? JSONEncoder().encode(groups) {
            try? data.write(to: groupsURL, options: .atomic)
        }
    }

    private func save() {
        let records = lights.map { Record(id: $0.id, name: $0.name) }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
