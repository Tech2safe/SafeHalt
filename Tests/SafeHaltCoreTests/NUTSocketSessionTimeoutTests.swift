import Foundation
import Network
import Testing
@testable import SafeHaltCore

/// 只收连接、永不回话的本地桩：验证会话请求超时优雅抛错（修复前会永久挂起）。
struct NUTSocketSessionTimeoutTests {
    @Test func silentServerTimesOutGracefully() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { conn in conn.start(queue: .global()) }
        listener.start(queue: .global())
        var port: UInt16 = 0
        for _ in 0..<50 {
            if let p = listener.port?.rawValue, p > 0 { port = p; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(port > 0, "本地监听桩应能拿到端口")
        let session = NUTSocketSession(host: "127.0.0.1", port: Int(port), requestTimeout: 1)
        await #expect(throws: (any Error).self) {
            _ = try await session.request("LIST UPS")
        }
        await session.close()
        listener.cancel()
    }
}
