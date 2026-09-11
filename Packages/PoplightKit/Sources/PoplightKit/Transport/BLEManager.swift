import CoreBluetooth
import Foundation
import Observation

/// The single CoreBluetooth central for the app. Runs entirely on the main actor
/// (the CBCentralManager is created with the main queue) so SwiftUI can observe it directly.
@Observable
public final class BLEManager: NSObject {
    public private(set) var state: CBManagerState = .unknown
    public private(set) var isScanning = false
    public private(set) var discovered: [DiscoveredPeripheral] = []
    public private(set) var connections: [UUID: BLEConnection] = [:]
    public private(set) var log: [LogEntry] = []

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    public var stateDescription: String {
        switch state {
        case .poweredOn: "Bluetooth on"
        case .poweredOff: "Bluetooth off"
        case .unauthorized: "Bluetooth not authorized"
        case .unsupported: "Bluetooth unsupported"
        case .resetting: "Bluetooth resetting"
        case .unknown: "Bluetooth starting"
        @unknown default: "Bluetooth ?"
        }
    }

    public var sortedConnections: [BLEConnection] {
        connections.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Scanning

    public func startScan(services: [CBUUID]? = nil) {
        guard state == .poweredOn else {
            append(.error, "cannot scan: \(stateDescription)")
            return
        }
        central.scanForPeripherals(withServices: services, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true,
        ])
        isScanning = true
        append(.info, "scan started" + (services.map { " for \($0)" } ?? ""))
    }

    public func stopScan() {
        central.stopScan()
        isScanning = false
        append(.info, "scan stopped")
    }

    public func toggleScan() {
        isScanning ? stopScan() : startScan()
    }

    /// Drop scan results that are not connected.
    public func clearDiscovered() {
        discovered.removeAll { connections[$0.id] == nil }
    }

    public func discovered(_ id: UUID) -> DiscoveredPeripheral? {
        discovered.first { $0.id == id }
    }

    // MARK: Connections

    @discardableResult
    public func connect(_ id: UUID) -> BLEConnection? {
        if let existing = connections[id], existing.status.isConnected || existing.status == .connecting {
            return existing
        }
        var peripheral = peripherals[id]
        if peripheral == nil {
            peripheral = central.retrievePeripherals(withIdentifiers: [id]).first
            if let peripheral { peripherals[id] = peripheral }
        }
        guard let peripheral else {
            append(.error, "connect: unknown peripheral \(id)")
            return nil
        }
        let connection = connections[id] ?? BLEConnection(peripheral: peripheral, name: discovered(id)?.displayName)
        connection.status = .connecting
        connections[id] = connection
        append(.connect, "connecting to \(connection.name)")
        central.connect(peripheral, options: nil)
        return connection
    }

    public func disconnect(_ id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    /// Disconnect and drop the connection object (its log goes with it).
    public func forget(_ id: UUID) {
        disconnect(id)
        connections[id] = nil
    }

    public func clearLog() {
        log.removeAll()
    }

    private func append(_ kind: LogEntry.Kind, _ message: String) {
        log.append(LogEntry(kind: kind, message: message))
    }
}

extension BLEManager: @MainActor CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        append(.info, stateDescription)
        if state != .poweredOn {
            isScanning = false
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        let advertisement = Advertisement(advertisementData)
        let now = Date()
        if let index = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
            discovered[index].rssi = RSSI.intValue
            discovered[index].lastSeen = now
            discovered[index].packets += 1
            discovered[index].advertisement.merge(advertisement)
            if let name = peripheral.name { discovered[index].name = name }
        } else {
            discovered.append(DiscoveredPeripheral(
                id: peripheral.identifier,
                name: peripheral.name,
                rssi: RSSI.intValue,
                advertisement: advertisement,
                firstSeen: now,
                lastSeen: now,
                packets: 1
            ))
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        append(.connect, "connected \(peripheral.name ?? peripheral.identifier.uuidString)")
        connections[peripheral.identifier]?.handleConnected()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        append(.error, "failed to connect \(peripheral.name ?? peripheral.identifier.uuidString): \(error?.localizedDescription ?? "?")")
        connections[peripheral.identifier]?.handleFailedToConnect(error)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        append(.disconnect, "disconnected \(peripheral.name ?? peripheral.identifier.uuidString)" + (error.map { ": \($0.localizedDescription)" } ?? ""))
        connections[peripheral.identifier]?.handleDisconnected(error)
    }
}
