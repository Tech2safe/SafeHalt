import Foundation

/// 守护进程对系统的副作用。注入以便逻辑脱离真机单测。
/// 契约：除 shutdown 外一律**非阻塞**（fire-and-forget）——关机绝不能被卡住的通知/对话框拖死。
public protocol SystemActions: Sendable {
    /// 无条件硬关机（真实现走 /sbin/shutdown -h now，不经 osascript；dry-run 只写日志）。
    func shutdown(reason: String)
    /// 用户会话简单通知（非阻塞）。
    func notify(_ message: String)
    /// 用户会话弹"可取消倒计时"对话框（非阻塞；带 giving up after；点取消由脚本自写标志文件）。message 说明本次原因。
    func presentCancelableWarning(minutes: Int, message: String)
    /// 是否有取消请求（查取消标志文件；由对话框脚本或 `safehalt cancel` 写入）。
    func isCancelRequested() -> Bool
    /// 新一轮转电池开始：清残留取消标志（避免被上一轮的取消预取消）。
    func beginEpisode()
    /// 本轮结束（市电恢复）：清取消标志。
    func endEpisode()
}
