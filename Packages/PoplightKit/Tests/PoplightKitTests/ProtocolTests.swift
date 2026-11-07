import Foundation
import Testing
@testable import PoplightKit

@Suite struct ProtocolTests {
    @Test func power() {
        #expect(PoplightProtocol.encode(.power(true)) == Data([1, 1, 1]))
        #expect(PoplightProtocol.encode(.power(false)) == Data([1, 1, 0]))
    }

    @Test func brightnessClamps() {
        #expect(PoplightProtocol.encode(.brightness(50)) == Data([1, 2, 50]))
        #expect(PoplightProtocol.encode(.brightness(100)) == Data([1, 2, 99]))
        #expect(PoplightProtocol.encode(.brightness(0)) == Data([1, 2, 1]))
        #expect(PoplightProtocol.wantsResponse(.brightness(10)) == false)
        #expect(PoplightProtocol.wantsResponse(.power(true)) == false)
        #expect(PoplightProtocol.wantsResponse(.queryStatus) == true)
    }

    @Test func warmth() {
        #expect(PoplightProtocol.encode(.colorTemperature(.cool)) == Data([1, 6, 0]))
        #expect(PoplightProtocol.encode(.colorTemperature(.neutral)) == Data([1, 6, 1]))
        #expect(PoplightProtocol.encode(.colorTemperature(.warm)) == Data([1, 6, 2]))
        #expect(PoplightColorTemperature(wireValue: 2) == .warm)
        #expect(PoplightColorTemperature(wireValue: 7) == nil)
    }

    @Test func timer() {
        #expect(PoplightProtocol.encode(.sleepTimer(seconds: 30 * 60)) == Data([2, 3, 0, 2]))
        #expect(PoplightProtocol.encode(.sleepTimer(seconds: 60 * 60)) == Data([2, 3, 0, 4]))
        #expect(PoplightProtocol.encode(.sleepTimer(seconds: 20 * 60)) == Data([2, 3, 0, 1]))
        #expect(PoplightProtocol.encode(.sleepTimer(seconds: 2000 * 60)) == Data([2, 3, 0, 48]))
        #expect(PoplightProtocol.encode(.sleepTimer(seconds: nil)) == nil)
        #expect(PoplightProtocol.encode(.sleepTimer(seconds: 0)) == nil)
    }

    @Test func battery() {
        #expect(PoplightProtocol.encode(.queryStatus) == Data([1, 9, 0]))
        #expect(PoplightProtocol.decodeStatus(Data([1, 9, 80])) == PoplightState(batteryPercent: 100, batteryRaw: 80))
        #expect(PoplightProtocol.decodeStatus(Data([1, 9, 60]))?.batteryPercent == 75)
        #expect(PoplightProtocol.decodeStatus(Data([1, 9, 40]))?.batteryPercent == 50)
        #expect(PoplightProtocol.decodeStatus(Data([1, 9, 20]))?.batteryPercent == 25)
        #expect(PoplightProtocol.decodeStatus(Data([1, 9, 73]))?.batteryPercent == 73)
        #expect(PoplightProtocol.decodeStatus(Data([1, 2, 50])) == nil)
        #expect(PoplightProtocol.decodeStatus(Data([1])) == nil)
    }

    @Test func stateApply() {
        var state = PoplightState()
        state.apply(.brightness(100))
        state.apply(.power(true))
        state.apply(.colorTemperature(.cool))
        #expect(state.brightness == 99)
        #expect(state.isOn == true)
        #expect(state.colorTemperature == .cool)
    }
}
