import Foundation

public struct EngineTarget: Codable, Equatable {
    public let host: String
    public let port: Int
    public let ups: String
    public init(host: String, port: Int, ups: String) { self.host = host; self.port = port; self.ups = ups }
}

public struct EnginePolicyDTO: Codable, Equatable {
    public let onBatteryMinutes: Int
    public let shutdownAlsoOnLowBattery: Bool
    public let commLossFailsafeMinutes: Int
    public init(onBatteryMinutes: Int, shutdownAlsoOnLowBattery: Bool, commLossFailsafeMinutes: Int) {
        self.onBatteryMinutes = onBatteryMinutes
        self.shutdownAlsoOnLowBattery = shutdownAlsoOnLowBattery
        self.commLossFailsafeMinutes = commLossFailsafeMinutes
    }
}

/// GET /status 回显。App 据此做一致性判定与健康展示。
public struct EngineStatus: Codable, Equatable {
    public let configured: Bool
    public let enabled: Bool
    public let target: EngineTarget?
    public let connected: Bool
    public let lastStatusRaw: String?
    public let lastSeenEpoch: Double?
    public let countdownActive: Bool
    public let countdownRemainingSeconds: Int?
    public let policy: EnginePolicyDTO?
    public init(configured: Bool, enabled: Bool, target: EngineTarget?, connected: Bool,
                lastStatusRaw: String?, lastSeenEpoch: Double?, countdownActive: Bool,
                countdownRemainingSeconds: Int?, policy: EnginePolicyDTO?) {
        self.configured = configured; self.enabled = enabled; self.target = target
        self.connected = connected; self.lastStatusRaw = lastStatusRaw; self.lastSeenEpoch = lastSeenEpoch
        self.countdownActive = countdownActive; self.countdownRemainingSeconds = countdownRemainingSeconds
        self.policy = policy
    }
}

/// GET /log 单条事件。
public struct EngineEvent: Codable, Equatable {
    public let atEpoch: Double
    public let kind: String
    public let message: String
    public init(atEpoch: Double, kind: String, message: String) {
        self.atEpoch = atEpoch; self.kind = kind; self.message = message
    }
}

/// 控制路由据此读引擎状态/事件、下发配置（DaemonRunner 遵从）。
public protocol EngineControl: Sendable {
    func currentStatus(now: Date) async -> EngineStatus
    func recentEvents(limit: Int) async -> [EngineEvent]
    func applySettings(_ cfg: DaemonConfig) async
}
