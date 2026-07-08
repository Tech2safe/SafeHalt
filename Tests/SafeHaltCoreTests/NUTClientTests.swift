import Testing
@testable import SafeHaltCore

/// 可编程的假传输：按命令前缀返回预设响应。
final class MockTransport: NUTTransport {
    var responses: [String: [String]] = [:]
    private(set) var sent: [String] = []
    func request(_ command: String) async throws -> [String] {
        sent.append(command)
        for (prefix, reply) in responses where command.hasPrefix(prefix) {
            return reply
        }
        return []
    }
}

struct NUTClientTests {
    @Test func listUPS() async throws {
        let t = MockTransport()
        t.responses["LIST UPS"] = ["BEGIN LIST UPS", "UPS ups \"x\"", "END LIST UPS"]
        let client = NUTClient(transport: t)
        let ups = try await client.listUPS()
        #expect(ups == ["ups"])
    }

    @Test func readAllVars() async throws {
        let t = MockTransport()
        t.responses["LIST VAR ups"] = [
            "BEGIN LIST VAR ups",
            "VAR ups battery.charge \"100\"",
            "VAR ups ups.status \"OL\"",
            "END LIST VAR ups"
        ]
        let client = NUTClient(transport: t)
        let vars = try await client.readAllVars(ups: "ups")
        #expect(vars["battery.charge"] == "100")
    }

    @Test func numLogins() async throws {
        let t = MockTransport()
        t.responses["GET NUMLOGINS ups"] = ["NUMLOGINS ups 2"]
        let client = NUTClient(transport: t)
        let n = try await client.numLogins(ups: "ups")
        #expect(n == 2)
    }

    @Test func loginSuccess() async throws {
        let t = MockTransport()
        t.responses["USERNAME"] = ["OK"]
        t.responses["PASSWORD"] = ["OK"]
        t.responses["LOGIN"] = ["OK"]
        let client = NUTClient(transport: t)
        let ok = try await client.testLogin(ups: "ups", username: "monuser", password: "changeme")
        #expect(ok)
    }

    @Test func loginAccessDenied() async throws {
        let t = MockTransport()
        t.responses["USERNAME"] = ["OK"]
        t.responses["PASSWORD"] = ["OK"]
        t.responses["LOGIN"] = ["ERR ACCESS-DENIED"]
        let client = NUTClient(transport: t)
        let ok = try await client.testLogin(ups: "ups", username: "monuser", password: "bad")
        #expect(!ok)
    }
}
