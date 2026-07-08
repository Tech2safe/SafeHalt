// 生成 launchd LaunchDaemon plist：RunAtLoad + KeepAlive，
// 跑 /usr/local/bin/safehalt --config <configFile>，日志落到 logFile。
public enum DaemonPlist {
    public static func launchd() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(DaemonPaths.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(DaemonPaths.binary)</string>
                <string>--config</string>
                <string>\(DaemonPaths.configFile)</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardErrorPath</key><string>\(DaemonPaths.logFile)</string>
            <key>StandardOutPath</key><string>\(DaemonPaths.logFile)</string>
        </dict>
        </plist>
        """
    }
}
