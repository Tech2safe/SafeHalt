// Tests/SafeHaltKitTests/ShutdownDeciderTests.swift
import Foundation
import Testing
@testable import SafeHaltKit
@testable import SafeHaltCore

struct ShutdownDeciderTests {
    private let policy = ShutdownPolicy(onBatteryMinutes: 10, shutdownAlsoOnLowBattery: true)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func status(_ flags: String) -> UPSStatus { UPSStatus(raw: ["ups.status": flags]) }
    private func s(_ st: UPSStatus?, onBattery: Date? = nil, commLost: Date? = nil,
                   at now: Date, failsafe: Int = 0, cancel: Bool = false) -> DeciderState {
        DeciderState(status: st, onBatterySince: onBattery, commLostSince: commLost,
                     now: now, policy: policy, commLossFailsafeMinutes: failsafe, cancelRequested: cancel)
    }

    @Test func onlineIdleDoesNothing() {
        #expect(ShutdownDecider.decide(s(status("OL"), at: t0)).action == .none)
    }
    @Test func onBatteryStartsCountdown() {
        #expect(ShutdownDecider.decide(s(status("OB"), at: t0)).action == .startCountdown)
    }
    @Test func onBatteryStillCountingBeforeThreshold() {
        #expect(ShutdownDecider.decide(s(status("OB"), onBattery: t0, at: t0.addingTimeInterval(9*60))).action == .none)
    }
    @Test func onBatteryPastThresholdShutsDown() {
        #expect(ShutdownDecider.decide(s(status("OB"), onBattery: t0, at: t0.addingTimeInterval(10*60))).action == .shutdownNow)
    }
    @Test func onlineWhileCountingCancels() {
        #expect(ShutdownDecider.decide(s(status("OL"), onBattery: t0, at: t0.addingTimeInterval(60))).action == .cancelCountdown)
    }
    @Test func lowBatteryShutsDownImmediately() {
        #expect(ShutdownDecider.decide(s(status("OB LB"), onBattery: t0, at: t0)).action == .shutdownNow)
    }
    @Test func lowBatteryOverridesCancel() {
        #expect(ShutdownDecider.decide(s(status("OB LB"), onBattery: t0, at: t0, cancel: true)).action == .shutdownNow)
    }
    @Test func lowBatteryNoShutdownWhenPolicyDisabled() {
        let p = ShutdownPolicy(onBatteryMinutes: 10, shutdownAlsoOnLowBattery: false)
        let st = DeciderState(status: status("OB LB"), onBatterySince: t0, commLostSince: nil,
                              now: t0.addingTimeInterval(60), policy: p, commLossFailsafeMinutes: 0, cancelRequested: false)
        #expect(ShutdownDecider.decide(st).action == .none)
    }
    @Test func cancelSuppressesTimedShutdown() {
        #expect(ShutdownDecider.decide(s(status("OB"), onBattery: t0, at: t0.addingTimeInterval(20*60), cancel: true)).action == .none)
    }
    @Test func commLossWhileCountingContinuesToShutdown() {
        #expect(ShutdownDecider.decide(s(nil, onBattery: t0, at: t0.addingTimeInterval(10*60))).action == .shutdownNow)
    }
    @Test func commLossWhenIdleObservesWithinWindow() {
        // failsafe=5 分钟，才断 2 分钟 → 观察，不关机
        #expect(ShutdownDecider.decide(s(nil, commLost: t0, at: t0.addingTimeInterval(2*60), failsafe: 5)).action == .none)
    }
    @Test func commLossFailsafeStartsCountdownAfterWindow() {
        // 断 5 分钟到阈值 → 疑似断电，启动倒计时
        #expect(ShutdownDecider.decide(s(nil, commLost: t0, at: t0.addingTimeInterval(5*60), failsafe: 5)).action == .startCountdown)
    }
    @Test func commLossFailsafeDisabledNeverShutsDown() {
        // failsafe=0（关闭）→ 无论断多久都不关机
        #expect(ShutdownDecider.decide(s(nil, commLost: t0, at: t0.addingTimeInterval(60*60), failsafe: 0)).action == .none)
    }
    @Test func onlineLowBatteryIdleDoesNotShutDown() {
        // OL LB（深放电后充电中）空闲：市电在线，不关机
        #expect(ShutdownDecider.decide(s(status("OL LB"), at: t0)).action == .none)
    }
    @Test func onlineLowBatteryWhileCountingCancels() {
        #expect(ShutdownDecider.decide(s(status("OL LB"), onBattery: t0, at: t0.addingTimeInterval(60))).action == .cancelCountdown)
    }
    @Test func bareLowBatteryShutsDownConservatively() {
        // 裸 LB（无 OL 无 OB）：市电未确认在线，保守关机
        #expect(ShutdownDecider.decide(s(status("LB"), onBattery: t0, at: t0)).action == .shutdownNow)
    }
    @Test func staleCancelFlagDoesNotPreCancelIdle() {
        // 残留取消标志 + 空闲转电池：不被预取消，应起倒计时
        #expect(ShutdownDecider.decide(s(status("OB"), at: t0, cancel: true)).action == .startCountdown)
    }
    @Test func commLossContinuationBeforeThresholdIsNone() {
        #expect(ShutdownDecider.decide(s(nil, onBattery: t0, at: t0.addingTimeInterval(9*60))).action == .none)
    }
    @Test func contradictoryOLOBTreatedAsOnBattery() {
        // 矛盾状态 OL OB：有 OB 标志 → 保守当作转电池，起倒计时
        #expect(ShutdownDecider.decide(s(status("OL OB"), at: t0)).action == .startCountdown)
    }
}
