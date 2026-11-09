import Foundation
import Testing
@testable import SafeHaltKit

private actor StubEngine: EngineControl {
    func currentStatus(now: Date) async -> EngineStatus {
        EngineStatus(configured: true, enabled: true,
                     target: EngineTarget(host: "192.168.0.5", port: 3493, ups: "ups"),
                     connected: true, lastStatusRaw: "OL", lastSeenEpoch: 100,
                     countdownActive: false, countdownRemainingSeconds: nil,
                     policy: EnginePolicyDTO(onBatteryMinutes: 10, shutdownAlsoOnLowBattery: true, commLossFailsafeMinutes: 5))
    }
    func recentEvents(limit: Int) async -> [EngineEvent] { [] }
    func applySettings(_ cfg: DaemonConfig) async {}
    func resumeCountdown() async {}
}

struct ControlServerIntegrationTests {
    private let seq: RandomBytes = { count in (0..<count).map { UInt8($0 & 0xFF) } }

    @Test func servesPingOverLoopback() async throws {
        let store = PairingStore(path: NSTemporaryDirectory() + "srv-ping.json")
        defer { try? FileManager.default.removeItem(atPath: store.path) }
        _ = try Pairing.initPairing(store: store, random: seq)
        let router = ControlRouter(engine: StubEngine(), pairing: store, random: seq,
                                   now: { Date() }, touchCancel: {})
        let server = ControlServer(port: 0, router: router)
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.boundPort())

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/ping")!)
        req.timeoutInterval = 3
        let (data, resp) = try await URLSession.shared.data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["installed"] as? Bool == true)
    }

    @Test func statusRequiresTokenOverLoopback() async throws {
        let store = PairingStore(path: NSTemporaryDirectory() + "srv-auth.json")
        defer { try? FileManager.default.removeItem(atPath: store.path) }
        _ = try Pairing.initPairing(store: store, random: seq)
        let router = ControlRouter(engine: StubEngine(), pairing: store, random: seq,
                                   now: { Date() }, touchCancel: {})
        let server = ControlServer(port: 0, router: router)
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.boundPort())

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/status")!)
        req.timeoutInterval = 3
        let (_, resp) = try await URLSession.shared.data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 401)
    }

    /// 回归测试：第二个 ControlServer 绑定同一已占用端口时，start() 必须在有限时间内返回
    /// （抛错或成功皆可），绝不能像 `.waiting` 状态未处理那样永久挂起——
    /// 挂起会阻塞守护进程主循环启动，属于安全性回归。
    @Test func secondServerOnSamePortFailsFastNotHang() async throws {
        let storeA = PairingStore(path: NSTemporaryDirectory() + "srv-portconflict-a.json")
        let storeB = PairingStore(path: NSTemporaryDirectory() + "srv-portconflict-b.json")
        defer {
            try? FileManager.default.removeItem(atPath: storeA.path)
            try? FileManager.default.removeItem(atPath: storeB.path)
        }
        _ = try Pairing.initPairing(store: storeA, random: seq)
        _ = try Pairing.initPairing(store: storeB, random: seq)
        let routerA = ControlRouter(engine: StubEngine(), pairing: storeA, random: seq,
                                    now: { Date() }, touchCancel: {})
        let routerB = ControlRouter(engine: StubEngine(), pairing: storeB, random: seq,
                                    now: { Date() }, touchCancel: {})
        let a = ControlServer(port: 0, router: routerA)
        try await a.start()
        let b = ControlServer(port: try #require(await a.boundPort()), router: routerB)
        defer {
            Task {
                await a.stop()
                await b.stop()
            }
        }

        enum RaceResult: Equatable { case started, timedOut }

        let result = try await withThrowingTaskGroup(of: RaceResult.self) { group in
            group.addTask {
                do { try await b.start() } catch { /* 抛错也算「返回」，属于预期行为之一 */ }
                return .started
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return .timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        if result == .timedOut {
            Issue.record("start() 未在 5s 内返回，疑似 .waiting 挂起回归")
        }
        #expect(result == .started)
    }
}
