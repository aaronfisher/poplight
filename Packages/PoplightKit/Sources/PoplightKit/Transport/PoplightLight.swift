import CoreBluetooth
import Foundation
import Observation

/// One Poplight as the app sees it: a remembered peripheral, its connection, cached
/// state, and the high-level commands. Reconnects by itself when the link drops.
@Observable
public final class PoplightLight: Identifiable {
    public let id: UUID
    public var name: String
    public private(set) var state = PoplightState()
    public private(set) var connection: BLEConnection?
    public private(set) var lastError: String?
    public private(set) var lastStatusAt: Date?
    /// Reconnect automatically after a drop. Cleared by `disconnect()`.
    public var autoReconnect = true

    @ObservationIgnored private let manager: BLEManager
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// How often to ask the light for its battery level while connected.
    public var batteryPollInterval: Duration = .seconds(120)
    @ObservationIgnored private let commandUUID = CBUUID(string: PoplightProtocol.commandCharacteristicUUID)
    @ObservationIgnored private let statusUUID = CBUUID(string: PoplightProtocol.statusCharacteristicUUID)

    public init(id: UUID, name: String, manager: BLEManager) {
        self.id = id
        self.name = name
        self.manager = manager
        if let existing = manager.connections[id] {
            attach(existing)
        }
    }

    // MARK: Connection

    public var isConnected: Bool { connection?.status.isConnected ?? false }

    /// Connected and the command characteristic has been discovered.
    public var isReady: Bool { connection?.status == .ready && commandCharacteristic != nil }

    public var statusText: String {
        guard let connection else { return autoReconnect ? "not connected" : "disconnected" }
        switch connection.status {
        case .connecting: return "connecting…"
        case .connected, .discovering: return "connecting…"
        case .ready: return commandCharacteristic == nil ? "connected, no FFB1" : "connected"
        case .disconnected(let reason):
            if autoReconnect { return "reconnecting…" }
            return reason.map { "disconnected · \($0)" } ?? "disconnected"
        }
    }

    public func connect() {
        autoReconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        lastError = nil
        if let c = manager.connect(id) {
            attach(c)
        } else if manager.state == .poweredOn, manager.connections[id] == nil {
            // Manager is scanning for it; it will appear in `connections` once found.
            scheduleReconnect(after: 2)
        }
    }

    public func disconnect() {
        autoReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        pollTask?.cancel()
        pollTask = nil
        manager.disconnect(id)
    }

    private func attach(_ c: BLEConnection) {
        guard connection !== c else { return }
        connection = c
        c.onValueUpdate = { [weak self] uuid, data in self?.handleValue(uuid: uuid, data: data) }
        c.onStatusChange = { [weak self] status in self?.handleStatus(status) }
        handleStatus(c.status)
    }

    private func handleStatus(_ status: BLEConnection.Status) {
        switch status {
        case .ready:
            lastError = commandCharacteristic == nil ? "This device has no \(PoplightProtocol.commandCharacteristicUUID) characteristic" : nil
            startPolling()
        case .disconnected:
            pollTask?.cancel()
            pollTask = nil
            if autoReconnect { scheduleReconnect(after: 3) }
        default:
            break
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isReady else { return }
                self.send(.queryStatus)
                try? await Task.sleep(for: self.batteryPollInterval)
            }
        }
    }

    private func scheduleReconnect(after seconds: Double) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.autoReconnect else { return }
            if let c = self.manager.connections[self.id] { self.attach(c) }
            self.connect()
        }
    }

    // MARK: Commands

    private var commandCharacteristic: GATTCharacteristic? {
        connection?.characteristic(uuid: commandUUID)
    }

    public func send(_ command: PoplightCommand) {
        guard let data = PoplightProtocol.encode(command) else {
            lastError = "The light has no command for that yet"
            return
        }
        guard let connection, let characteristic = commandCharacteristic, connection.status == .ready else {
            lastError = "Not connected"
            return
        }
        lastError = nil
        let withResponse = PoplightProtocol.wantsResponse(command) ? characteristic.canWrite : !characteristic.canWriteWithoutResponse
        connection.write(data, to: characteristic, withResponse: withResponse)
        state.apply(command)
    }

    public func setPower(_ on: Bool) { send(.power(on)) }
    public func setBrightness(_ percent: Int) { send(.brightness(percent)) }
    public func setColorTemperature(_ t: PoplightColorTemperature) { send(.colorTemperature(t)) }
    public func setSleepTimer(minutes: Int?) { send(.sleepTimer(seconds: minutes.map { $0 * 60 })) }
    public func refresh() { send(.queryStatus) }

    private func handleValue(uuid: CBUUID, data: Data) {
        guard uuid == statusUUID, let parsed = PoplightProtocol.decodeStatus(data) else { return }
        state.merge(parsed)
        lastStatusAt = Date()
    }
}
