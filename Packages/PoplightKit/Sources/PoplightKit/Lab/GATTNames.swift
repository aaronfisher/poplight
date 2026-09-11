import CoreBluetooth
import Foundation

/// Human names for well-known GATT UUIDs and Bluetooth SIG company IDs, plus
/// value decoders for the standard characteristics we care about.
public enum GATTNames {
    nonisolated static let services: [String: String] = [
        "1800": "Generic Access",
        "1801": "Generic Attribute",
        "1802": "Immediate Alert",
        "1803": "Link Loss",
        "1804": "Tx Power",
        "1805": "Current Time",
        "180A": "Device Information",
        "180F": "Battery",
        "1812": "Human Interface Device",
        "181C": "User Data",
        "1819": "Location and Navigation",
        "FE59": "Nordic Secure DFU",
        "FEF5": "Dialog DFU",
        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E": "Nordic UART Service",
        "0000FFE0-0000-1000-8000-00805F9B34FB": "Vendor serial (FFE0, HM-10 style)",
        "FFE0": "Vendor serial (FFE0, HM-10 style)",
        "FFF0": "Vendor (FFF0)",
        "FF00": "Vendor (FF00)",
        "AE00": "Vendor (AE00, common LED controllers)",
        "00010203-0405-0607-0809-0A0B0C0D1910": "Telink mesh",
        "0000FEE7-0000-1000-8000-00805F9B34FB": "Tencent WeChat",
    ]

    nonisolated static let characteristics: [String: String] = [
        "2A00": "Device Name",
        "2A01": "Appearance",
        "2A02": "Peripheral Privacy Flag",
        "2A03": "Reconnection Address",
        "2A04": "Peripheral Preferred Connection Parameters",
        "2A05": "Service Changed",
        "2A06": "Alert Level",
        "2A07": "Tx Power Level",
        "2A19": "Battery Level",
        "2A23": "System ID",
        "2A24": "Model Number",
        "2A25": "Serial Number",
        "2A26": "Firmware Revision",
        "2A27": "Hardware Revision",
        "2A28": "Software Revision",
        "2A29": "Manufacturer Name",
        "2A2A": "IEEE Regulatory Certification",
        "2A50": "PnP ID",
        "2AA6": "Central Address Resolution",
        "2B29": "Client Supported Features",
        "2B2A": "Database Hash",
        "6E400002-B5A3-F393-E0A9-E50E24DCCA9E": "NUS RX (write to device)",
        "6E400003-B5A3-F393-E0A9-E50E24DCCA9E": "NUS TX (notify from device)",
        "FFE1": "Vendor serial data (FFE1)",
        "FFF1": "Vendor (FFF1)",
        "FFF2": "Vendor (FFF2)",
        "AE01": "Vendor write (AE01)",
        "AE02": "Vendor notify (AE02)",
        "00010203-0405-0607-0809-0A0B0C0D1911": "Telink status",
        "00010203-0405-0607-0809-0A0B0C0D1912": "Telink command",
        "00010203-0405-0607-0809-0A0B0C0D1913": "Telink OTA",
        "00010203-0405-0607-0809-0A0B0C0D1914": "Telink pair",
    ]

    nonisolated static let descriptors: [String: String] = [
        "2900": "Extended Properties",
        "2901": "User Description",
        "2902": "Client Characteristic Configuration",
        "2903": "Server Characteristic Configuration",
        "2904": "Presentation Format",
        "2905": "Aggregate Format",
    ]

    nonisolated static let companies: [UInt16: String] = [
        0x0000: "Ericsson", 0x0002: "Intel", 0x0006: "Microsoft", 0x000D: "Texas Instruments",
        0x0030: "STMicroelectronics", 0x004C: "Apple", 0x0059: "Nordic Semiconductor",
        0x0075: "Samsung", 0x00E0: "Google", 0x0157: "Anhui Huami", 0x0211: "Telink Semiconductor",
        0x02E5: "Espressif", 0x038F: "Xiaomi", 0x0499: "Ruuvi", 0x0822: "adafruit",
        0x0D96: "Silicon Labs (Zhuhai Jieli)", 0x05A7: "Sonos", 0x0310: "SGL Italia",
    ]

