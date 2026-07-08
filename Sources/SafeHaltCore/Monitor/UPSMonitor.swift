public actor UPSMonitor {
    private let client: NUTClient
    private let upsName: String

    public init(transport: NUTTransport, upsName: String) {
        self.client = NUTClient(transport: transport)
        self.upsName = upsName
    }

    /// 读一次 UPS 全部变量；任何连接/协议错误不抛出，折叠为 .unreachable。
    public func pollOnce() async -> UPSSnapshot {
        do {
            let vars = try await client.readAllVars(ups: upsName)
            return .connected(UPSStatus(raw: vars))
        } catch {
            return .unreachable(String(describing: error))
        }
    }
}
