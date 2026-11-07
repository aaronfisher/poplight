import Foundation
import Observation
import PoplightKit

/// The lights the user has added, persisted as JSON in Application Support.
@Observable
final class LightStore {
    private struct Record: Codable {
        var id: UUID
        var name: String
    }

    private(set) var lights: [PoplightLight] = []
    @ObservationIgnored private let manager: BLEManager
    @ObservationIgnored private let fileURL: URL

    init(manager: BLEManager) {
        self.manager = manager
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Poplight", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("lights.json")
        load()
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
    }

    private func save() {
        let records = lights.map { Record(id: $0.id, name: $0.name) }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
