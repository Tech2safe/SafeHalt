import Foundation
import Testing
@testable import SafeHaltKit
@testable import SafeHaltCore

/// 「最低电量」：UPS 自带 LB 兜底之外的可选门槛（0 = 仅 UPS 默认）。
struct MinChargeTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func st(_ flags: String, charge: Int?) -> UPSStatus {
        var raw = ["ups.status": flags]
        if let charge { raw["battery.charge"] = String(charge) }
        return UPSStatus(raw: raw)
    }
    private func decide(_ status: UPSStatus?, min: Int, counting: Bool = true, cancel: Bool = false) -> ShutdownDecision {
        ShutdownDecider.decide(DeciderState(
            status: status, onBatterySince: counting ? t0 : nil, now: t0.addingTimeInterval(60),
            policy: ShutdownPolicy(onBatteryMinutes: 10, shutdownAlsoOnLowBattery: true, minChargePercent: min),
            cancelRequested: cancel))
    }

    @Test func atOrBelowThresholdShutsDownDuringCountdown() {
        #expect(decide(st("OB", charge: 40), min: 40).action == .shutdownNow)
        #expect(decide(st("OB", charge: 35), min: 40).action == .shutdownNow)
        #expect(decide(st("OB", charge: 35), min: 40).reason.contains("40%"))
    }
    @Test func aboveThresholdKeepsCounting() {
        #expect(decide(st("OB", charge: 41), min: 40).action == .none)
    }
    @Test func zeroMeansOnlyUPSDefault() {
        #expect(decide(st("OB", charge: 15), min: 0).action == .none)
    }
    @Test func firstTickStillStartsCountdownWithWarning() {
        #expect(decide(st("OB", charge: 30), min: 40, counting: false).action == .startCountdown)
    }
    @Test func respectsUserCancel() {
        #expect(decide(st("OB", charge: 30), min: 40, cancel: true).action == .none)
    }
    @Test func neverWhileMainsOnline() {
        #expect(decide(st("OL", charge: 10), min: 60, counting: false).action == .none)
        #expect(decide(st("OL CHRG", charge: 10), min: 60, counting: false).action == .none)
    }
    @Test func unknownChargeIgnored() {
        #expect(decide(st("OB", charge: nil), min: 40).action == .none)
        #expect(decide(nil, min: 40).action == .none)
    }

    // 配置：缺省 0（旧 config 兼容）；只接受 0 或 5…95
    private func json(_ extra: String) -> Data {
        Data(#"{"host":"h","port":3493,"ups":"ups","onBatteryMinutes":10,"shutdownAlsoOnLowBattery":true\#(extra)}"#.utf8)
    }
    @Test func configDefaultsToZeroAndRoundTrips() throws {
        #expect(try DaemonConfig.load(data: json("")).minChargePercent == 0)
        let c = try DaemonConfig.load(data: json(#","minChargePercent":40"#))
        #expect(c.minChargePercent == 40 && c.policy.minChargePercent == 40)
        #expect(try DaemonConfig.load(data: c.encoded()).minChargePercent == 40)
    }
    @Test func configRejectsOutOfRange() {
        #expect(throws: DaemonConfigError.self) { try DaemonConfig.load(data: json(#","minChargePercent":3"#)) }
        #expect(throws: DaemonConfigError.self) { try DaemonConfig.load(data: json(#","minChargePercent":100"#)) }
    }
    @Test func statusEchoesMinCharge() async throws {
        let c = try DaemonConfig.load(data: json(#","minChargePercent":60"#))
        let r = DaemonRunner(settings: c, transportFactory: { _, _ in UnreachableTransport() }, actions: MockSystemActions())
        #expect(await r.currentStatus(now: Date()).policy?.minChargePercent == 60)
    }
}
