import CoreBluetooth
import Foundation
import Observation

/// One connected (or connecting) peripheral: discovers the whole GATT database,
/// optionally reads everything readable and subscribes to everything that notifies,
/// and logs every byte in both directions.
@Observable
public final class BLEConnection: NSObject, Identifiable {
    public enum Status: Equatable, Sendable {
        case connecting
        case connected
        case discovering
        case ready
        case disconnected(String?)

        public var isConnected: Bool {
            switch self {
            case .connected, .discovering, .ready: true
            default: false
            }
        }
    }

    public let id: UUID
    public let peripheral: CBPeripheral
    public var name: String
    public internal(set) var status: Status = .connecting {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    /// Called on every characteristic value update (read or notification).
    @ObservationIgnored public var onValueUpdate: ((CBUUID, Data) -> Void)?
    /// Called whenever `status` changes.
    @ObservationIgnored public var onStatusChange: ((Status) -> Void)?
    public private(set) var services: [GATTService] = []
    public private(set) var log: [LogEntry] = []
    public private(set) var maximumWriteWithResponse = 0
    public private(set) var maximumWriteWithoutResponse = 0
    public private(set) var rssi: Int?
    public private(set) var connectedAt: Date?

    /// Read every readable characteristic right after discovery.
    public var autoRead = true
    /// Subscribe to every notify/indicate characteristic right after discovery.
    public var autoSubscribe = true

    @ObservationIgnored private var pendingDiscovery = 0
    @ObservationIgnored private let persister: LogPersister
    /// Where this connection's log is being written on disk.
    public var logFileURL: URL { persister.url }
    @ObservationIgnored private var pendingReads: Set<ObjectIdentifier> = []

    init(peripheral: CBPeripheral, name: String?) {
        self.id = peripheral.identifier
        self.peripheral = peripheral
        let resolvedName = name ?? peripheral.name ?? "(unnamed)"
        self.name = resolvedName
        self.persister = LogPersister(name: resolvedName, id: peripheral.identifier)
        super.init()
        peripheral.delegate = self
    }

    // MARK: Lifecycle (driven by BLEManager)

    func handleConnected() {
        status = .connected
        connectedAt = Date()
        maximumWriteWithResponse = peripheral.maximumWriteValueLength(for: .withResponse)
        maximumWriteWithoutResponse = peripheral.maximumWriteValueLength(for: .withoutResponse)
        append(.connect, message: "connected · max write \(maximumWriteWithResponse) / \(maximumWriteWithoutResponse) (no rsp)")
        discoverAll()
    }

    func handleFailedToConnect(_ error: Error?) {
        status = .disconnected(error?.localizedDescription ?? "failed to connect")
        append(.error, message: "failed to connect: \(error?.localizedDescription ?? "unknown")")
    }

    func handleDisconnected(_ error: Error?) {
        status = .disconnected(error?.localizedDescription)
        append(.disconnect, message: error.map { "disconnected: \($0.localizedDescription)" } ?? "disconnected")
        services = []
        pendingDiscovery = 0
        pendingReads = []
    }

    // MARK: Public actions

    public func discoverAll() {
        guard status.isConnected else { return }
        status = .discovering
        services = []
        pendingDiscovery = 1
        append(.discover, message: "discovering services")
        peripheral.discoverServices(nil)
    }

    public func read(_ characteristic: GATTCharacteristic) {
        pendingReads.insert(ObjectIdentifier(characteristic.cb))
        append(.readRequest, characteristic: characteristic)
        peripheral.readValue(for: characteristic.cb)
    }

    public func write(_ data: Data, to characteristic: GATTCharacteristic, withResponse: Bool) {
        let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
        append(.write, characteristic: characteristic, data: data, message: withResponse ? "with response" : "without response")
        peripheral.writeValue(data, for: characteristic.cb, type: type)
    }

    public func setNotify(_ enabled: Bool, for characteristic: GATTCharacteristic) {
        append(.subscribe, characteristic: characteristic, message: enabled ? "subscribe" : "unsubscribe")
        peripheral.setNotifyValue(enabled, for: characteristic.cb)
    }

    public func readRSSI() {
        peripheral.readRSSI()
    }

    public func clearLog() {
        log.removeAll()
    }

    public func note(_ message: String) {
        append(.info, message: message)
    }

    // MARK: Lookup helpers

    public func characteristic(uuid: CBUUID) -> GATTCharacteristic? {
        for service in services {
            if let c = service.characteristics.first(where: { $0.uuid == uuid }) { return c }
        }
        return nil
    }

    public var allCharacteristics: [GATTCharacteristic] {
        services.flatMap(\.characteristics)
    }

    // MARK: Internals

    private func sink(_ entry: LogEntry) {
        log.append(entry)
        persister.append(entry)
    }

    private func append(_ kind: LogEntry.Kind, characteristic: GATTCharacteristic? = nil, data: Data? = nil, message: String? = nil) {
        sink(LogEntry(
            kind: kind,
            service: characteristic?.serviceUUID.uuidString,
            characteristic: characteristic?.uuid.uuidString,
            data: data,
            message: message
        ))
    }

    private func append(_ kind: LogEntry.Kind, cb: CBCharacteristic, data: Data? = nil, message: String? = nil) {
        sink(LogEntry(
            kind: kind,
            service: cb.service?.uuid.uuidString,
            characteristic: cb.uuid.uuidString,
            data: data,
            message: message
        ))
    }

    private func locate(_ cb: CBCharacteristic) -> (Int, Int)? {
        for (s, service) in services.enumerated() {
            for (c, characteristic) in service.characteristics.enumerated() where characteristic.cb === cb {
                return (s, c)
            }
        }
        return nil
    }

    private func update(_ cb: CBCharacteristic, _ body: (inout GATTCharacteristic) -> Void) {
        guard let (s, c) = locate(cb) else { return }
        body(&services[s].characteristics[c])
    }

    private func discoveryStepFinished() {
        pendingDiscovery -= 1
        if pendingDiscovery <= 0, status == .discovering {
            pendingDiscovery = 0
            status = .ready
            let count = services.reduce(0) { $0 + $1.characteristics.count }
            append(.discover, message: "ready · \(services.count) services, \(count) characteristics")
        }
    }
}

extension BLEConnection: @MainActor CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            append(.error, message: "discoverServices: \(error.localizedDescription)")
            discoveryStepFinished()
            return
        }
        let found = peripheral.services ?? []
        services = found.enumerated().map { index, service in
            GATTService(id: "\(service.uuid.uuidString)#\(index)", uuid: service.uuid, isPrimary: service.isPrimary, cb: service)
        }
        append(.discover, message: "services: " + found.map { GATTNames.label(service: $0.uuid) }.joined(separator: ", "))
        pendingDiscovery += found.count
        for service in found {
            peripheral.discoverCharacteristics(nil, for: service)
        }
        discoveryStepFinished()
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        defer { discoveryStepFinished() }
        if let error {
            append(.error, message: "discoverCharacteristics \(service.uuid): \(error.localizedDescription)")
            return
        }
        guard let index = services.firstIndex(where: { $0.cb === service }) else { return }
        let found = service.characteristics ?? []
        services[index].characteristics = found.enumerated().map { i, c in
            GATTCharacteristic(
                id: "\(service.uuid.uuidString)#\(index)/\(c.uuid.uuidString)#\(i)",
                uuid: c.uuid,
                serviceUUID: service.uuid,
                properties: c.properties,
                cb: c
            )
        }
        for c in found {
            let names = GATTNames.describe(properties: c.properties).joined(separator: ",")
            append(.discover, cb: c, message: "characteristic [\(names)]")
            pendingDiscovery += 1
            peripheral.discoverDescriptors(for: c)
            if autoRead, c.properties.contains(.read) {
                pendingReads.insert(ObjectIdentifier(c))
                peripheral.readValue(for: c)
            }
            if autoSubscribe, c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        defer { discoveryStepFinished() }
        if let error {
            append(.error, cb: characteristic, message: "discoverDescriptors: \(error.localizedDescription)")
            return
        }
        let found = characteristic.descriptors ?? []
        update(characteristic) { c in
            c.descriptors = found.enumerated().map { i, d in
                GATTDescriptor(id: "\(c.id)/\(d.uuid.uuidString)#\(i)", uuid: d.uuid, cb: d)
            }
        }
        for d in found where d.uuid.uuidString.uppercased() == "2901" {
            peripheral.readValue(for: d)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let wasRead = pendingReads.remove(ObjectIdentifier(characteristic)) != nil
        if let error {
            append(.error, cb: characteristic, message: "\(wasRead ? "read" : "notify") error: \(error.localizedDescription)")
            return
        }
        let data = characteristic.value ?? Data()
        update(characteristic) { c in
            c.value = data
            c.valueUpdatedAt = Date()
            if wasRead { c.readCount += 1 } else { c.notifyCount += 1 }
        }
        let decoded = GATTNames.decode(characteristic.uuid, data)
        append(wasRead ? .read : .notify, cb: characteristic, data: data, message: decoded)
        onValueUpdate?(characteristic.uuid, data)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            append(.error, cb: characteristic, message: "write error: \(error.localizedDescription)")
        } else {
            append(.writeResponse, cb: characteristic, message: "write ok")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            append(.error, cb: characteristic, message: "notify state error: \(error.localizedDescription)")
            return
        }
        update(characteristic) { $0.isNotifying = characteristic.isNotifying }
        append(.subscribe, cb: characteristic, message: characteristic.isNotifying ? "notifying" : "not notifying")
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        guard error == nil, let characteristic = descriptor.characteristic else { return }
        let text: String? = switch descriptor.value {
        case let s as String: s
        case let d as Data: d.hexString
        case let n as NSNumber: n.stringValue
        default: nil
        }
        update(characteristic) { c in
            if let i = c.descriptors.firstIndex(where: { $0.cb === descriptor }) {
                c.descriptors[i].value = text
            }
        }
        if let text {
            append(.read, cb: characteristic, message: "descriptor \(GATTNames.label(descriptor: descriptor.uuid)) = \(text)")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        rssi = RSSI.intValue
    }

    public func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        if let n = peripheral.name {
            name = n
            append(.info, message: "name changed to \(n)")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        append(.info, message: "services modified (\(invalidatedServices.count) invalidated), rediscovering")
        discoverAll()
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // Flow control hook for bulk writes; nothing queued yet.
    }
}
