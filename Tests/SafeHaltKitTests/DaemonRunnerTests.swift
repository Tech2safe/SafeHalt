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
        let r = DaemonRunner(config: cfg(), transportFactory: statusFactory("OL"), actions: a)
        await r.tick(now: t0)
        #expect(a.shutdownReasons.isEmpty)
        #expect(await r.onBatterySinceForTest == nil)
    }

    @Test func onBatteryBeginsEpisodeAndWarns() async {
        let a = MockSystemActions()
        let r = DaemonRunner(config: cfg(), transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)
        #expect(a.episodesBegun == 1)
        #expect(a.warningsShown == 1)          // 转电池即弹可取消倒计时
        #expect(await r.onBatterySinceForTest == t0)
        #expect(a.shutdownReasons.isEmpty)
    }

    @Test func onBatteryPastThresholdShutsDown() async {
        let a = MockSystemActions()
        let r = DaemonRunner(config: cfg(), transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)
        await r.tick(now: t0.addingTimeInterval(10*60))
        #expect(a.shutdownReasons.count == 1)
    }

    /// 回归（漏洞三）：关机 tick 只调 shutdown、不调通知——关机绝不被可能卡住的通知阻塞。
    @Test func shutdownTickDoesNotNotify() async {
        let a = MockSystemActions()
        let r = DaemonRunner(config: cfg(), transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)                       // 起倒计时（弹 warning，不 notify）
        let notifsBefore = a.notifications.count
        await r.tick(now: t0.addingTimeInterval(10*60))   // 关机 tick
        #expect(a.shutdownReasons.count == 1)
        #expect(a.notifications.count == notifsBefore)     // 关机 tick 未新增通知
    }

    @Test func recoveryEndsEpisode() async {
        let a = MockSystemActions()
        let r = DaemonRunner(config: cfg(), transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)
        await r.setTransportFactoryForTest(statusFactory("OL"))
        await r.tick(now: t0.addingTimeInterval(60))
        #expect(a.episodesEnded == 1)
        #expect(await r.onBatterySinceForTest == nil)
    }

    @Test func cancelSuppressesShutdown() async {
        let a = MockSystemActions()
        let r = DaemonRunner(config: cfg(), transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)
        a.cancelRequested = true
        await r.tick(now: t0.addingTimeInterval(20*60))
        #expect(a.shutdownReasons.isEmpty)
    }

    @Test func commLossFailsafeTriggersAfterWindow() async {
        let a = MockSystemActions()
        let r = DaemonRunner(config: cfg(failsafe: 5), transportFactory: unreachable, actions: a)
        await r.tick(now: t0)                          // 首次掉线：记 commLostSince，尚未到阈值
        #expect(a.shutdownReasons.isEmpty)
        await r.tick(now: t0.addingTimeInterval(5*60)) // 到阈值：failsafe 起倒计时
        #expect(await r.onBatterySinceForTest == t0.addingTimeInterval(5*60))
        await r.tick(now: t0.addingTimeInterval(15*60))// 倒计时到点（续算，仍掉线）→ 关机
        #expect(a.shutdownReasons.count == 1)
    }

    @Test func commLossDisabledNeverShutsDown() async {
        let a = MockSystemActions()
        let r = DaemonRunner(config: cfg(failsafe: 0), transportFactory: unreachable, actions: a)
        await r.tick(now: t0)
        await r.tick(now: t0.addingTimeInterval(60*60))
        #expect(a.shutdownReasons.isEmpty)
    }

    /// 回归（安全铁律）：转电池倒计时到点的同一 tick 恰好通信中断时，
    /// 关机必须先于本 tick 的“通信中断”通知——否则卡住的通知会拖死关机。
    @Test func shutdownPrecedesCommLossNotifyWhenBothOccur() async {
        let a = MockSystemActions()
        let r = DaemonRunner(config: cfg(failsafe: 5), transportFactory: statusFactory("OB"), actions: a)
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
        let r = DaemonRunner(config: cfg(), transportFactory: statusFactory("OB"), actions: a)
        await r.tick(now: t0)
        #expect(a.episodesBegun == 1)                     // 起了新 episode（真实现里 beginEpisode 会清标志）
        #expect(await r.onBatterySinceForTest == t0)
    }
}
