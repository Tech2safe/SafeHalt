/// NUT 报文分帧：从字节流缓冲里切出"一条命令的完整回复"。
/// 供一次性传输（NUTSocketTransport）与会话式传输（NUTSocketSession）共用。
public enum NUTFraming {
    public static func isListCommand(_ command: String) -> Bool {
        command.hasPrefix("LIST")
    }

    /// 提取一条完整回复。
    /// - isList: true 时读到 "END LIST" 行或 "ERR" 行为止；false 时取第一行非空行。
    /// - 返回 nil 表示缓冲里还没有完整回复，需继续接收。
    /// - lines 已去掉空行与 \r；remainder 为回复之后的剩余内容。
    public static func extractReply(from buffer: String, isList: Bool) throws -> (lines: [String], remainder: String)? {
        let normalized = buffer.replacingOccurrences(of: "\r", with: "")
        var pieces = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // split 保尾：最后一段是尚未以 \n 结尾的残段（可能为空串）
        let tail = pieces.removeLast()
        var consumed: [String] = []
        for (i, line) in pieces.enumerated() {
            if line.isEmpty { continue }
            consumed.append(line)
            let isTerminator = isList
                ? (line.hasPrefix("END LIST") || line.hasPrefix("ERR"))
                : true
            if isTerminator {
                let rest = pieces[(i + 1)...] + [tail]
                return (consumed, rest.joined(separator: "\n"))
            }
        }
        return nil
    }
}
