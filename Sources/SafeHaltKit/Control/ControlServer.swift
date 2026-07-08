import Foundation
import Network

public enum ControlServerError: Error, Equatable {
    /// 监听器在到达 .ready 前被取消（未真正启动即被 stop()）。
    case cancelledBeforeReady
}

/// 只绑 127.0.0.1 的极简 HTTP 控制服务端（每连接一请求，Connection: close）。
/// 安全：崩溃/阻塞绝不能影响守护进程主循环——本类独立于 DaemonRunner，经 actor 隔离。
public actor ControlServer {
    private let port: UInt16
    private let router: ControlRouter
    private var listener: NWListener?

    public init(port: UInt16, router: ControlRouter) {
        self.port = port; self.router = router
    }

    /// 启动并等待监听器就绪（`.ready`）后再返回——`port: 0` 时系统分配的真实端口
    /// 只有到达 `.ready` 状态后 `listener.port` 才会反映出来，故此处不能提前返回，
    /// 否则 `boundPort()` 会读到请求端口（0）而非实际绑定端口。
    public func start() async throws {
        let params = NWParameters.tcp
        // 只绑环回地址——外网/局域网无法连入
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                 port: NWEndpoint.Port(rawValue: port) ?? .any)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [router] conn in
            ControlServer.serve(conn, router: router)
        }
        listener = l
        // 与 NUTSocketTransport 同一套「等就绪」写法：状态回调触发一次即置 nil，防止重复 resume。
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            l.stateUpdateHandler = { [weak l] state in
                switch state {
                case .ready:
                    l?.stateUpdateHandler = nil
                    cont.resume(returning: ())
                case .failed(let err):
                    l?.stateUpdateHandler = nil
                    cont.resume(throwing: err)
                case .cancelled:
                    l?.stateUpdateHandler = nil
                    cont.resume(throwing: ControlServerError.cancelledBeforeReady)
                default:
                    break
                }
            }
            l.start(queue: .global(qos: .utility))
        }
    }

    public func boundPort() -> UInt16? {
        listener?.port?.rawValue
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // 单连接生命周期：累积字节 → 解析 → 路由 → 回写 → 关闭。
    private static func serve(_ conn: NWConnection, router: ControlRouter) {
        conn.start(queue: .global(qos: .utility))
        receive(conn, buffer: Data(), router: router)
    }

    private static func receive(_ conn: NWConnection, buffer: Data, router: ControlRouter) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buf = buffer
            if let data { buf.append(data) }
            do {
                switch try HTTPParser.parse(buf) {
                case .ok(let req):
                    Task {
                        let resp = await router.handle(req)
                        conn.send(content: resp.serialized(),
                                  completion: .contentProcessed { _ in conn.cancel() })
                    }
                case .incomplete:
                    if isComplete || error != nil { conn.cancel() }
                    else { receive(conn, buffer: buf, router: router) }
                }
            } catch {
                conn.send(content: HTTPResponse.error(400, "请求格式错误").serialized(),
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }
}
