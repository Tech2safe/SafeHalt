public enum DaemonPaths {
    public static let label = "com.safehalt.daemon"
    public static let binary = "/usr/local/bin/safehalt"
    public static let configDir = "/Library/Application Support/SafeHalt"
    public static let configFile = "/Library/Application Support/SafeHalt/config.json"
    public static let launchdPlist = "/Library/LaunchDaemons/com.safehalt.daemon.plist"
    public static let logFile = "/var/log/safehalt.log"
    /// 取消标志：守护进程内部机制（自弹对话框的 osascript 或 `safehalt cancel` 写入）。
    /// 关机前检查其存在即中止本次。绝不由沙盒 App 读写。
    public static let cancelFlagFile = "/tmp/safehalt-cancel-shutdown"
    /// 控制服务端固定端口（只绑 127.0.0.1）。App 客户端硬编码同值。
    public static let httpPort = 57117
    /// 配对状态（配对码哈希 + 令牌哈希），600 root。绝不由沙盒 App 读写，只经 HTTP。
    public static let pairingFile = "/Library/Application Support/SafeHalt/pairing.json"
}
