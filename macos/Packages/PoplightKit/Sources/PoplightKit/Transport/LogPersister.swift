import Foundation

/// Appends log entries as JSON lines to
/// ~/Library/Application Support/Poplight/logs/<date>-<name>.jsonl so a Lab session
/// survives quitting the app.
public final class LogPersister {
    public static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Poplight/logs", isDirectory: true)
    }()

    public let url: URL
    private var handle: FileHandle?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public init(name: String, id: UUID) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let safe = name.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
        url = Self.directory.appendingPathComponent("\(formatter.string(from: Date()))-\(safe)-\(id.uuidString.prefix(8)).jsonl")
    }

    public func append(_ entry: LogEntry) {
        if handle == nil {
            do {
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try FileHandle(forWritingTo: url)
                try handle?.seekToEnd()
            } catch {
                return
            }
        }
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)
        try? handle?.write(contentsOf: data)
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }
}
