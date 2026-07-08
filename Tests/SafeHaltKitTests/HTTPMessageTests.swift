import Foundation
import Testing
@testable import SafeHaltKit

struct HTTPMessageTests {
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test func parsesGetWithQuery() throws {
        let raw = bytes("GET /log?n=20 HTTP/1.1\r\nHost: x\r\n\r\n")
        guard case .ok(let req) = try HTTPParser.parse(raw) else { Issue.record("应解析完成"); return }
        #expect(req.method == "GET")
        #expect(req.path == "/log")
        #expect(req.query["n"] == "20")
        #expect(req.headers["host"] == "x")
        #expect(req.body.isEmpty)
    }

    @Test func parsesPostWithJSONBody() throws {
        let json = #"{"a":1}"#
        let raw = bytes("POST /config HTTP/1.1\r\nContent-Length: \(json.utf8.count)\r\nContent-Type: application/json\r\n\r\n\(json)")
        guard case .ok(let req) = try HTTPParser.parse(raw) else { Issue.record("应解析完成"); return }
        #expect(req.method == "POST")
        #expect(req.path == "/config")
        #expect(String(data: req.body, encoding: .utf8) == json)
    }

    @Test func incompleteWhenBodyShorterThanContentLength() throws {
        let raw = bytes("POST /config HTTP/1.1\r\nContent-Length: 10\r\n\r\nab")
        guard case .incomplete = try HTTPParser.parse(raw) else { Issue.record("应报未完成"); return }
    }

    @Test func incompleteWhenHeadersUnterminated() throws {
        let raw = bytes("GET /status HTTP/1.1\r\nHost: x")
        guard case .incomplete = try HTTPParser.parse(raw) else { Issue.record("应报未完成"); return }
    }

    @Test func malformedRequestLineThrows() {
        let raw = bytes("GARBAGE\r\n\r\n")
        #expect(throws: HTTPRequestParseError.self) { try HTTPParser.parse(raw) }
    }

    @Test func invalidContentLengthThrows() {
        let raw = bytes("POST /config HTTP/1.1\r\nContent-Length: abc\r\n\r\n{\"a\":1}")
        #expect(throws: HTTPRequestParseError.self) { try HTTPParser.parse(raw) }
    }

    @Test func headerWithoutColonThrows() {
        let raw = bytes("GET /status HTTP/1.1\r\nBadHeaderLine\r\n\r\n")
        #expect(throws: HTTPRequestParseError.self) { try HTTPParser.parse(raw) }
    }

    @Test func authorizationHeaderLowercased() throws {
        let raw = bytes("GET /status HTTP/1.1\r\nAuthorization: Bearer abc\r\n\r\n")
        guard case .ok(let req) = try HTTPParser.parse(raw) else { Issue.record("应解析完成"); return }
        #expect(req.headers["authorization"] == "Bearer abc")
    }

    @Test func responseSerializesStatusAndBody() {
        let body = bytes(#"{"ok":true}"#)
        let out = HTTPResponse.json(200, body).serialized()
        let text = String(data: out, encoding: .utf8)!
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n"))
        #expect(text.contains("Content-Length: \(body.count)\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n" + #"{"ok":true}"#))
    }

    @Test func responseSerializesExactWireFormat() {
        let bodyString = #"{"ok":true}"#
        let body = bytes(bodyString)
        #expect(body.count == 11)
        let out = HTTPResponse.json(200, body).serialized()
        let text = String(data: out, encoding: .utf8)!
        #expect(text == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}")
    }

    @Test func errorResponseWrapsMessage() {
        let out = HTTPResponse.error(401, "需要配对").serialized()
        let text = String(data: out, encoding: .utf8)!
        #expect(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        #expect(text.contains(#""error""#))
        #expect(text.contains("需要配对"))
    }
}
