import Foundation

// MARK: - Poplight protocol
//
// Recovered 2026-11-06 by decompiling the official Flutter app (v1.0.8) with Blutter.
// Everything in this file is pure data + byte codecs with no CoreBluetooth dependency,
// so it can be ported 1:1 to TypeScript (Homebridge) or Python (Home Assistant).
// See PROTOCOL.md at the repo root for the human-readable description.

nonisolated public enum PoplightColorTemperature: String, CaseIterable, Sendable, Codable {
    case warm, neutral, cool

    /// Wire value used by the warmth command `[1, 6, value]`.
    public var wireValue: UInt8 {
        switch self {
        case .cool: 0
        case .neutral: 1
        case .warm: 2
        }
    }

    public init?(wireValue: UInt8) {
        switch wireValue {
        case 0: self = .cool
        case 1: self = .neutral
        case 2: self = .warm
        default: return nil
        }
    }
}

nonisolated public struct PoplightState: Equatable, Sendable, Codable {
    public var isOn: Bool?
    /// 1…99 (the light clamps 100 to 99).
    public var brightness: Int?
    public var colorTemperature: PoplightColorTemperature?
    /// 0…100, already mapped from the light's raw level.
    public var batteryPercent: Int?
    /// Raw battery byte as reported by the light (20/40/60/80 steps seen).
    public var batteryRaw: Int?
    /// Remaining sleep-timer seconds, nil when no timer is set.
    public var sleepTimerRemaining: Int?

    public init(isOn: Bool? = nil, brightness: Int? = nil, colorTemperature: PoplightColorTemperature? = nil, batteryPercent: Int? = nil, batteryRaw: Int? = nil, sleepTimerRemaining: Int? = nil) {
        self.isOn = isOn
        self.brightness = brightness
        self.colorTemperature = colorTemperature
        self.batteryPercent = batteryPercent
        self.batteryRaw = batteryRaw
        self.sleepTimerRemaining = sleepTimerRemaining
    }

    /// Overlay the non-nil fields of `other` onto self.
    public mutating func merge(_ other: PoplightState) {
        if let v = other.isOn { isOn = v }
        if let v = other.brightness { brightness = v }
        if let v = other.colorTemperature { colorTemperature = v }
        if let v = other.batteryPercent { batteryPercent = v }
        if let v = other.batteryRaw { batteryRaw = v }
        if let v = other.sleepTimerRemaining { sleepTimerRemaining = v }
    }

    /// What we expect the light's state to be after `command` succeeds.
    public mutating func apply(_ command: PoplightCommand) {
        switch command {
        case .power(let on): isOn = on
        case .brightness(let b): brightness = PoplightProtocol.clampBrightness(b)
        case .colorTemperature(let t): colorTemperature = t
        case .sleepTimer(let seconds): sleepTimerRemaining = seconds
        case .queryStatus: break
        }
    }
}

nonisolated public enum PoplightCommand: Equatable, Sendable {
    case power(Bool)
    case brightness(Int)
    case colorTemperature(PoplightColorTemperature)
    /// `nil` cancels. Minutes are rounded to the light's 15-minute steps (15…720).
    case sleepTimer(seconds: Int?)
    /// Asks for the battery level; the answer arrives as a notification on the status characteristic.
    case queryStatus
}

/// Byte-level codec for the Poplight.
nonisolated public enum PoplightProtocol {
    /// Advertised name used to recognise a Poplight while scanning.
    public static let advertisedNameHint = "POP_Light"

    /// GATT UUIDs, as strings so this file stays free of CoreBluetooth.
    public static let serviceUUID = "FFB0"
    public static let commandCharacteristicUUID = "FFB1"   // "Characteristic 3": write / write-no-rsp
    public static let statusCharacteristicUUID = "FFB2"    // "Characteristic 4": notify (and write)

    public static let isKnown = true

    public static let minBrightness = 1
    public static let maxBrightness = 99
    public static let timerStepMinutes = 15
    public static let maxTimerMinutes = 720

    public static func clampBrightness(_ value: Int) -> Int {
        max(minBrightness, min(maxBrightness, value))
    }

    /// Minutes → timer index (1…48), rounding to the nearest 15-minute step. `nil` for ≤ 0.
    public static func timerIndex(minutes: Int) -> Int? {
        guard minutes > 0 else { return nil }
        let idx = Int((Double(minutes) / Double(timerStepMinutes)).rounded())
        return max(1, min(maxTimerMinutes / timerStepMinutes, idx))
    }

    /// Bytes to write to `FFB1`. Returns nil for commands the light has no encoding for.
    public static func encode(_ command: PoplightCommand) -> Data? {
        switch command {
        case .power(let on):
            return Data([0x01, 0x01, on ? 0x01 : 0x00])
        case .brightness(let value):
            return Data([0x01, 0x02, UInt8(clampBrightness(value))])
        case .colorTemperature(let t):
            return Data([0x01, 0x06, t.wireValue])
        case .sleepTimer(let seconds):
            guard let seconds, let idx = timerIndex(minutes: seconds / 60) else {
                // The official app has no explicit cancel; index 0 is rejected by the light ("Invalid Time").
                return nil
            }
            return Data([0x02, 0x03, 0x00, UInt8(idx)])
        case .queryStatus:
            return Data([0x01, 0x09, 0x00])
        }
    }

    /// The official app writes everything without response when the characteristic allows it,
    /// except the battery query, which it writes with response before listening on FFB2.
    public static func wantsResponse(_ command: PoplightCommand) -> Bool {
        if case .queryStatus = command { return true }
        return false
    }

    /// Battery bytes → percentage, as the official app does it (`mapBatteryPercentage`).
    public static func batteryPercent(raw: Int) -> Int {
        switch raw {
        case 80: 100
        case 60: 75
        case 40: 50
        case 20: 25
        default: max(0, min(100, raw))
        }
    }

    /// Parses a notification from `FFB2`. Only the battery reply `[1, 9, level]` is understood so far.
    public static func decodeStatus(_ data: Data) -> PoplightState? {
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { return nil }
        if bytes[0] == 0x01, bytes[1] == 0x09 {
            let raw = Int(bytes[2])
            return PoplightState(batteryPercent: batteryPercent(raw: raw), batteryRaw: raw)
        }
        return nil
    }
}
