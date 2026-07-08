import Foundation

/// 极简 HTTP/1.1 请求（控制 API 用；每连接一请求，Connection: close）。
public struct HTTPRequest: Equatable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]   // 键统一小写
    public let body: Data
}

public enum HTTPParseResult { case incomplete; case ok(HTTPRequest) }
public enum HTTPRequestParseError: Error, Equatable { case malformed(String) }

public enum HTTPParser {
    /// 解析累积字节。头部未收全或 body 不足 Content-Length → .incomplete（继续读）；
    /// 请求行/头部格式非法 → 抛 .malformed。
    public static func parse(_ data: Data) throws -> HTTPParseResult {
        let sep = Data("\r\n\r\n".utf8)
        guard let headEnd = range(of: sep, in: data) else { return .incomplete }
        let headData = data.subdata(in: data.startIndex..<headEnd.lowerBound)
        guard let headText = String(data: headData, encoding: .utf8) else {
            throw HTTPRequestParseError.malformed("头部非 UTF-8")
        }
        var lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            throw HTTPRequestParseError.malformed("空请求行")
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else {
            throw HTTPRequestParseError.malformed("请求行格式错误：\(requestLine)")
        }
        let method = String(parts[0])
        let target = String(parts[1])
        let (path, query) = splitTarget(target)

        lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw HTTPRequestParseError.malformed("头部行缺冒号：\(line)")
            }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headEnd.upperBound
        let available = data.subdata(in: bodyStart..<data.endIndex)
        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        if available.count < contentLength { return .incomplete }
        let body = contentLength > 0 ? available.subdata(in: available.startIndex..<available.index(available.startIndex, offsetBy: contentLength)) : Data()

        return .ok(HTTPRequest(method: method, path: path, query: query, headers: headers, body: body))
    }

    private static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[target.startIndex..<q])
        var query: [String: String] = [:]
        for pair in target[target.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { query[String(kv[0])] = String(kv[1]) }
            else if kv.count == 1 { query[String(kv[0])] = "" }
        }
        return (path, query)
    }

    private static func range(of needle: Data, in haystack: Data) -> Range<Data.Index>? {
        haystack.range(of: needle)
    }
}

public struct HTTPResponse {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }

    public static func json(_ status: Int, _ body: Data) -> HTTPResponse {
        HTTPResponse(status: status, body: body)
    }
    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        let safe = message.replacingOccurrences(of: "\"", with: "'")
        return HTTPResponse(status: status, body: Data("{\"error\":\"\(safe)\"}".utf8))
    }

    public func serialized() -> Data {
        var out = Data("HTTP/1.1 \(status) \(Self.reason(status))\r\n".utf8)
        out.append(Data("Content-Type: application/json\r\n".utf8))
        out.append(Data("Content-Length: \(body.count)\r\n".utf8))
        out.append(Data("Connection: close\r\n".utf8))
        out.append(Data("\r\n".utf8))
        out.append(body)
        return out
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
