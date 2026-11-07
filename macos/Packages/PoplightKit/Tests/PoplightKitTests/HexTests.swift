import Foundation
import Testing
@testable import PoplightKit

@Suite struct HexTests {
    @Test func roundTrip() {
        let data = Data([0x01, 0xA2, 0xFF, 0x00])
        #expect(data.hexString == "01 a2 ff 00")
        #expect(data.compactHex == "01a2ff00")
        #expect(Data(hexLoose: data.hexString) == data)
        #expect(Data(hexLoose: data.compactHex) == data)
    }

    @Test func looseParsing() {
        #expect(Data(hexLoose: "0x01, 0xA2:ff-00") == Data([0x01, 0xA2, 0xFF, 0x00]))
        #expect(Data(hexLoose: "") == Data())
        #expect(Data(hexLoose: "abc") == nil)
        #expect(Data(hexLoose: "zz") == nil)
    }

    @Test func asciiPreview() {
        #expect(Data("Hi\u{01}!".utf8).asciiPreview == "Hi.!")
        #expect(Data("Poplight".utf8).isMostlyPrintable)
        #expect(!Data([0x00, 0x01, 0x02, 0x80]).isMostlyPrintable)
    }
}
