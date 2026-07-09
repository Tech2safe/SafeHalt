// Tests/SafeHaltKitTests/DaemonRunnerTests.swift
import Foundation
import Testing
@testable import SafeHaltKit
@testable import SafeHaltCore

/// 本测试目标内的最小假传输（与 SafeHaltCoreTests 里的同名类不同模块，互不冲突）。
final class MockTransport: NUTTransport {
    var responses: [String: [String]] = [:]
    func request(_ command: String) async throws -> [String] {
        for (prefix, reply) in responses where command.hasPrefix(prefix) { return reply }
        return []
    }
}
/// 永远抛错的假传输：模拟连不上（status 折叠为 nil）。
final class UnreachableTransport: NUTTransport {
    struct Boom: Error {}
    func request(_ command: String) async throws -> [String] { throw Boom() }
}

/// 测试用：@Sendable persist 闭包里安全存放落盘配置。
final class ConfigBox: @unchecked Sendable { var value: DaemonConfig? }

struct DaemonRunnerTests {
    private func cfg(failsafe: Int = 0) -> DaemonConfig {
        DaemonConfig(host: "h", port: 3493, ups: "ups", username: "u", password: "p",
                     onBatteryMinutes: 10, shutdownAlsoOnLowBattery: true,
                     commLossFailsafeMinutes: failsafe, pollSeconds: 5)
    }
    private func statusFactory(_ flags: String) -> @Sendable (String, Int) -> NUTTransport {
        { _, _ in
            let t = MockTransport()
            t.responses["LIST VAR ups"] = ["BEGIN LIST VAR ups", "VAR ups ups.status \"\(flags)\"", "END LIST VAR ups"]
            return t
        }
    }
    private let unreachable: @Sendable (String, Int) -> NUTTransport = { _, _ in UnreachableTransport() }
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    @Test func onlineDoesNothing() async {
        let a = MockSystemActions()
        let r = DaemonRunner(settings: cfg(), transportFactory: statusFactory("OL"), actions: a)
        await r.tick(now: t0)
        #expect(a.shutdownReasons.isEmpty)
        #expect(await r.onBatterySinceForTest == nil)
    }

    @Test func onBatteryBeginsEpisodeAndWarns() async {
        let a = MockSystemActions()
        let r = DaemonRunner(settings: cfg(), transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)
        #expect(a.episodesBegun == 1)
        #expect(a.warningsShown == 1)          // 转电池即弹可取消倒计时
        #expect(await r.onBatterySinceForTest == t0)
        #expect(a.shutdownReasons.isEmpty)
    }

    @Test func onBatteryPastThresholdShutsDown() async {
        let a = MockSystemActions()
        let r = DaemonRunner(settings: cfg(), transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)
        await r.tick(now: t0.addingTimeInterval(10*60))
        #expect(a.shutdownReasons.count == 1)
    }

    /// 回归（漏洞三）：关机 tick 只调 shutdown、不调通知——关机绝不被可能卡住的通知阻塞。
    @Test func shutdownTickDoesNotNotify() async {
        let a = MockSystemActions()
        let r = DaemonRunner(settings: cfg(), transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)                       // 起倒计时（弹 warning，不 notify）
        let notifsBefore = a.notifications.count
        await r.tick(now: t0.addingTimeInterval(10*60))   // 关机 tick
        #expect(a.shutdownReasons.count == 1)
        #expect(a.notifications.count == notifsBefore)     // 关机 tick 未新增通知
    }

    @Test func recoveryEndsEpisode() async {
        let a = MockSystemActions()
        let r = DaemonRunner(settings: cfg(), transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)
        await r.setTransportFactoryForTest(statusFactory("OL"))
        await r.tick(now: t0.addingTimeInterval(60))
        #expect(a.episodesEnded == 1)
        #expect(await r.onBatterySinceForTest == nil)
    }

