import Foundation
import Testing
import SafeHaltCore
@testable import SafeHaltKit

final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _saves: [[EngineEvent]] = []
    private var _shutdownSeenAtSave: [Bool] = []
    let actions: MockSystemActions?
    init(actions: MockSystemActions? = nil) { self.actions = actions }
    func save(_ e: [EngineEvent]) {
        lock.lock(); _saves.append(e); _shutdownSeenAtSave.append(!(actions?.shutdownReasons.isEmpty ?? true)); lock.unlock()
    }
    var saves: [[EngineEvent]] { lock.lock(); defer { lock.unlock() }; return _saves }
    var shutdownSeenAtSave: [Bool] { lock.lock(); defer { lock.unlock() }; return _shutdownSeenAtSave }
}

struct EventPersistenceTests {
    private func cfg() -> DaemonConfig {
        DaemonConfig(host: "h", port: 3493, ups: "ups", onBatteryMinutes: 10,
                     shutdownAlsoOnLowBattery: true, commLossFailsafeMinutes: 0, pollSeconds: 5)
    }
    private func ob() -> @Sendable (String, Int) -> NUTTransport {
        { _, _ in
            let t = MockTransport()
            t.responses["LIST VAR ups"] = ["BEGIN LIST VAR ups", "VAR ups ups.status \"OB\"", "END LIST VAR ups"]
            return t
        }
    }
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    @Test func startsWithPersistedEvents() async {
        let old = [EngineEvent(atEpoch: 1, kind: "shutdown", message: "上次关机")]
        let r = DaemonRunner(settings: cfg(), transportFactory: ob(), actions: MockSystemActions(),
                             initialEvents: old)
        #expect(await r.recentEvents(limit: 10) == old)
    }

    @Test func everyEventIsPersisted() async {
        let sink = EventSink()
        let r = DaemonRunner(settings: cfg(), transportFactory: ob(), actions: MockSystemActions(),
                             persistEvents: { sink.save($0) })
        await r.tick(now: t0)
        #expect(sink.saves.last?.map(\.kind) == ["countdown"])
    }

    /// 安全红线：关机事件先发关机命令、后写盘——写盘绝不拖慢关机。
    @Test func shutdownIssuedBeforeEventPersisted() async {
        let a = MockSystemActions()
        let sink = EventSink(actions: a)
        let r = DaemonRunner(settings: cfg(), transportFactory: ob(), actions: a,
                             persistEvents: { sink.save($0) })
        await r.tick(now: t0)
        await r.tick(now: t0.addingTimeInterval(10 * 60))
        #expect(a.shutdownReasons.count == 1)
        #expect(sink.saves.last?.last?.kind == "shutdown")
        #expect(sink.shutdownSeenAtSave.last == true)
    }

    @Test func storeRoundTripsAndCapsAndToleratesGarbage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("events.json").path
        let store = EventStore(path: path)
        #expect(store.load().isEmpty)
        let evs = [EngineEvent(atEpoch: 5, kind: "restore", message: "市电已恢复")]
        store.save(evs)
        #expect(store.load() == evs)
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        #expect(store.load().isEmpty)
    }
}
