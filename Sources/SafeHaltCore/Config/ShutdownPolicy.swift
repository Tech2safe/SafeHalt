public struct ShutdownPolicy: Equatable {
    public var onBatteryMinutes: Int
    public var shutdownAlsoOnLowBattery: Bool
    /// 用户可选「最低电量」：电池供电且电量 ≤ 此值即关机；0 = 仅依赖 UPS 自带低电量（LB）。
    public var minChargePercent: Int
    public init(onBatteryMinutes: Int = 10, shutdownAlsoOnLowBattery: Bool = true, minChargePercent: Int = 0) {
        self.onBatteryMinutes = onBatteryMinutes
        self.shutdownAlsoOnLowBattery = shutdownAlsoOnLowBattery
        self.minChargePercent = minChargePercent
    }
    public static let `default` = ShutdownPolicy()
}
