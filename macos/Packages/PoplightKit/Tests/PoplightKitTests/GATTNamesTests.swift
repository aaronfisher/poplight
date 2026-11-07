import CoreBluetooth
import Foundation
import Testing
@testable import PoplightKit

@Suite struct GATTNamesTests {
    @Test func knownNames() {
        #expect(GATTNames.serviceName(CBUUID(string: "180F")) == "Battery")
        #expect(GATTNames.characteristicName(CBUUID(string: "2A19")) == "Battery Level")
        #expect(GATTNames.serviceName(CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")) == "Nordic UART Service")
        #expect(GATTNames.serviceName(CBUUID(string: "1234")) == nil)
    }

    @Test func decoders() {
        #expect(GATTNames.decode(CBUUID(string: "2A19"), Data([87])) == "87%")
        #expect(GATTNames.decode(CBUUID(string: "2A29"), Data("Acme".utf8)) == "\"Acme\"")
        #expect(GATTNames.decode(CBUUID(string: "2902"), Data([1, 0])) == "notifications on")
        #expect(GATTNames.decode(CBUUID(string: "FFF1"), Data([0x00, 0x80, 0xFF])) == nil)
    }

    @Test func properties() {
        let props: CBCharacteristicProperties = [.read, .write, .notify]
        #expect(GATTNames.describe(properties: props) == ["read", "write", "notify"])
    }
}
