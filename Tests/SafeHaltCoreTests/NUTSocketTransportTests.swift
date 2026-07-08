import Testing
@testable import SafeHaltCore

struct NUTSocketTransportTests {
    /// 127.0.0.1:1 无监听者，连接被拒。修复前此路径存在重复 resume 崩溃风险；
    /// 本测试锁定"优雅抛错"的行为。
    @Test func refusedConnectionThrowsGracefully() async {
        let transport = NUTSocketTransport(host: "127.0.0.1", port: 1)
        await #expect(throws: (any Error).self) {
            _ = try await transport.request("LIST UPS")
        }
    }

    /// 端口超范围必须优雅抛错（曾是 UInt16 陷阱转换崩溃 + 坏值落盘后的重启崩溃循环）。
    @Test func invalidPortThrowsGracefully() async {
        let transport = NUTSocketTransport(host: "127.0.0.1", port: 99999)
        await #expect(throws: (any Error).self) {
            _ = try await transport.request("LIST UPS")
        }
    }
}
