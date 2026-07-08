import Foundation

public struct NUTVariable: Equatable {
    public let ups: String
    public let name: String
    public let value: String
    public init(ups: String, name: String, value: String) {
        self.ups = ups; self.name = name; self.value = value
    }
}

public enum NUTError: Error, Equatable {
    case server(String)      // ERR <code>
    case malformed(String)   // 无法解析的行
}

public enum NUTProtocol {

    /// 提取双引号包裹的值（可含空格）。返回 (引号前的 token 数组, 引号内的值)。
    private static func splitQuoted(_ line: String) -> (tokens: [String], quoted: String?) {
        guard let firstQuote = line.firstIndex(of: "\""),
              let lastQuote = line.lastIndex(of: "\""),
              firstQuote < lastQuote else {
            return (line.split(separator: " ").map(String.init), nil)
        }
        let before = String(line[line.startIndex..<firstQuote])
            .split(separator: " ").map(String.init)
        let inner = String(line[line.index(after: firstQuote)..<lastQuote])
        return (before, inner)
    }

    public static func parseUPSList(_ lines: [String]) throws -> [String] {
        var result: [String] = []
        for line in lines {
            if line.hasPrefix("BEGIN LIST") || line.hasPrefix("END LIST") { continue }
            if line.hasPrefix("ERR") {
                throw NUTError.server(line.replacingOccurrences(of: "ERR ", with: ""))
            }
            let (tokens, _) = splitQuoted(line)
            guard tokens.count >= 2, tokens[0] == "UPS" else {
                throw NUTError.malformed(line)
            }
            result.append(tokens[1])
        }
        return result
    }

    public static func parseVarLine(_ line: String) throws -> NUTVariable {
        if line.hasPrefix("ERR") {
            throw NUTError.server(line.replacingOccurrences(of: "ERR ", with: ""))
        }
        let (tokens, quoted) = splitQuoted(line)
        guard tokens.count >= 3, tokens[0] == "VAR", let value = quoted else {
            throw NUTError.malformed(line)
        }
        return NUTVariable(ups: tokens[1], name: tokens[2], value: value)
    }

    public static func parseVarList(_ lines: [String]) throws -> [String: String] {
        var dict: [String: String] = [:]
        for line in lines {
            if line.hasPrefix("BEGIN LIST") || line.hasPrefix("END LIST") { continue }
            if line.isEmpty { continue }
            let v = try parseVarLine(line)
            dict[v.name] = v.value
        }
        return dict
    }

    public static func parseNumLogins(_ line: String) throws -> Int {
        if line.hasPrefix("ERR") {
            throw NUTError.server(line.replacingOccurrences(of: "ERR ", with: ""))
        }
        let tokens = line.split(separator: " ").map(String.init)
        guard tokens.count == 3, tokens[0] == "NUMLOGINS", let n = Int(tokens[2]) else {
            throw NUTError.malformed(line)
        }
        return n
    }

    public static func checkSimpleReply(_ line: String) throws {
        if line == "OK" { return }
        if line.hasPrefix("ERR") {
            throw NUTError.server(line.replacingOccurrences(of: "ERR ", with: ""))
        }
        throw NUTError.malformed(line)
    }
}
