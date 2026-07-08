import Foundation
import Testing
@testable import SafeHaltCore

/// 真机集成测试：仅当设置 SAFEHALT_NUT_HOST 时运行。
/// 用法：SAFEHALT_NUT_HOST=192.168.1.100 ./test.sh --filter NUTSocketSessionIntegrationTests
/// 凭据用例额外需要 SAFEHALT_NUT_USER / SAFEHALT_NUT_PASS。
private let env = ProcessInfo.processInfo.environment
private let nutHost = env["SAFEHALT_NUT_HOST"]

struct NUTSocketSessionIntegrationTests {
    @Test(.enabled(if: nutHost != nil, "未设置 SAFEHALT_NUT_HOST，跳过真机测试"))
    func multipleCommandsOverOneConnection() async throws {
        let session = NUTSocketSession(host: nutHost!, port: 3493)
        let client = NUTClient(transport: session)
        let ups = try await client.listUPS()
        #expect(!ups.isEmpty)
        let vars = try await client.readAllVars(ups: ups[0])   // 同一连接第二条命令
        #expect(vars["ups.status"] != nil)
        await session.close()
    }

    @Test(.enabled(if: nutHost != nil, "未设置 SAFEHALT_NUT_HOST，跳过真机测试"))
    func wrongCredentialIsRejected() async throws {
        let session = NUTSocketSession(host: nutHost!, port: 3493)
        let client = NUTClient(transport: session)
        let ups = try await client.listUPS()
        let ok = try? await client.testLogin(ups: ups[0], username: "wrong", password: "bad")
        #expect(ok != true, "错误凭据不应登录成功")
        await session.close()
    }

    @Test(.enabled(if: nutHost != nil && env["SAFEHALT_NUT_USER"] != nil,
                   "未设置 SAFEHALT_NUT_USER/SAFEHALT_NUT_PASS，跳过凭据用例"))
    func correctCredentialLogsIn() async throws {
        let session = NUTSocketSession(host: nutHost!, port: 3493)
        let client = NUTClient(transport: session)
        let ups = try await client.listUPS()
        let ok = try await client.testLogin(
            ups: ups[0], username: env["SAFEHALT_NUT_USER"]!, password: env["SAFEHALT_NUT_PASS"]!)
        #expect(ok, "正确凭据应登录成功（LOGIN 会占一个会话槽，断开即释放）")
        await session.close()
    }

    /// 回归：actor 可重入曾导致并发请求在同一连接上交错、回复串线。
    /// 串线时 readAllVars 会拿到 NUMLOGINS 的单行应答而解析失败。
    @Test(.enabled(if: nutHost != nil, "未设置 SAFEHALT_NUT_HOST，跳过真机测试"))
    func concurrentRequestsDoNotCrossWires() async throws {
        let session = NUTSocketSession(host: nutHost!, port: 3493)
        let client = NUTClient(transport: session)
        let ups = try await client.listUPS().first ?? "ups"
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    let vars = try await client.readAllVars(ups: ups)
                    #expect(vars["ups.status"] != nil)
                }
                group.addTask {
                    let n = try await client.numLogins(ups: ups)
                    #expect(n >= 0)
                }
            }
            try await group.waitForAll()
        }
        await session.close()
    }
}