    @Test func cancelSuppressesShutdown() async {
        let a = MockSystemActions()
        let r = DaemonRunner(settings: cfg(), transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)
        a.cancelRequested = true
        await r.tick(now: t0.addingTimeInterval(20*60))
        #expect(a.shutdownReasons.isEmpty)
    }

    /// 用户取消后：停显倒计时 + 报告 episodeCancelled + 记事件/通知一次；超阈值仍不关机；市电恢复复位。
    @Test func userCancelReportsCancelledStateAndFeedback() async {
        let a = MockSystemActions()
        let r = DaemonRunner(settings: cfg(), transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)                                   // OB → 起倒计时
        var st = await r.currentStatus(now: t0)
        #expect(st.countdownActive == true)
        #expect(st.episodeCancelled == false)

        a.cancelRequested = true                               // 用户取消
        await r.tick(now: t0.addingTimeInterval(60))
        st = await r.currentStatus(now: t0.addingTimeInterval(60))
        #expect(st.countdownActive == false)                   // 停显倒计时
        #expect(st.episodeCancelled == true)                   // 报告已取消
        #expect(a.notifications.contains { $0.contains("已取消本次关机") })   // 有明确反馈
        let cancelEvents = await r.recentEvents(limit: 100).filter { $0.kind == "cancel" }
        #expect(cancelEvents.count == 1)                       // 事件仅记一次

        await r.tick(now: t0.addingTimeInterval(20*60))        // 超阈值：仍不关机
        #expect(a.shutdownReasons.isEmpty)
        let stillOneCancel = await r.recentEvents(limit: 100).filter { $0.kind == "cancel" }
        #expect(stillOneCancel.count == 1)                    // 不重复记事件

        await r.setTransportFactoryForTest(statusFactory("OL"))  // 市电恢复
        a.cancelRequested = false
        await r.tick(now: t0.addingTimeInterval(21*60))
        st = await r.currentStatus(now: t0.addingTimeInterval(21*60))
        #expect(st.episodeCancelled == false)                 // 复位
    }

    @Test func commLossFailsafeTriggersAfterWindow() async {
        let a = MockSystemActions()
        let r = DaemonRunner(settings: cfg(failsafe: 5), transportFactory: unreachable, actions: a)
        await r.tick(now: t0)                          // 首次掉线：记 commLostSince，尚未到阈值
        #expect(a.shutdownReasons.isEmpty)
        await r.tick(now: t0.addingTimeInterval(5*60)) // 到阈值：failsafe 起倒计时
        #expect(await r.onBatterySinceForTest == t0.addingTimeInterval(5*60))
        await r.tick(now: t0.addingTimeInterval(15*60))// 倒计时到点（续算，仍掉线）→ 关机
        #expect(a.shutdownReasons.count == 1)
    }

    @Test func commLossDisabledNeverShutsDown() async {
        let a = MockSystemActions()
        let r = DaemonRunner(settings: cfg(failsafe: 0), transportFactory: unreachable, actions: a)
        await r.tick(now: t0)
        await r.tick(now: t0.addingTimeInterval(60*60))
        #expect(a.shutdownReasons.isEmpty)
    }

    /// 回归（安全铁律）：转电池倒计时到点的同一 tick 恰好通信中断时，
    /// 关机必须先于本 tick 的“通信中断”通知——否则卡住的通知会拖死关机。
    @Test func shutdownPrecedesCommLossNotifyWhenBothOccur() async {
        let a = MockSystemActions()
        let r = DaemonRunner(settings: cfg(failsafe: 5), transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)                              // 转电池，起倒计时
        await r.setTransportFactoryForTest(unreachable)    // 通信中断
        await r.tick(now: t0.addingTimeInterval(10*60))    // 到点 + 通信中断同 tick
        #expect(a.shutdownReasons.count == 1)              // 续算仍关机
        let s = a.callOrder.lastIndex(of: "shutdown")
        let n = a.callOrder.lastIndex(of: "notify")
        #expect(s != nil && n != nil && s! < n!)           // 关机在通信通知之前
    }

