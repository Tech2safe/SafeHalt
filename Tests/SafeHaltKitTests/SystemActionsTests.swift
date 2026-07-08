import Foundation
import Testing
@testable import SafeHaltKit

/// 记录型假动作：单测 DaemonRunner 用。
final class MockSystemActions: SystemActions, @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelRequested = false
    /// 读写均加锁：避免测试里跨 actor 边界写后读出现竞态（Task 3 复盘发现的非对称锁问题）。
    var cancelRequested: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelRequested }
        set { lock.lock(); _cancelRequested = newValue; lock.unlock() }
    }
    private(set) var shutdownReasons: [String] = []
    private(set) var notifications: [String] = []
    private(set) var warningsShown = 0
    private(set) var episodesBegun = 0
    private(set) var episodesEnded = 0
    private(set) var callOrder: [String] = []

    func shutdown(reason: String) { lock.lock(); shutdownReasons.append(reason); callOrder.append("shutdown"); lock.unlock() }
    func notify(_ message: String) { lock.lock(); notifications.append(message); callOrder.append("notify"); lock.unlock() }
    func presentCancelableWarning(minutes: Int, message: String) { lock.lock(); warningsShown += 1; callOrder.append("warning"); lock.unlock() }
    // 注意：cancelRequested 计算属性内部已加锁，这里不能再抢同一把 NSLock（会自死锁）。
    func isCancelRequested() -> Bool { cancelRequested }
    func beginEpisode() { lock.lock(); episodesBegun += 1; callOrder.append("beginEpisode"); lock.unlock() }
    func endEpisode() { lock.lock(); episodesEnded += 1; callOrder.append("endEpisode"); lock.unlock() }
}

struct SystemActionsTests {
    @Test func mockRecordsCalls() {
        let a = MockSystemActions()
        a.shutdown(reason: "x"); a.notify("hi"); a.presentCancelableWarning(minutes: 10, message: "x")
        a.beginEpisode(); a.endEpisode(); a.cancelRequested = true
        #expect(a.shutdownReasons == ["x"])
        #expect(a.notifications == ["hi"])
        #expect(a.warningsShown == 1)
        #expect(a.episodesBegun == 1 && a.episodesEnded == 1)
        #expect(a.isCancelRequested())
    }
}
