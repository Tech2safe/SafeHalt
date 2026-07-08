import Testing
@testable import SafeHaltCore

struct UPSStatusTests {
    private let sample: [String: String] = [
        "ups.status": "OL",
        "battery.charge": "100",
        "battery.runtime": "4140",
        "ups.load": "11",
        "device.model": "Smart-UPS 1000",
        "device.mfr": "American Power Conversion ",
        "input.voltage": "239.0",
        "output.voltage": "230.0"
    ]

    @Test func parsesNumbers() {
        let s = UPSStatus(raw: sample)
        #expect(s.batteryCharge == 100)
        #expect(s.runtimeSeconds == 4140)
        #expect(s.loadPercent == 11)
        #expect(s.inputVoltage == 239.0)
        #expect(s.outputVoltage == 230.0)
    }

    @Test func statusFlagsOnline() {
        let s = UPSStatus(raw: sample)
        #expect(s.isOnline)
        #expect(!s.isOnBattery)
        #expect(!s.isLowBattery)
    }

    @Test func statusFlagsOnBatteryLow() {
        var raw = sample; raw["ups.status"] = "OB LB"
        let s = UPSStatus(raw: raw)
        #expect(s.isOnBattery)
        #expect(s.isLowBattery)
        #expect(!s.isOnline)
        #expect(s.statusFlags == ["OB", "LB"])
    }

    @Test func trimsManufacturer() {
        let s = UPSStatus(raw: sample)
        #expect(s.manufacturer == "American Power Conversion")
    }
}
