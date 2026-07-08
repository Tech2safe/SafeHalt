public protocol NUTTransport: AnyObject {
    /// 发送一行命令（不含 CRLF），返回响应行（已去掉 CRLF）。
    func request(_ command: String) async throws -> [String]
}

public struct NUTConnectionInfo: Equatable {
    public let host: String
    public let port: Int
    public let ups: String
    public let username: String?
    public let password: String?
    public init(host: String, port: Int, ups: String, username: String?, password: String?) {
        self.host = host; self.port = port; self.ups = ups
        self.username = username; self.password = password
    }
}
