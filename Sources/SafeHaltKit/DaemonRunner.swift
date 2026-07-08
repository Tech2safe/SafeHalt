// Sources/SafeHaltKit/DaemonRunner.swift
import Foundation
import SafeHaltCore

/// 守护进程主循环：轮询 UPS → 决策 → 副作用。维护转电池起始与通信中断起始。
public actor DaemonRunner {
    private let config: DaemonConfig
    private var transportFactory: @Sendable (String, Int) -> NUTTransport
    private let actions: SystemActions
    private var onBatterySince: Date?
    private var commLostSince: Date?

    public init(config: DaemonConfig,
                transportFactory: @escaping @Sendable (String, Int) -> NUTTransport,
                actions: SystemActions) {
        self.config = config
        self.transportFactory = transportFactory
        self.actions = actions
    }

    public var onBatterySinceForTest: Date? { onBatterySince }
    public func setTransportFactoryForTest(_ f: @escaping @Sendable (String, Int) -> NUTTransport) {
        transportFactory = f
    }

    public func tick(now: Date) async {
        let monitor = UPSMonitor(transport: transportFactory(config.host, config.port), upsName: config.ups)
        let status = (await monitor.pollOnce()).status

        // 仅更新状态（decide 的输入）；通信通知延后——关机绝不能排在可能卡住的通知之后
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

        // 先执行动作：关机（若有）必须发生在任何通信通知之前
        switch decision.action {
        case .none:
            break
        case .startCountdown:
            onBatterySince = now
            actions.beginEpisode()
            let warnMsg = (status == nil)
                ? "与 UPS 通信持续中断，疑似断电。\(config.onBatteryMinutes) 分钟后若未恢复将自动关机。"
                : "市电中断，已转 UPS 供电。\(config.onBatteryMinutes) 分钟后若未恢复将自动关机。"
            actions.presentCancelableWarning(minutes: config.onBatteryMinutes, message: warnMsg)
        case .cancelCountdown:
            onBatterySince = nil
            actions.endEpisode()
            actions.notify("市电已恢复，取消关机。")
        case .shutdownNow:
            // 安全铁律：关机不依赖任何通知（通知可能因 TCC/无会话卡住）；直接硬关机。
            actions.shutdown(reason: decision.reason)
        }

        // 通信状态通知置于动作之后：即便它卡住，本 tick 的关机/动作已完成
        if commJustLost {
            actions.notify(config.commLossFailsafeMinutes > 0
                ? "与 UPS 的通信中断，\(config.commLossFailsafeMinutes) 分钟内未恢复将按断电处理。"
                : "与 UPS 的通信中断（未启用通信丢失关机，仅监控）。")
        } else if commJustRestored {
            actions.notify("与 UPS 的通信已恢复。")
        }
    }

    public func run() async {
        while !Task.isCancelled {
            await tick(now: Date())
            try? await Task.sleep(nanoseconds: UInt64(max(1, config.pollSeconds)) * 1_000_000_000)
        }
    }
}
