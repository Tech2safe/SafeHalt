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
    /// 空闲时连续通信中断多少分钟触发 failsafe 关机；0 = 关闭。保守，宜 ≥ NAS 重启耗时。
    public let commLossFailsafeMinutes: Int
    public let pollSeconds: Int

    public init(host: String, port: Int, ups: String, username: String, password: String,
                onBatteryMinutes: Int, shutdownAlsoOnLowBattery: Bool,
                commLossFailsafeMinutes: Int, pollSeconds: Int) {
        self.host = host; self.port = port; self.ups = ups
        self.username = username; self.password = password
        self.onBatteryMinutes = onBatteryMinutes
        self.shutdownAlsoOnLowBattery = shutdownAlsoOnLowBattery
        self.commLossFailsafeMinutes = commLossFailsafeMinutes
        self.pollSeconds = pollSeconds
    }

    public var policy: ShutdownPolicy {
        ShutdownPolicy(onBatteryMinutes: onBatteryMinutes, shutdownAlsoOnLowBattery: shutdownAlsoOnLowBattery)
    }

    public static func load(data: Data) throws -> DaemonConfig {
        let cfg = try JSONDecoder().decode(DaemonConfig.self, from: data)
        guard cfg.onBatteryMinutes >= 1 else {
            throw DaemonConfigError.invalid("onBatteryMinutes 必须 ≥ 1（当前 \(cfg.onBatteryMinutes)），否则任何转电池瞬间即关机")
        }
        guard cfg.commLossFailsafeMinutes >= 0 else {
            throw DaemonConfigError.invalid("commLossFailsafeMinutes 不能为负（当前 \(cfg.commLossFailsafeMinutes)）")
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
