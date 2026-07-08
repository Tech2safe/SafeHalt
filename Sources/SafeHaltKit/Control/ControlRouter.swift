import Foundation

/// 端点路由 + 鉴权。纯粹依赖注入，可脱离 socket 单测。
/// 安全：除 /ping /pair 外均需 Bearer 令牌;/status 等含敏感目标信息故必须鉴权。
public struct ControlRouter {
    private let engine: EngineControl
    private let pairing: PairingStore
    private let random: RandomBytes
    private let now: @Sendable () -> Date
    private let touchCancel: @Sendable () -> Void

    public init(engine: EngineControl, pairing: PairingStore,
                random: @escaping RandomBytes,
                now: @escaping @Sendable () -> Date,
                touchCancel: @escaping @Sendable () -> Void) {
        self.engine = engine; self.pairing = pairing; self.random = random
        self.now = now; self.touchCancel = touchCancel
    }

    public func handle(_ req: HTTPRequest) async -> HTTPResponse {
        switch (req.method, req.path) {
        case ("GET", "/ping"):
            return ping()
        case ("POST", "/pair"):
            return pair(req)
        default:
            guard authorized(req) else { return .error(401, "需要配对或令牌无效") }
            switch (req.method, req.path) {
            case ("POST", "/config"): return await applyConfig(req)
            case ("GET", "/status"):  return await status()
            case ("POST", "/cancel"): touchCancel(); return ok()
            case ("GET", "/log"):     return await log(req)
            default:                  return .error(404, "未知端点")
            }
        }
    }

    // MARK: 端点

    private func ping() -> HTTPResponse {
        let state = pairing.load()
        let obj: [String: Any] = [
            "installed": true,
            "paired": state?.tokenHash != nil,
            "configured": false  // 免鉴权不暴露引擎细节；配置态经鉴权后的 /status 获取
        ]
        return json(200, obj)
    }

    private func pair(_ req: HTTPRequest) -> HTTPResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let code = obj["code"] as? String else {
            return .error(400, "缺少 code")
        }
        guard let token = try? Pairing.redeem(store: pairing, submittedCode: code, random: random) else {
            return .error(401, "配对码不正确")
        }
        return json(200, ["token": token])
    }

    private func applyConfig(_ req: HTTPRequest) async -> HTTPResponse {
        do {
            let cfg = try DaemonConfig.load(data: req.body)
            await engine.applySettings(cfg)
            return ok()
        } catch let e as DaemonConfigError {
            if case .invalid(let msg) = e { return .error(400, msg) }
            return .error(400, "配置非法")
        } catch {
            return .error(400, "配置解析失败")
        }
    }

    private func status() async -> HTTPResponse {
        let st = await engine.currentStatus(now: now())
        guard let data = try? JSONEncoder().encode(st) else { return .error(500, "编码失败") }
        return .json(200, data)
    }

    private func log(_ req: HTTPRequest) async -> HTTPResponse {
        let n = min(100, max(1, req.query["n"].flatMap { Int($0) } ?? 50))
        let events = await engine.recentEvents(limit: n)
        guard let data = try? JSONEncoder().encode(events) else { return .error(500, "编码失败") }
        return .json(200, data)
    }

    // MARK: 辅助

    private func authorized(_ req: HTTPRequest) -> Bool {
        guard let auth = req.headers["authorization"], auth.hasPrefix("Bearer ") else { return false }
        let token = String(auth.dropFirst("Bearer ".count))
        return Pairing.verifyToken(store: pairing, bearer: token)
    }

    private func ok() -> HTTPResponse { json(200, ["ok": true]) }

    private func json(_ status: Int, _ obj: [String: Any]) -> HTTPResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else {
            return .error(500, "编码失败")
        }
        return .json(status, data)
    }
}
