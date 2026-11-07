import CoreBluetooth
import Foundation

/// Snapshot of a discovered service tree. Structs hold the CoreBluetooth objects so
/// the UI can act on them, and cached values so SwiftUI can render without touching CB.
public struct GATTService: Identifiable {
    public let id: String
    public let uuid: CBUUID
    public let isPrimary: Bool
    public let cb: CBService
    public var characteristics: [GATTCharacteristic] = []

    public var label: String { GATTNames.label(service: uuid) }
}

public struct GATTCharacteristic: Identifiable {
    public let id: String
    public let uuid: CBUUID
    public let serviceUUID: CBUUID
    public let properties: CBCharacteristicProperties
    public let cb: CBCharacteristic
    public var descriptors: [GATTDescriptor] = []
    public var value: Data?
    public var valueUpdatedAt: Date?
    public var isNotifying = false
    public var readCount = 0
    public var notifyCount = 0

    public var label: String { GATTNames.label(characteristic: uuid) }
    public var propertyNames: [String] { GATTNames.describe(properties: properties) }
    public var canRead: Bool { properties.contains(.read) }
    public var canWrite: Bool { properties.contains(.write) }
    public var canWriteWithoutResponse: Bool { properties.contains(.writeWithoutResponse) }
    public var canNotify: Bool { properties.contains(.notify) || properties.contains(.indicate) }
    public var decodedValue: String? { value.flatMap { GATTNames.decode(uuid, $0) } }
}

public struct GATTDescriptor: Identifiable {
    public let id: String
    public let uuid: CBUUID
    public let cb: CBDescriptor
    public var value: String?

    public var label: String { GATTNames.label(descriptor: uuid) }
}
