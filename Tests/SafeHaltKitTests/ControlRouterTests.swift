import Foundation
import Testing
@testable import SafeHaltKit

private actor FakeEngine: EngineControl {
    var applied: DaemonConfig?
    private(set) var resumedCount = 0
    let status: EngineStatus
    let events: [EngineEvent]
    init(status: EngineStatus, events: [EngineEvent] = []) { self.status = status; self.events = events }
    func currentStatus(now: Date) async -> EngineStatus { status }
    func recentEvents(limit: Int) async -> [EngineEvent] { Array(events.prefix(limit)) }
    func applySettings(_ cfg: DaemonConfig) async { applied = cfg }
    func resumeCountdown() async { resumedCount += 1 }
    func appliedConfig() -> DaemonConfig? { applied }
    func resumes() -> Int { resumedCount }
}

struct ControlRouterTests {
    private let seq: RandomBytes = { count in (0..<count).map { UInt8($0 & 0xFF) } }
    private let dumbStatus = EngineStatus(configured: false, enabled: false, target: nil, connected: false,
        lastStatusRaw: nil, lastSeenEpoch: nil, countdownActive: false, countdownRemainingSeconds: nil, policy: nil)

    private func store(_ name: String) -> PairingStore {
        PairingStore(path: NSTemporaryDirectory() + "router-\(name).json")
    }
    private func req(_ method: String, _ path: String, headers: [String:String] = [:], body: String = "") -> HTTPRequest {
        var h = headers; if !body.isEmpty { h["content-length"] = "\(body.utf8.count)" }
        // 用解析器构造，确保与真实链路一致
        let raw = "\(method) \(path) HTTP/1.1\r\n" + h.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n\r\n" + body
        guard case .ok(let r) = try! HTTPParser.parse(Data(raw.utf8)) else { fatalError("测试请求构造失败") }
        return r
    }
    private func router(_ engine: FakeEngine, _ st: PairingStore, cancel: @escaping @Sendable () -> Void = {}) -> ControlRouter {
        ControlRouter(engine: engine, pairing: st, random: seq, now: { Date(timeIntervalSince1970: 0) }, touchCancel: cancel)
    }

