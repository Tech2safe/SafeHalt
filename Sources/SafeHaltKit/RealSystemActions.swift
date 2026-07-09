import Foundation
import SystemConfiguration

/// 真实副作用。一切 osascript fire-and-forget（不 waitUntilExit）；关机无条件硬关机。
public struct RealSystemActions: SystemActions {
    private let dryRun: Bool
    private let consoleUID: () -> uid_t?

    public init(dryRun: Bool, consoleUID: @escaping () -> uid_t? = RealSystemActions.currentConsoleUID) {
        self.dryRun = dryRun
        self.consoleUID = consoleUID
    }

    public func shutdown(reason: String) {
        log("SHUTDOWN 决策：\(reason)")
        if dryRun { log("[dry-run] 跳过真实关机"); return }
        // 无条件硬关机，不经 osascript、不需用户确认
        runDetached("/sbin/shutdown", ["-h", "now", "SafeHalt: UPS power protection"])
    }

    public func notify(_ message: String) {
        log("通知：\(message)")
        guard let uid = consoleUID() else { return }
        let safe = message.replacingOccurrences(of: "\"", with: "'")
        runDetached("/bin/launchctl", ["asuser", "\(uid)", "/usr/bin/osascript",
            "-e", "display notification \"\(safe)\" with title \"⚡ 断电保护\""])
    }

    public func presentCancelableWarning(minutes: Int, message: String) {
        log("弹可取消倒计时告警：\(minutes) 分钟")
        guard let uid = consoleUID() else { return }
        let cancelBtn = "取消关机"
        let safeMsg = message.replacingOccurrences(of: "\"", with: "'")
        // 对话框存活整个倒计时（giving up after），到期自动放行；点取消由脚本自写标志文件。
        // fire-and-forget：绝不等待用户，绝不阻塞关机。消息第二行提示取消有风险。
        runDetached("/bin/launchctl", ["asuser", "\(uid)", "/usr/bin/osascript",
            "-e", "set res to (display alert \"⚡ 断电保护\" message (\"\(safeMsg)\" & return & return & \"有风险，请自行关机\") buttons {\"\(cancelBtn)\", \"知道了\"} default button \"知道了\" giving up after \(minutes * 60))",
            "-e", "if (gave up of res) is false and (button returned of res) is \"\(cancelBtn)\" then do shell script \"/usr/bin/touch '\(DaemonPaths.cancelFlagFile)'\""])
    }

    public func isCancelRequested() -> Bool {
        FileManager.default.fileExists(atPath: DaemonPaths.cancelFlagFile)
    }
    public func beginEpisode() { try? FileManager.default.removeItem(atPath: DaemonPaths.cancelFlagFile) }
    public func endEpisode() { try? FileManager.default.removeItem(atPath: DaemonPaths.cancelFlagFile) }

    /// 当前控制台（图形登录）用户 uid；登录界面/无人登录返回 nil。
    public static func currentConsoleUID() -> uid_t? {
        var uid: uid_t = 0
        let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil)
        return name != nil && uid != 0 ? uid : nil
    }

    private func log(_ s: String) {
        let line = "[safehalt] \(s)\n"
        if let h = FileHandle(forWritingAtPath: DaemonPaths.logFile) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: DaemonPaths.logFile, atomically: true, encoding: .utf8)
        }
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// 启动外部命令后立即返回，绝不 waitUntilExit——防止卡住的 osascript 拖死主循环。
    private func runDetached(_ path: String, _ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        do { try p.run() } catch { log("外部命令启动失败 \(path): \(error)") }
    }
}
