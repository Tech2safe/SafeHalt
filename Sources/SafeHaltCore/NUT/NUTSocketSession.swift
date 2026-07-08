import Foundation
import Network

/// 会话式 NUT 传输：一条 TCP 连接上串行发送多条命令。
/// upsd 按连接记会话状态，USERNAME/PASSWORD/LOGIN 必须走同一连接——
/// 这是 NUTClient.testLogin 唯一可用的传输方式（一次性传输每请求新建连接，会话状态丢失）。
///
/// 注意：串行化闸门保证的是**命令级**顺序，非事务级。testLogin 的三条命令若与
/// 其他并发命令共用同一 session 会被插队；本工程每次 testLogin 用独立 session，无此问题。
/// Phase 4 若跨多处共享一个 session，需引入批量/事务 API。
public actor NUTSocketSession: NUTTransport {
    private let host: String
    private let port: Int
    private let requestTimeout: TimeInterval
    private let queue = DispatchQueue(label: "safehalt.nut.session")
    private var connection: NWConnection?
    private var buffer = ""
    /// 串行化闸门：actor 在 await 悬挂点可重入，并发 request 必须显式排队，
    /// 否则两个调用会在同一连接/缓冲上交错，把彼此的回复拿错。
    private var tail: Task<Void, Never>?

    public init(host: String, port: Int, requestTimeout: TimeInterval = 10) {
        self.host = host
        self.port = port
        self.requestTimeout = requestTimeout
    }

    public func request(_ command: String) async throws -> [String] {
        let previous = tail
        let task = Task<[String], Error> { [weak self] in
            _ = await previous?.value          // 排在上一个请求之后
            guard let self else { throw NUTError.malformed("会话已释放") }
            return try await self.performRequest(command)
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    public func close() {
        connection?.cancel()
        connection = nil
        buffer = ""
    }

    /// 兜底释放：探测/登录场景常直接丢弃 session 不显式 close()，
    /// 若不在此取消，连接会被超时定时器一直持有到期才关，期间占用 upsd 登录槽。
    deinit { connection?.cancel() }

    /// 单条命令的完整往返。任何建连/发送/接收错误都会重置连接（下次请求自愈重连）。
    private func performRequest(_ command: String) async throws -> [String] {
        do {
            let conn = try await ensureConnection()

            let payload = (command + "\r\n").data(using: .utf8)!
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.send(content: payload, completion: .contentProcessed { error in
                    if let error = error { cont.resume(throwing: error) } else { cont.resume() }
                })
            }

            let isList = NUTFraming.isListCommand(command)
            while true {
                if let reply = try NUTFraming.extractReply(from: buffer, isList: isList) {
                    buffer = reply.remainder
                    return reply.lines
                }
                // 带超时的单次 resume：timeout 回调与 receive 完成回调都在同一串行 queue 上，
                // resumed 标记无竞争；超时抛错后外层 catch 会 close() 防止残余应答串线。
                let chunk: String = try await withCheckedThrowingContinuation { cont in
                    var resumed = false
                    let finish: (Result<String, Error>) -> Void = { result in
                        guard !resumed else { return }
                        resumed = true
                        cont.resume(with: result)
                    }
                    queue.asyncAfter(deadline: .now() + requestTimeout) {
                        finish(.failure(NUTError.malformed("等待服务器响应超时")))
                    }
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                        if let error { finish(.failure(error)); return }
                        finish(.success(data.flatMap { String(data: $0, encoding: .utf8) } ?? ""))
                    }
                }
                if chunk.isEmpty {
                    throw NUTError.malformed("连接被服务器关闭")
                }
                buffer += chunk
            }
        } catch {
            close()
            throw error
        }
    }

    private func ensureConnection() async throws -> NWConnection {
        if let connection { return connection }
        // 端口守卫：UInt16(port) 是陷阱转换，超范围会崩（Phase 2 最终审查的 Critical 教训）
        guard let portNumber = UInt16(exactly: port), portNumber > 0 else {
            throw NUTError.malformed("端口无效: \(port)")
        }
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: portNumber)!,
            using: .tcp)
        do {
            // 等待就绪同样带超时：handler 与超时回调同在实例串行 queue 上，resumed 标记无竞争。
            // handler 必须在 start 之前装好，否则极端情况下 .ready 可能在装 handler 前就到达而漏掉。
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                var resumed = false
                let finish: (Result<Void, Error>) -> Void = { result in
                    guard !resumed else { return }
                    resumed = true
                    conn.stateUpdateHandler = nil
                    cont.resume(with: result)
                }
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(.success(()))
                    case .failed(let e): finish(.failure(e))
                    case .waiting(let e): finish(.failure(e))
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + requestTimeout) {
                    finish(.failure(NUTError.malformed("连接超时")))
                }
                conn.start(queue: queue)
            }
        } catch {
            conn.cancel()
            throw error
        }
        connection = conn
        return conn
    }
}
