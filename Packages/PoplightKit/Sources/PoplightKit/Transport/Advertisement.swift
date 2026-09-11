import CoreBluetooth
import Foundation

/// Decoded advertisement payload from `centralManager(_:didDiscover:advertisementData:rssi:)`.
public struct Advertisement {
    public var localName: String?
    public var serviceUUIDs: [CBUUID] = []
    public var overflowServiceUUIDs: [CBUUID] = []
    public var solicitedServiceUUIDs: [CBUUID] = []
    public var serviceData: [CBUUID: Data] = [:]
    public var manufacturerData: Data?
    public var txPower: Int?
    public var isConnectable: Bool?

    public init() {}

    public init(_ dict: [String: Any]) {
        localName = dict[CBAdvertisementDataLocalNameKey] as? String
        serviceUUIDs = dict[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        overflowServiceUUIDs = dict[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        solicitedServiceUUIDs = dict[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? []
        serviceData = dict[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        manufacturerData = dict[CBAdvertisementDataManufacturerDataKey] as? Data
        txPower = (dict[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        isConnectable = (dict[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
    }

    /// Merge a newer advertisement into this one (scan responses arrive as separate callbacks).
    public mutating func merge(_ other: Advertisement) {
        if let n = other.localName { localName = n }
        if !other.serviceUUIDs.isEmpty { serviceUUIDs = other.serviceUUIDs }
        if !other.overflowServiceUUIDs.isEmpty { overflowServiceUUIDs = other.overflowServiceUUIDs }
        if !other.solicitedServiceUUIDs.isEmpty { solicitedServiceUUIDs = other.solicitedServiceUUIDs }
        if !other.serviceData.isEmpty { serviceData.merge(other.serviceData) { $1 } }
        if let m = other.manufacturerData { manufacturerData = m }
        if let t = other.txPower { txPower = t }
        if let c = other.isConnectable { isConnectable = c }
    }

    public var manufacturerCompanyID: UInt16? {
        guard let m = manufacturerData, m.count >= 2 else { return nil }
        return UInt16(m[m.startIndex]) | UInt16(m[m.startIndex + 1]) << 8
    }

    public var manufacturerCompanyName: String? {
        manufacturerCompanyID.flatMap { GATTNames.companyName($0) }
    }

    /// Multi-line description for the Lab detail pane.
    public var details: [(String, String)] {
        var rows: [(String, String)] = []
        if let localName { rows.append(("Local name", localName)) }
        if let isConnectable { rows.append(("Connectable", isConnectable ? "yes" : "no")) }
        if let txPower { rows.append(("Tx power", "\(txPower) dBm")) }
        if !serviceUUIDs.isEmpty { rows.append(("Services", serviceUUIDs.map { GATTNames.label(service: $0) }.joined(separator: "\n"))) }
        if !overflowServiceUUIDs.isEmpty { rows.append(("Overflow services", overflowServiceUUIDs.map(\.uuidString).joined(separator: "\n"))) }
        if !solicitedServiceUUIDs.isEmpty { rows.append(("Solicited services", solicitedServiceUUIDs.map(\.uuidString).joined(separator: "\n"))) }
        for (uuid, data) in serviceData.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            rows.append(("Service data \(uuid.uuidString)", "\(data.hexString)  \(data.asciiPreview)"))
        }
        if let m = manufacturerData {
            var text = m.hexString
            if let id = manufacturerCompanyID {
                text += String(format: "\ncompany 0x%04x", id)
                if let name = manufacturerCompanyName { text += " (\(name))" }
                text += "\npayload " + m.dropFirst(2).hexString + "  " + m.dropFirst(2).asciiPreview
            }
            rows.append(("Manufacturer data", text))
        }
        return rows
    }
}

/// A peripheral seen while scanning.
public struct DiscoveredPeripheral: Identifiable {
    public let id: UUID
    public var name: String?
    public var rssi: Int
    public var advertisement: Advertisement
    public var firstSeen: Date
    public var lastSeen: Date
    public var packets: Int

    public var displayName: String {
        name ?? advertisement.localName ?? "(unnamed)"
    }

    public var looksLikePoplight: Bool {
        displayName.localizedCaseInsensitiveContains("pop")
    }
}
