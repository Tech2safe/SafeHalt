// Sources/SafeHaltKit/DaemonLog.swift
import Foundation

/// 守护进程日志：只写 stderr（launchd 的 StandardErrorPath 已指向日志文件，再自写文件会重复一行）。
public enum DaemonLog {
    public static func write(_ message: String) {
        FileHandle.standardError.write(Data(line(message).utf8))
    }

    static func line(_ message: String, at date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(f.string(from: date)) [safehalt] \(message)\n"
    }
}
