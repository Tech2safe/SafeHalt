public enum UPSSnapshot: Equatable {
    case connected(UPSStatus)
    case unreachable(String)   // 错误描述（开发用；UI 层显示统一人话）

    public var status: UPSStatus? {
        if case .connected(let s) = self { return s }
        return nil
    }
    public var isConnected: Bool { status != nil }
}
