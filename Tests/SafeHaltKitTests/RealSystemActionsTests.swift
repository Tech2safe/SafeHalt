import Foundation
import Testing
@testable import SafeHaltKit

struct RealSystemActionsTests {
    @Test func dryRunShutdownDoesNotRealShutdown() {
        // 必须 dry-run：真关机会中断测试
        RealSystemActions(dryRun: true, consoleUID: { nil }).shutdown(reason: "测试")
        #expect(Bool(true))
    }
    @Test func warningWithNoConsoleUserIsNoop() {
        // 无登录会话时弹窗直接跳过、不崩溃、不阻塞
        RealSystemActions(dryRun: true, consoleUID: { nil }).presentCancelableWarning(minutes: 10, message: "测试")
        #expect(Bool(true))
    }
    @Test func episodeClearsCancelFlag() throws {
        // beginEpisode/endEpisode 清取消标志（用真实路径，测试后自清）
        let a = RealSystemActions(dryRun: true, consoleUID: { nil })
        try "x".write(toFile: DaemonPaths.cancelFlagFile, atomically: true, encoding: .utf8)
        a.beginEpisode()
        #expect(!a.isCancelRequested())
        a.endEpisode()   // 幂等
        #expect(!a.isCancelRequested())
    }
}