    /// 回归（Critical）：残留取消标志不得预取消下一轮 episode——新转电池必须起倒计时。
    @Test func staleCancelFlagDoesNotSuppressNextEpisode() async {
        let a = MockSystemActions()
        a.cancelRequested = true                          // 上一轮遗留的残留标志
        let r = DaemonRunner(settings: cfg(), transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)
        #expect(a.episodesBegun == 1)                     // 起了新 episode（真实现里 beginEpisode 会清标志）
        #expect(await r.onBatterySinceForTest == t0)
    }

    @Test func dumbWhenUnconfiguredDoesNotShutdown() async {
        let a = MockSystemActions()
        let r = DaemonRunner(settings: nil, transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)
        #expect(a.shutdownReasons.isEmpty)
        let st = await r.currentStatus(now: t0)
        #expect(st.configured == false)
        #expect(st.target == nil)
    }

    @Test func pausedWhenDisabledDoesNotShutdown() async {
        let a = MockSystemActions()
        let disabled = DaemonConfig(host: "h", port: 3493, ups: "ups",
                                    onBatteryMinutes: 10, shutdownAlsoOnLowBattery: true, enabled: false)
        let r = DaemonRunner(settings: disabled, transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)
        #expect(a.shutdownReasons.isEmpty)
        let st = await r.currentStatus(now: t0)
        #expect(st.configured == true)
        #expect(st.enabled == false)
    }

    /// 回归（Important）：暂停时不得冻结在途倒计时——恢复后若仍在电池上，
    /// 必须重新起倒计时并弹可取消告警，不能因续算旧起点而直接跳到关机。
    @Test func pauseThenResumeRestartsCountdownInsteadOfImmediateShutdown() async {
        let a = MockSystemActions()
        let cfg = DaemonConfig(host: "h", port: 3493, ups: "ups",
                               onBatteryMinutes: 10, shutdownAlsoOnLowBattery: true)
        let r = DaemonRunner(settings: cfg, transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)                                   // OB → 起倒计时 + 弹告警
        #expect(a.warningsShown == 1)
        #expect(await r.onBatterySinceForTest == t0)
        // 暂停（同目标，enabled=false）
        let paused = DaemonConfig(host: "h", port: 3493, ups: "ups",
                                  onBatteryMinutes: 10, shutdownAlsoOnLowBattery: true, enabled: false)
        await r.applySettings(paused)
        #expect(await r.onBatterySinceForTest == nil)          // 暂停放弃在途倒计时
        await r.tick(now: t0.addingTimeInterval(30*60))        // 暂停中：什么都不做
        #expect(a.shutdownReasons.isEmpty)
        // 恢复（仍 OB，且已远超原阈值）
        let resumed = DaemonConfig(host: "h", port: 3493, ups: "ups",
                                   onBatteryMinutes: 10, shutdownAlsoOnLowBattery: true, enabled: true)
        await r.applySettings(resumed)
        await r.tick(now: t0.addingTimeInterval(31*60))        // 恢复后首个 tick
        #expect(a.shutdownReasons.isEmpty)                     // 不立即关机
        #expect(a.warningsShown == 2)                          // 弹了新的可取消告警
        #expect(await r.onBatterySinceForTest == t0.addingTimeInterval(31*60))  // 新倒计时起点
    }

    @Test func applySettingsPersistsAndArms() async {
        let a = MockSystemActions()
        let box = ConfigBox()
        let r = DaemonRunner(settings: nil, transportFactory: statusFactory("OL"),
                             actions: a, persist: { box.value = $0 })
        let newCfg = DaemonConfig(host: "h2", port: 3493, ups: "ups",
                                  onBatteryMinutes: 10, shutdownAlsoOnLowBattery: true)
        await r.applySettings(newCfg)
        #expect(box.value == newCfg)
        let st = await r.currentStatus(now: t0)
        #expect(st.configured == true)
        #expect(st.target == EngineTarget(host: "h2", port: 3493, ups: "ups"))
    }
}
