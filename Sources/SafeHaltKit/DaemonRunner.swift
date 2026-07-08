// Sources/SafeHaltKit/DaemonRunner.swift
import Foundation
import SafeHaltCore

/// 守护进程主循环：轮询 UPS → 决策 → 副作用。维护转电池起始与通信中断起始。
/// 支持哑/暂停门控与运行期改配（App 经 HTTP 控制）。
public actor DaemonRunner: EngineControl {
    private var settings: DaemonConfig?
    private var transportFactory: @Sendable (String, Int) -> NUTTransport
    private let actions: SystemActions
    private let persist: (@Sendable (DaemonConfig) -> Void)?

    private var onBatterySince: Date?
    private var commLostSince: Date?

    // /status 与 /log 所需的观测量
    private var lastStatus: UPSStatus?
    private var lastSeen: Date?
    private var events: [EngineEvent] = []
    private let eventCap = 100

    public init(settings: DaemonConfig?,
                transportFactory: @escaping @Sendable (String, Int) -> NUTTransport,
                actions: SystemActions,
                persist: (@Sendable (DaemonConfig) -> Void)? = nil) {
        self.settings = settings
        self.transportFactory = transportFactory
        self.actions = actions
        self.persist = persist
    }

    public var onBatterySinceForTest: Date? { onBatterySince }
    public func setTransportFactoryForTest(_ f: @escaping @Sendable (String, Int) -> NUTTransport) {
        transportFactory = f
    }

    // MARK: EngineControl

    public func applySettings(_ cfg: DaemonConfig) {
        let targetChanged = settings.map { $0.host != cfg.host || $0.port != cfg.port || $0.ups != cfg.ups } ?? true
        settings = cfg
        if targetChanged { onBatterySince = nil; commLostSince = nil; lastStatus = nil; lastSeen = nil }
        persist?(cfg)
        appendEvent(kind: "config", message: "配置已更新（\(cfg.host)/\(cfg.ups)，\(cfg.enabled ? "启用" : "暂停")）")
    }

    public func currentStatus(now: Date) -> EngineStatus {
        guard let cfg = settings else {
            return EngineStatus(configured: false, enabled: false, target: nil, connected: false,
                                lastStatusRaw: nil, lastSeenEpoch: nil, countdownActive: false,
                                countdownRemainingSeconds: nil, policy: nil)
        }
        let counting = onBatterySince != nil
        let remaining: Int? = onBatterySince.map {
            max(0, cfg.onBatteryMinutes * 60 - Int(now.timeIntervalSince($0)))
        }
        let connected = lastStatus != nil
        return EngineStatus(
            configured: true, enabled: cfg.enabled,
            target: EngineTarget(host: cfg.host, port: cfg.port, ups: cfg.ups),
            connected: connected,
            lastStatusRaw: lastStatus?.raw["ups.status"],
            lastSeenEpoch: lastSeen?.timeIntervalSince1970,
            countdownActive: counting,
            countdownRemainingSeconds: counting ? remaining : nil,
            policy: EnginePolicyDTO(onBatteryMinutes: cfg.onBatteryMinutes,
                                    shutdownAlsoOnLowBattery: cfg.shutdownAlsoOnLowBattery,
                                    commLossFailsafeMinutes: cfg.commLossFailsafeMinutes))
    }

    public func recentEvents(limit: Int) -> [EngineEvent] {
        Array(events.suffix(max(0, limit)))
    }

    private func appendEvent(kind: String, message: String) {
        events.append(EngineEvent(atEpoch: Date().timeIntervalSince1970, kind: kind, message: message))
        if events.count > eventCap { events.removeFirst(events.count - eventCap) }
    }

    // MARK: 主循环

    public func tick(now: Date) async {
        // 哑（无配置）或暂停（enabled=false）：不连 NUT、不决策、不关机
        guard let config = settings, config.enabled else { return }

        let monitor = UPSMonitor(transport: transportFactory(config.host, config.port), upsName: config.ups)
        let status = (await monitor.pollOnce()).status
        if let status { lastStatus = status; lastSeen = now }

        let commJustLost = (status == nil && commLostSince == nil)
        let commJustRestored = (status != nil && commLostSince != nil)
        if status == nil {
            if commLostSince == nil { commLostSince = now }
        } else {
            commLostSince = nil
        }

        let decision = ShutdownDecider.decide(DeciderState(
            status: status, onBatterySince: onBatterySince, commLostSince: commLostSince,
            now: now, policy: config.policy,
            commLossFailsafeMinutes: config.commLossFailsafeMinutes,
            cancelRequested: actions.isCancelRequested()))

        switch decision.action {
        case .none:
            break
        case .startCountdown:
            onBatterySince = now
            actions.beginEpisode()
            appendEvent(kind: "countdown", message: decision.reason)
            let warnMsg = (status == nil)
                ? "与 UPS 通信持续中断，疑似断电。\(config.onBatteryMinutes) 分钟后若未恢复将自动关机。"
                : "市电中断，已转 UPS 供电。\(config.onBatteryMinutes) 分钟后若未恢复将自动关机。"
            actions.presentCancelableWarning(minutes: config.onBatteryMinutes, message: warnMsg)
        case .cancelCountdown:
            onBatterySince = nil
            actions.endEpisode()
            appendEvent(kind: "restore", message: "市电已恢复，取消关机")
            actions.notify("市电已恢复，取消关机。")
        case .shutdownNow:
            appendEvent(kind: "shutdown", message: decision.reason)
            actions.shutdown(reason: decision.reason)
        }

        if commJustLost {
            appendEvent(kind: "commLost", message: "与 UPS 的通信中断")
            actions.notify(config.commLossFailsafeMinutes > 0
                ? "与 UPS 的通信中断，\(config.commLossFailsafeMinutes) 分钟内未恢复将按断电处理。"
                : "与 UPS 的通信中断（未启用通信丢失关机，仅监控）。")
        } else if commJustRestored {
            appendEvent(kind: "commRestore", message: "与 UPS 的通信已恢复")
            actions.notify("与 UPS 的通信已恢复。")
        }
    }

    public func run() async {
        while !Task.isCancelled {
            await tick(now: Date())
            let sleep = settings.map { max(1, $0.pollSeconds) } ?? 5
            try? await Task.sleep(nanoseconds: UInt64(sleep) * 1_000_000_000)
        }
    }
}
