public actor NUTClient {
    private let transport: NUTTransport
    public init(transport: NUTTransport) { self.transport = transport }

    public func listUPS() async throws -> [String] {
        let lines = try await transport.request("LIST UPS")
        return try NUTProtocol.parseUPSList(lines)
    }

    public func readAllVars(ups: String) async throws -> [String: String] {
        let lines = try await transport.request("LIST VAR \(ups)")
        return try NUTProtocol.parseVarList(lines)
    }

    public func numLogins(ups: String) async throws -> Int {
        let lines = try await transport.request("GET NUMLOGINS \(ups)")
        guard let first = lines.first else { throw NUTError.malformed("empty NUMLOGINS reply") }
        return try NUTProtocol.parseNumLogins(first)
    }

    /// 测试凭据能否登录（OK→true，ACCESS-DENIED→false，其它错误抛出）。
    /// ⚠️ 必须用会话式传输（NUTSocketSession）：USERNAME/PASSWORD/LOGIN 需同一条连接，
    /// 一次性传输（NUTSocketTransport）每请求新建连接，会话状态丢失，登录必然失败。
    public func testLogin(ups: String, username: String, password: String) async throws -> Bool {
        _ = try await transport.request("USERNAME \(username)")
        _ = try await transport.request("PASSWORD \(password)")
        let loginReply = try await transport.request("LOGIN \(ups)")
        guard let line = loginReply.first else { throw NUTError.malformed("empty LOGIN reply") }
        do {
            try NUTProtocol.checkSimpleReply(line)
            return true
        } catch NUTError.server(let code) where code == "ACCESS-DENIED" {
            return false
        }
    }
}
