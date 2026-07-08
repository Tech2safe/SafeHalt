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
}
