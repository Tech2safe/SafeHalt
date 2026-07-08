import Foundation

/// 经 launchctl asuser 在登录会话弹"配对码"品牌对话框。
/// 与关机路径无关（安装/子命令上下文），可阻塞等待用户点"知道了"。
public enum PairingDialog {
    /// 构造 launchctl 参数（便于单测；不触发真实进程）。
    public static func osascriptArgs(uid: uid_t, code: String) -> [String] {
        let safe = code.replacingOccurrences(of: "\"", with: "")
        let script = "display dialog \"配对码：\(safe)\\n\\n打开 Mac UPS Link，在「连接断电保护引擎」处输入本码即可激活断电保护。\" with title \"⚡ SafeHalt 断电保护\" buttons {\"知道了\"} default button \"知道了\""
        return ["asuser", "\(uid)", "/usr/bin/osascript", "-e", script]
    }

    public static func present(code: String, consoleUID: uid_t?) {
        guard let uid = consoleUID else {
            print("配对码：\(code)（当前无图形登录用户，请在 Mac UPS Link 中输入此码）")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = osascriptArgs(uid: uid, code: code)
        try? p.run()
        p.waitUntilExit()   // 安装上下文，等用户读完；非守护循环，无阻塞风险
    }
}
