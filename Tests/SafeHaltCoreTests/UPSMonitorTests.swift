import Testing
@testable import SafeHaltCore

/// 永远抛错的假传输，模拟断网/服务端拒绝。
final class FailingTransport: NUTTransport {
    struct Boom: Error {}
    func request(_ command: String) async throws -> [String] { throw Boom() }
}

struct UPSMonitorTests {
    @Test func pollOnceSuccess() async {
        let t = MockTransport()
        t.responses["LIST VAR ups"] = [
            "BEGIN LIST VAR ups",
            "VAR ups ups.status \"OL\"",
            "VAR ups battery.charge \"100\"",
            "END LIST VAR ups"
        ]
        let m = UPSMonitor(transport: t, upsName: "ups")
        let snap = await m.pollOnce()
        #expect(snap.isConnected)
        #expect(snap.status?.batteryCharge == 100)
        #expect(snap.status?.isOnline == true)
    }

    @Test func pollOnceFailureFoldsToUnreachable() async {
        let m = UPSMonitor(transport: FailingTransport(), upsName: "ups")
        let snap = await m.pollOnce()
        #expect(!snap.isConnected)
        #expect(snap.status == nil)
        if case .unreachable = snap {} else { Issue.record("应为 .unreachable") }
    }
}
