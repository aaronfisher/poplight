import Foundation

public extension Data {
    /// "01 a2 ff" style hex, lowercase, space separated.
    nonisolated var hexString: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Compact hex with no separators: "01a2ff".
    nonisolated var compactHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Parses "01 a2 ff", "01a2ff", "0x01,0xA2", "01:a2:ff" … Returns nil on odd length or bad chars.
    nonisolated init?(hexLoose text: String) {
        var cleaned = text.lowercased()
        for token in ["0x", " ", ",", ":", "-", "\n", "\t", "_"] {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    /// Printable ASCII rendering, with "." for non-printables. Handy for spotting string payloads.
    nonisolated var asciiPreview: String {
        String(map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }

    nonisolated var isMostlyPrintable: Bool {
        guard !isEmpty else { return false }
        let printable = filter { (32...126).contains($0) || $0 == 0 }.count
        return printable * 10 >= count * 9
    }
}
