import Foundation

// MARK: - Poplight protocol (to be filled in from the Phase 2 capture)
//
// Everything in this file is pure data + byte codecs with no CoreBluetooth dependency,
// so it can be ported 1:1 to TypeScript (Homebridge) or Python (Home Assistant).
// See PROTOCOL.md at the repo root for the human-readable description.

nonisolated public enum PoplightColorTemperature: String, CaseIterable, Sendable, Codable {
    case warm, neutral, cool
}

nonisolated public struct PoplightState: Equatable, Sendable, Codable {
    public var isOn: Bool?
    /// 0…100
    public var brightness: Int?
    public var colorTemperature: PoplightColorTemperature?
    /// 0…100
    public var batteryPercent: Int?
    /// Remaining sleep-timer seconds, nil when no timer is set.
    public var sleepTimerRemaining: Int?

    public init(isOn: Bool? = nil, brightness: Int? = nil, colorTemperature: PoplightColorTemperature? = nil, batteryPercent: Int? = nil, sleepTimerRemaining: Int? = nil) {
        self.isOn = isOn
        self.brightness = brightness
        self.colorTemperature = colorTemperature
        self.batteryPercent = batteryPercent
        self.sleepTimerRemaining = sleepTimerRemaining
    }
}

nonisolated public enum PoplightCommand: Equatable, Sendable {
    case power(Bool)
    case brightness(Int)
    case colorTemperature(PoplightColorTemperature)
    case sleepTimer(seconds: Int?)
    case queryStatus
}

/// Byte-level codec. UUIDs and encodings are placeholders until the capture is decoded.
nonisolated public enum PoplightProtocol {
    /// Advertised name prefix used to recognise a Poplight while scanning. Refine after Phase 2.
    public static let advertisedNameHint = "POP_Light"

    /// GATT UUIDs, as strings so this file stays free of CoreBluetooth.
    /// Observed 2026-09-10 in the Lab; roles are the working assumption until the capture confirms them.
    public static let serviceUUID = "FFB0"
    public static let commandCharacteristicUUID = "FFB1"   // "Characteristic 3", write
    public static let statusCharacteristicUUID = "FFB2"    // "Characteristic 4", notify

    /// Flip to true once `encode`/`decodeStatus` are implemented from the capture.
    public static let isKnown = false

    public static func encode(_ command: PoplightCommand) -> Data? {
        // TODO(Phase 2): fill in from the capture.
        nil
    }

    public static func decodeStatus(_ data: Data) -> PoplightState? {
        // TODO(Phase 2): fill in from the capture.
        nil
    }
}
