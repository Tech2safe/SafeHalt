// Sources/SafeHaltKit/ShutdownDecider.swift
import Foundation
import SafeHaltCore

/// 决策纯函数的输入：一次决策所需的全部上下文（无隐藏状态、无 IO）。
public struct DeciderState {
    public let status: UPSStatus?
    public let onBatterySince: Date?
    public let commLostSince: Date?
    public let now: Date
    public let policy: ShutdownPolicy
    public let commLossFailsafeMinutes: Int
    public let cancelRequested: Bool
    public init(status: UPSStatus?, onBatterySince: Date? = nil, commLostSince: Date? = nil,
                now: Date, policy: ShutdownPolicy,
                commLossFailsafeMinutes: Int = 0, cancelRequested: Bool = false) {
        self.status = status; self.onBatterySince = onBatterySince; self.commLostSince = commLostSince
        self.now = now; self.policy = policy
        self.commLossFailsafeMinutes = commLossFailsafeMinutes; self.cancelRequested = cancelRequested
    }
}

public struct ShutdownDecision: Equatable {
    public enum Action: Equatable { case none, startCountdown, cancelCountdown, shutdownNow }
    public let action: Action
    public let reason: String
    public init(_ action: Action, _ reason: String) { self.action = action; self.reason = reason }
}

/// 关机决策纯函数——safehalt 的安全命脉，无任何 IO/定时器，可穷举测试。
public enum ShutdownDecider {
    public static func decide(_ s: DeciderState) -> ShutdownDecision {
        let counting = s.onBatterySince != nil

        // 1. 低电量：最紧急，越过取消（最后防线）；但市电在线时不关（如深放电后 OL LB 充电中，避免误关+开机关机循环）
        if let st = s.status, st.isLowBattery, !st.isOnline, s.policy.shutdownAlsoOnLowBattery {
            return ShutdownDecision(.shutdownNow, "UPS 电量过低，立即关机")
        }
        // 2. 市电恢复
        if let st = s.status, st.isOnline, !st.isOnBattery {
            return counting ? ShutdownDecision(.cancelCountdown, "市电已恢复，取消关机")
                            : ShutdownDecision(.none, "市电正常")
        }
        // 3. 用户已取消本次（仅在已进入倒计时时有效——残留标志不得预取消下一轮 episode）
        if counting, s.cancelRequested {
            return ShutdownDecision(.none, "用户已取消本次关机")
        }
        // 4. 转电池（含倒计时中通信中断，按最后已知 OB 续算）
        let onBattery = (s.status?.isOnBattery ?? false) || (counting && s.status == nil)
        if onBattery {
            guard let since = s.onBatterySince else {
                return ShutdownDecision(.startCountdown, "转电池供电，开始关机倒计时")
            }
            // 用户设定的最低电量（位于「取消」检查之后：可被取消；UPS 自带 LB 兜底见第 1 步，不可取消）
            if let st = s.status, st.isOnBattery, !st.isOnline, s.policy.minChargePercent > 0,
               let charge = st.batteryCharge, charge <= s.policy.minChargePercent {
                return ShutdownDecision(.shutdownNow, "电量降至 \(charge)%（不高于设定的 \(s.policy.minChargePercent)%），执行关机")
            }
            if s.now.timeIntervalSince(since) >= Double(s.policy.onBatteryMinutes * 60) {
                return ShutdownDecision(.shutdownNow, "转电池超过设定时长，执行关机")
            }
            return ShutdownDecision(.none, "转电池倒计时中")
        }
        // 5. 空闲时持续通信中断的 failsafe（保守：超阈值才当疑似断电）
        if s.status == nil, s.commLossFailsafeMinutes > 0, let lostSince = s.commLostSince {
            if s.now.timeIntervalSince(lostSince) >= Double(s.commLossFailsafeMinutes * 60) {
                return ShutdownDecision(.startCountdown, "与 UPS 持续通信中断，疑似断电，启动 failsafe 关机倒计时")
            }
            return ShutdownDecision(.none, "与 UPS 通信中断，failsafe 观察中")
        }
        // 6. 其它
        return ShutdownDecision(.none, s.status == nil ? "暂时无法读取 UPS 状态" : "状态未知")
    }
}
