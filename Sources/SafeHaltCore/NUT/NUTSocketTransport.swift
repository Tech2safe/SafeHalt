import Foundation
import Network

public final class NUTSocketTransport: NUTTransport, @unchecked Sendable {
    private let host: String
    private let port: Int
    public init(host: String, port: Int) { self.host = host; self.port = port }

    public func request(_ command: String) async throws -> [String] {
        guard let portNumber = UInt16(exactly: port), portNumber > 0 else {
            throw NUTError.malformed("端口无效: \(port)")
        }
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: portNumber)!,
            using: .tcp)
        let queue = DispatchQueue(label: "safehalt.nut.socket")
        conn.start(queue: queue)
        // 提前注册：连接失败抛错路径也必须 cancel，长期轮询不可泄漏连接
        defer { conn.cancel() }

        // 等待就绪
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [weak conn] state in
                switch state {
                case .ready:
                    conn?.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let e):
                    conn?.stateUpdateHandler = nil
                    cont.resume(throwing: e)
                case .waiting(let e):
                    conn?.stateUpdateHandler = nil
                    cont.resume(throwing: e)
                default: break
                }
            }
        }

        // 发送命令
        let payload = (command + "\r\n").data(using: .utf8)!
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: payload, completion: .contentProcessed { error in
                if let error = error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }

        // 接收直到取出一条完整回复（分帧逻辑在 NUTFraming，与会话式传输共用）
        let isList = NUTFraming.isListCommand(command)
        var buffer = ""
        while true {
            if let reply = try NUTFraming.extractReply(from: buffer, isList: isList) {
                return reply.lines
            }
            let chunk: String = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error = error { cont.resume(throwing: error); return }
                    cont.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                    _ = isComplete
                }
            }
            if chunk.isEmpty {
                // 连接关闭：把已有缓冲整体按行返回（与旧行为一致）
                return buffer.replacingOccurrences(of: "\r", with: "")
                    .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            }
            buffer += chunk
        }
    }
}