    @Test func pingUnauthenticatedReportsState() async throws {
        let s = store("ping"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        _ = try Pairing.initPairing(store: s, random: seq)
        let r = router(FakeEngine(status: dumbStatus), s)
        let resp = await r.handle(req("GET", "/ping"))
        #expect(resp.status == 200)
        let obj = try JSONSerialization.jsonObject(with: resp.body) as! [String: Any]
        #expect(obj["installed"] as? Bool == true)
        #expect(obj["paired"] as? Bool == false)
        #expect(obj["configured"] as? Bool == false)
    }

    @Test func pairWithCorrectCodeReturnsToken() async throws {
        let s = store("pair"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        let code = try Pairing.initPairing(store: s, random: seq)
        let r = router(FakeEngine(status: dumbStatus), s)
        let resp = await r.handle(req("POST", "/pair", body: #"{"code":"\#(code)"}"#))
        #expect(resp.status == 200)
        let obj = try JSONSerialization.jsonObject(with: resp.body) as! [String: Any]
        #expect((obj["token"] as? String)?.isEmpty == false)
    }

    @Test func pairWithWrongCodeIs401() async throws {
        let s = store("pairbad"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        _ = try Pairing.initPairing(store: s, random: seq)
        let r = router(FakeEngine(status: dumbStatus), s)
        let resp = await r.handle(req("POST", "/pair", body: #"{"code":"WRON-GXXX"}"#))
        #expect(resp.status == 401)
    }

    @Test func protectedEndpointWithoutTokenIs401() async throws {
        let s = store("noauth"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        _ = try Pairing.initPairing(store: s, random: seq)
        let r = router(FakeEngine(status: dumbStatus), s)
        #expect(await r.handle(req("GET", "/status")).status == 401)
    }

    @Test func configWithValidTokenAppliesSettings() async throws {
        let s = store("config"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        let code = try Pairing.initPairing(store: s, random: seq)
        let engine = FakeEngine(status: dumbStatus)
        let r = router(engine, s)
        let token = try #require(try Pairing.redeem(store: s, submittedCode: code, random: seq))
        let body = #"{"host":"192.168.0.5","port":3493,"ups":"ups","onBatteryMinutes":10,"shutdownAlsoOnLowBattery":true,"commLossFailsafeMinutes":5,"enabled":true}"#
        let resp = await r.handle(req("POST", "/config", headers: ["authorization": "Bearer \(token)"], body: body))
        #expect(resp.status == 200)
        let applied = await engine.appliedConfig()
        #expect(applied?.host == "192.168.0.5")
        #expect(applied?.onBatteryMinutes == 10)
    }

    @Test func configWithInvalidBodyIs400() async throws {
        let s = store("cfgbad"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        let code = try Pairing.initPairing(store: s, random: seq)
        let token = try #require(try Pairing.redeem(store: s, submittedCode: code, random: seq))
        let r = router(FakeEngine(status: dumbStatus), s)
        // onBatteryMinutes=0 触发 DaemonConfig.load 校验失败
        let body = #"{"host":"h","port":3493,"ups":"ups","onBatteryMinutes":0,"shutdownAlsoOnLowBattery":true}"#
        let resp = await r.handle(req("POST", "/config", headers: ["authorization": "Bearer \(token)"], body: body))
        #expect(resp.status == 400)
    }

    @Test func cancelTouchesFlag() async throws {
        let s = store("cancel"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        let code = try Pairing.initPairing(store: s, random: seq)
        let token = try #require(try Pairing.redeem(store: s, submittedCode: code, random: seq))
        var touched = false
        let r = router(FakeEngine(status: dumbStatus), s, cancel: { touched = true })
        let resp = await r.handle(req("POST", "/cancel", headers: ["authorization": "Bearer \(token)"]))
        #expect(resp.status == 200)
        #expect(touched == true)
    }

    @Test func resumeCallsEngine() async throws {
        let s = store("resume"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        let code = try Pairing.initPairing(store: s, random: seq)
        let token = try #require(try Pairing.redeem(store: s, submittedCode: code, random: seq))
        let engine = FakeEngine(status: dumbStatus)
        let r = router(engine, s)
        let resp = await r.handle(req("POST", "/resume", headers: ["authorization": "Bearer \(token)"]))
        #expect(resp.status == 200)
        #expect(await engine.resumes() == 1)
    }

    @Test func resumeRequiresToken() async throws {
        let s = store("resume-noauth"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        _ = try Pairing.initPairing(store: s, random: seq)
        let r = router(FakeEngine(status: dumbStatus), s)
        #expect(await r.handle(req("POST", "/resume")).status == 401)
    }

    @Test func logReturnsEvents() async throws {
        let s = store("log"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        let code = try Pairing.initPairing(store: s, random: seq)
        let token = try #require(try Pairing.redeem(store: s, submittedCode: code, random: seq))
        let ev = [EngineEvent(atEpoch: 1, kind: "countdown", message: "转电池"),
                  EngineEvent(atEpoch: 2, kind: "restore", message: "恢复")]
        let r = router(FakeEngine(status: dumbStatus, events: ev), s)
        let resp = await r.handle(req("GET", "/log?n=50", headers: ["authorization": "Bearer \(token)"]))
        #expect(resp.status == 200)
        let arr = try JSONSerialization.jsonObject(with: resp.body) as! [[String: Any]]
        #expect(arr.count == 2)
    }

    @Test func unknownPathIs404() async throws {
        let s = store("404"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        let code = try Pairing.initPairing(store: s, random: seq)
        let token = try #require(try Pairing.redeem(store: s, submittedCode: code, random: seq))
        let r = router(FakeEngine(status: dumbStatus), s)
        #expect(await r.handle(req("GET", "/nope", headers: ["authorization": "Bearer \(token)"])).status == 404)
    }
}