    nonisolated public static func serviceName(_ uuid: CBUUID) -> String? {
        services[uuid.uuidString.uppercased()]
    }

    nonisolated public static func characteristicName(_ uuid: CBUUID) -> String? {
        characteristics[uuid.uuidString.uppercased()]
    }

    nonisolated public static func descriptorName(_ uuid: CBUUID) -> String? {
        descriptors[uuid.uuidString.uppercased()]
    }

    nonisolated public static func companyName(_ id: UInt16) -> String? {
        companies[id]
    }

    /// Short label: "180F Battery" or the raw UUID when unknown.
    nonisolated public static func label(service uuid: CBUUID) -> String {
        if let name = serviceName(uuid) { return "\(uuid.uuidString) · \(name)" }
        return uuid.uuidString
    }

    nonisolated public static func label(characteristic uuid: CBUUID) -> String {
        if let name = characteristicName(uuid) { return "\(uuid.uuidString) · \(name)" }
        return uuid.uuidString
    }

    nonisolated public static func label(descriptor uuid: CBUUID) -> String {
        if let name = descriptorName(uuid) { return "\(uuid.uuidString) · \(name)" }
        return uuid.uuidString
    }

    /// Best-effort decode of a characteristic value for display next to the hex.
    nonisolated public static func decode(_ uuid: CBUUID, _ data: Data) -> String? {
        switch uuid.uuidString.uppercased() {
        case "2A19":
            return data.first.map { "\($0)%" }
        case "2A00", "2A24", "2A25", "2A26", "2A27", "2A28", "2A29", "2901":
            return String(data: data, encoding: .utf8).map { "\"\($0)\"" }
        case "2A01":
            guard data.count >= 2 else { return nil }
            let value = UInt16(data[data.startIndex]) | UInt16(data[data.startIndex + 1]) << 8
            return String(format: "appearance 0x%04x", value)
        case "2A50":
            guard data.count >= 7 else { return nil }
            let b = [UInt8](data)
            let vendor = UInt16(b[1]) | UInt16(b[2]) << 8
            let product = UInt16(b[3]) | UInt16(b[4]) << 8
            let version = UInt16(b[5]) | UInt16(b[6]) << 8
            let source = b[0] == 1 ? "SIG" : b[0] == 2 ? "USB" : "src\(b[0])"
            return String(format: "%@ vendor 0x%04x product 0x%04x v0x%04x", source, vendor, product, version)
        case "2A04":
            guard data.count >= 8 else { return nil }
            let b = [UInt8](data)
            func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
            return "conn interval \(Double(u16(0)) * 1.25)–\(Double(u16(2)) * 1.25) ms, latency \(u16(4)), timeout \(u16(6) * 10) ms"
        case "2902":
            guard data.count >= 2 else { return nil }
            let value = UInt16(data[data.startIndex]) | UInt16(data[data.startIndex + 1]) << 8
            switch value {
            case 0: return "notifications off"
            case 1: return "notifications on"
            case 2: return "indications on"
            default: return String(format: "cccd 0x%04x", value)
            }
        default:
            if data.isMostlyPrintable, let text = String(data: data, encoding: .utf8) {
                return "\"\(text)\""
            }
            return nil
        }
    }

    nonisolated public static func describe(properties: CBCharacteristicProperties) -> [String] {
        var out: [String] = []
        if properties.contains(.broadcast) { out.append("broadcast") }
        if properties.contains(.read) { out.append("read") }
        if properties.contains(.writeWithoutResponse) { out.append("write-no-rsp") }
        if properties.contains(.write) { out.append("write") }
        if properties.contains(.notify) { out.append("notify") }
        if properties.contains(.indicate) { out.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { out.append("signed-write") }
        if properties.contains(.extendedProperties) { out.append("ext") }
        if properties.contains(.notifyEncryptionRequired) { out.append("notify-enc") }
        if properties.contains(.indicateEncryptionRequired) { out.append("indicate-enc") }
        return out
    }
}
