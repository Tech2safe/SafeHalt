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
}
