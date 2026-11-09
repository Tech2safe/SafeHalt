import Foundation
import SafeHaltCore

public enum DaemonConfigError: Error, Equatable { case invalid(String) }

public struct DaemonConfig: Codable, Equatable {
    public let host: String
    public let port: Int
    public let ups: String
    public let username: String
    public let password: String
    public let onBatteryMinutes: Int
    public let shutdownAlsoOnLowBattery: Bool
    /// 最低电量门槛（%）；0 = 仅 UPS 默认。旧 config 无此字段时为 0。
    public let minChargePercent: Int
    /// 空闲时连续通信中断多少分钟触发 failsafe 关机；0 = 关闭。保守，宜 ≥ NAS 重启耗时。
    public let commLossFailsafeMinutes: Int
    public let pollSeconds: Int
    /// App 可从控制面板暂停/恢复保护。默认 true（旧 config 无此字段时保持启用）。
    public let enabled: Bool

    public init(host: String, port: Int, ups: String,
                username: String = "", password: String = "",
                onBatteryMinutes: Int, shutdownAlsoOnLowBattery: Bool,
                minChargePercent: Int = 0,
                commLossFailsafeMinutes: Int = 0, pollSeconds: Int = 5,
                enabled: Bool = true) {
        self.host = host; self.port = port; self.ups = ups
        self.username = username; self.password = password
        self.onBatteryMinutes = onBatteryMinutes
        self.shutdownAlsoOnLowBattery = shutdownAlsoOnLowBattery
        self.minChargePercent = minChargePercent
        self.commLossFailsafeMinutes = commLossFailsafeMinutes
        self.pollSeconds = pollSeconds
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, ups, username, password, onBatteryMinutes
        case shutdownAlsoOnLowBattery, minChargePercent, commLossFailsafeMinutes, pollSeconds, enabled
    }

    // 自定义解码：凭据/failsafe/poll/enabled 缺失时取默认，保证旧 config 向后兼容。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        ups = try c.decode(String.self, forKey: .ups)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        onBatteryMinutes = try c.decode(Int.self, forKey: .onBatteryMinutes)
        shutdownAlsoOnLowBattery = try c.decode(Bool.self, forKey: .shutdownAlsoOnLowBattery)
        minChargePercent = try c.decodeIfPresent(Int.self, forKey: .minChargePercent) ?? 0
        commLossFailsafeMinutes = try c.decodeIfPresent(Int.self, forKey: .commLossFailsafeMinutes) ?? 0
        pollSeconds = try c.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? 5
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public var policy: ShutdownPolicy {
        ShutdownPolicy(onBatteryMinutes: onBatteryMinutes, shutdownAlsoOnLowBattery: shutdownAlsoOnLowBattery,
                       minChargePercent: minChargePercent)
    }

    public static func load(data: Data) throws -> DaemonConfig {
        let cfg = try JSONDecoder().decode(DaemonConfig.self, from: data)
        guard cfg.onBatteryMinutes >= 1 else {
            throw DaemonConfigError.invalid("onBatteryMinutes 必须 ≥ 1（当前 \(cfg.onBatteryMinutes)），否则任何转电池瞬间即关机")
        }
        guard cfg.commLossFailsafeMinutes >= 0 else {
            throw DaemonConfigError.invalid("commLossFailsafeMinutes 不能为负（当前 \(cfg.commLossFailsafeMinutes)）")
        }
        guard cfg.minChargePercent == 0 || (5...95).contains(cfg.minChargePercent) else {
            throw DaemonConfigError.invalid("minChargePercent 须为 0（仅 UPS 默认）或 5…95（当前 \(cfg.minChargePercent)）")
        }
        guard cfg.pollSeconds >= 1 else {
            throw DaemonConfigError.invalid("pollSeconds 必须 ≥ 1（当前 \(cfg.pollSeconds)）")
        }
        return cfg
    }
    public static func load(path: String) throws -> DaemonConfig {
        try load(data: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    public func encoded() throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }
}
