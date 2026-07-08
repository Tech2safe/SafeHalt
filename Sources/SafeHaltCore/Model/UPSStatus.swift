import Foundation

public struct UPSStatus: Equatable {
    public let raw: [String: String]
    public let statusFlags: [String]

    public init(raw: [String: String]) {
        self.raw = raw
        self.statusFlags = (raw["ups.status"] ?? "")
            .split(separator: " ").map(String.init)
    }

    public var isOnline: Bool { statusFlags.contains("OL") }
    public var isOnBattery: Bool { statusFlags.contains("OB") }
    public var isLowBattery: Bool { statusFlags.contains("LB") }

    public var batteryCharge: Int? { raw["battery.charge"].flatMap { Int($0) } }
    public var runtimeSeconds: Int? { raw["battery.runtime"].flatMap { Int($0) } }
    public var loadPercent: Int? { raw["ups.load"].flatMap { Int($0) } }
    public var model: String? { raw["device.model"]?.trimmingCharacters(in: .whitespaces) }
    public var manufacturer: String? { raw["device.mfr"]?.trimmingCharacters(in: .whitespaces) }
    public var inputVoltage: Double? { raw["input.voltage"].flatMap { Double($0) } }
    public var outputVoltage: Double? { raw["output.voltage"].flatMap { Double($0) } }
}
