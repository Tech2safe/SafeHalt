public struct ShutdownPolicy: Equatable {
    public var onBatteryMinutes: Int
    public var shutdownAlsoOnLowBattery: Bool
    public init(onBatteryMinutes: Int = 10, shutdownAlsoOnLowBattery: Bool = true) {
        self.onBatteryMinutes = onBatteryMinutes
        self.shutdownAlsoOnLowBattery = shutdownAlsoOnLowBattery
    }
    public static let `default` = ShutdownPolicy()
}
