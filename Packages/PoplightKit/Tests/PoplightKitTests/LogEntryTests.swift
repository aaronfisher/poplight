import Foundation
import Testing
@testable import PoplightKit

@Suite struct LogEntryTests {
    @Test func jsonExportUsesHex() throws {
        let entry = LogEntry(kind: .write, characteristic: "FFF1", data: Data([0xAA, 0x01]), message: "hello")
        let json = LogExport.json([entry])
        #expect(json.contains("\"hex\" : \"aa 01\""))
        #expect(json.contains("\"kind\" : \"write\""))
        #expect(json.contains("\"characteristic\" : \"FFF1\""))
    }

    @Test func textExport() {
        let a = LogEntry(kind: .info, message: "first")
        let b = LogEntry(kind: .notify, characteristic: "FFF2", data: Data([1, 2]))
        let text = LogExport.text([a, b])
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("INFO"))
        #expect(lines[1].contains("[2] 01 02"))
    }
}
