import Foundation

/// One line in the Lab log. Pure data so it can be exported and used from any context.
nonisolated public struct LogEntry: Identifiable, Sendable, Encodable {
    public enum Kind: String, Sendable, Encodable, CaseIterable {
        case info, error, connect, disconnect, discover
        case read, readRequest, write, writeResponse, notify, subscribe
    }

    public let id: UUID
    public let time: Date
    public let kind: Kind
    public let service: String?
    public let characteristic: String?
    public let data: Data?
    public let message: String?

    public init(kind: Kind, service: String? = nil, characteristic: String? = nil, data: Data? = nil, message: String? = nil) {
        self.id = UUID()
        self.time = Date()
        self.kind = kind
        self.service = service
        self.characteristic = characteristic
        self.data = data
        self.message = message
    }

    enum CodingKeys: String, CodingKey { case time, kind, service, characteristic, hex, ascii, message }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time.timeIntervalSince1970, forKey: .time)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(service, forKey: .service)
        try c.encodeIfPresent(characteristic, forKey: .characteristic)
        try c.encodeIfPresent(data?.hexString, forKey: .hex)
        try c.encodeIfPresent(data?.asciiPreview, forKey: .ascii)
        try c.encodeIfPresent(message, forKey: .message)
    }

    /// Single-line text rendering, relative to `start`.
    public func line(relativeTo start: Date) -> String {
        let t = String(format: "%+9.3fs", time.timeIntervalSince(start))
        var parts = [t, kind.rawValue.uppercased().padding(toLength: 13, withPad: " ", startingAt: 0)]
        if let characteristic { parts.append(characteristic) }
        if let data { parts.append("[\(data.count)] \(data.hexString)") }
        if let message { parts.append(message) }
        return parts.joined(separator: "  ")
    }
}

nonisolated public enum LogExport {
    public static func json(_ entries: [LogEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func text(_ entries: [LogEntry]) -> String {
        guard let start = entries.first?.time else { return "" }
        return entries.map { $0.line(relativeTo: start) }.joined(separator: "\n")
    }
}
