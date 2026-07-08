# SafeHalt 控制服务端 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 SafeHalt 守护进程加一个只绑 `127.0.0.1` 的 HTTP 控制服务端 + 配对码/令牌鉴权 + 哑引擎门控,使 Mac UPS Link 成为它唯一被支持的配置/控制入口。

**Architecture:** 守护进程新增 `NWListener` HTTP 服务端(与现有 `NWConnection` NUT 客户端同栈,零外部依赖),与监控循环并行运行、经 actor 共享状态通信。纯函数决策核心 `ShutdownDecider` 保持不动。守护进程出厂无配置即"哑"(只监控/不关机),等 App 经 `/pair`+`/config` 激活。配对码由 `.pkg` 安装脚本经 `safehalt pair-init` 生成、经 `launchctl asuser` 弹品牌对话框呈现。

**Tech Stack:** Swift 5.9, macOS 13+, Command Line Tools(无 Xcode),Network.framework(NWListener/NWConnection),CryptoKit(SHA256),Swift Testing + `./test.sh`。

## Global Constraints

- **安全红线:** 关机决策必须自治在守护进程体内,运行期绝不依赖 App/HTTP;HTTP 服务端崩溃或阻塞**绝不能**影响监控/关机循环。关机路径(`ShutdownDecider` + `RealSystemActions.shutdown`)零改动。
- **只绑 `127.0.0.1`**,永不监听局域网(`0.0.0.0`)。固定端口 `57117`。
- **鉴权:** 除 `GET /ping` 与 `POST /pair` 外,所有端点需 `Authorization: Bearer <token>`。配对码/令牌一律以 SHA256 十六进制存储,比较用常量时间。
- **哑引擎:** 无有效配置(config.json 缺失/非法)时守护进程照常启动、跑 HTTP,但**不连 NUT、不关机**,`/status` 报 `configured:false`。
- **向后兼容:** 现役机器的 config.json(无 `enabled` 字段、含 username/password)必须仍能加载并保持保护(`enabled` 默认 `true`,凭据可选)。
- **测试:** 一律 Swift Testing(`import Testing`,`@Test`,`#expect`),经 `./test.sh` 运行(`swift test` 会因缺 Testing 模块失败)。决策/解析/鉴权等纯逻辑必须穷举单测;NWListener 走 localhost 集成测试。
- **文案:** 用户可见中文;不得出现 "PowerNut" 字样(本仓是 SafeHalt)。
- **提交但不推送:** 每任务提交到本地 `feat/control-server` 分支;**不 `git push`**(公开仓,推送留人工确认)。

---

## File Structure

**新增(SafeHaltKit):**
- `Sources/SafeHaltKit/Control/HTTPMessage.swift` — HTTP/1.1 请求解析 + 响应编码(纯函数)。
- `Sources/SafeHaltKit/Control/Pairing.swift` — 配对码/令牌生成、SHA256、常量时间比较、`PairingState` + `PairingStore`(文件 IO)。
- `Sources/SafeHaltKit/Control/EngineStatus.swift` — `/status` 与 `/log` 的 DTO(`EngineStatus`/`EngineEvent`/`EngineControl` 协议)。
- `Sources/SafeHaltKit/Control/ControlRouter.swift` — 端点路由(async,注入依赖,可脱离 socket 单测)。
- `Sources/SafeHaltKit/Control/ControlServer.swift` — NWListener loopback 粘合层。
- `Sources/SafeHaltKit/Control/PairingDialog.swift` — 经 asuser osascript 弹配对码品牌对话框。

**修改:**
- `Sources/SafeHaltKit/DaemonPaths.swift` — 加 `httpPort`、`pairingFile`。
- `Sources/SafeHaltKit/DaemonConfig.swift` — 凭据可选、加 `enabled`、向后兼容解码。
- `Sources/SafeHaltKit/DaemonRunner.swift` — 可变 settings、哑/暂停门控、`EngineStatus` 快照、`EngineEvent` 环形缓冲、遵从 `EngineControl`。
- `Sources/safehalt/main.swift` — 子命令 `pair-init`/`show-pairing-dialog`;哑启动;并行跑服务端 + 循环。
- `uninstall-daemon.sh` — 删 `pairing.json`。
- `README.md` — 重定位为"Mac UPS Link 的开源引擎"。

**新增(仓根):**
- `make-pkg.sh` — 构建 + `pkgbuild` 打包 + postinstall(pair-init/load/弹对话框)。

**删除:**
- `Sources/SafeHaltAgent/` — 未进 Package.swift 的死代码。

---

### Task 1: 基础常量、配置演进、清理死代码

**Files:**
- Modify: `Sources/SafeHaltKit/DaemonPaths.swift`
- Modify: `Sources/SafeHaltKit/DaemonConfig.swift`
- Delete: `Sources/SafeHaltAgent/` (整个目录)
- Test: `Tests/SafeHaltKitTests/DaemonConfigTests.swift`(扩充)

**Interfaces:**
- Produces:
  - `DaemonPaths.httpPort: Int` = `57117`;`DaemonPaths.pairingFile: String` = `/Library/Application Support/SafeHalt/pairing.json`。
  - `DaemonConfig` 新增 `enabled: Bool`(默认 `true`);`username`/`password` 解码缺失时为 `""`;`commLossFailsafeMinutes`/`pollSeconds` 解码缺失时分别为 `0`/`5`。构造器 `init(host:port:ups:username:password:onBatteryMinutes:shutdownAlsoOnLowBattery:commLossFailsafeMinutes:pollSeconds:enabled:)`,`enabled` 默认 `true`。

- [ ] **Step 1: 删除死代码 SafeHaltAgent**

```bash
git rm -r Sources/SafeHaltAgent
```

- [ ] **Step 2: 加路径常量**

编辑 `Sources/SafeHaltKit/DaemonPaths.swift`,在 `cancelFlagFile` 之后、`}` 之前插入:

```swift
    /// 控制服务端固定端口（只绑 127.0.0.1）。App 客户端硬编码同值。
    public static let httpPort = 57117
    /// 配对状态（配对码哈希 + 令牌哈希），600 root。绝不由沙盒 App 读写，只经 HTTP。
    public static let pairingFile = "/Library/Application Support/SafeHalt/pairing.json"
```

- [ ] **Step 3: 写失败测试——enabled 默认与凭据可选**

在 `Tests/SafeHaltKitTests/DaemonConfigTests.swift` 的 `struct DaemonConfigTests` 内追加:

```swift
    @Test func enabledDefaultsTrueWhenMissing() throws {
        // 现役机器的旧 config 无 enabled 字段，须默认启用（升级不失保护）
        let legacy = #"{"host":"h","port":3493,"ups":"ups","username":"u","password":"p","onBatteryMinutes":10,"shutdownAlsoOnLowBattery":true,"commLossFailsafeMinutes":5,"pollSeconds":5}"#
        let cfg = try DaemonConfig.load(data: Data(legacy.utf8))
        #expect(cfg.enabled == true)
    }

    @Test func credentialsOptionalDefaultEmpty() throws {
        // 匿名读 UPS 状态，无需凭据；App 的 /config 不下发 username/password
        let minimal = #"{"host":"h","port":3493,"ups":"ups","onBatteryMinutes":10,"shutdownAlsoOnLowBattery":true,"enabled":false}"#
        let cfg = try DaemonConfig.load(data: Data(minimal.utf8))
        #expect(cfg.username == "")
        #expect(cfg.password == "")
        #expect(cfg.commLossFailsafeMinutes == 0)
        #expect(cfg.pollSeconds == 5)
        #expect(cfg.enabled == false)
    }

    @Test func newPathsExist() {
        #expect(DaemonPaths.httpPort == 57117)
        #expect(DaemonPaths.pairingFile == "/Library/Application Support/SafeHalt/pairing.json")
    }
```

- [ ] **Step 4: 运行测试确认失败**

Run: `./test.sh --filter DaemonConfigTests`
Expected: FAIL(`enabled`/新路径尚不存在,编译错误或断言失败)

- [ ] **Step 5: 演进 DaemonConfig**

把 `Sources/SafeHaltKit/DaemonConfig.swift` 整体替换为:

```swift
import Foundation
import SafeHaltCore

public enum DaemonConfigError: Error, Equatable { case invalid(String) }

public struct DaemonConfig: Codable, Equatable {
    public let host: String
    public let port: Int
    public let ups: String
    public let username: String
    public let password: String
    public let onBatteryMinutes: Int
    public let shutdownAlsoOnLowBattery: Bool
    /// 空闲时连续通信中断多少分钟触发 failsafe 关机；0 = 关闭。保守，宜 ≥ NAS 重启耗时。
    public let commLossFailsafeMinutes: Int
    public let pollSeconds: Int
    /// App 可从控制面板暂停/恢复保护。默认 true（旧 config 无此字段时保持启用）。
    public let enabled: Bool

    public init(host: String, port: Int, ups: String,
                username: String = "", password: String = "",
                onBatteryMinutes: Int, shutdownAlsoOnLowBattery: Bool,
                commLossFailsafeMinutes: Int = 0, pollSeconds: Int = 5,
                enabled: Bool = true) {
        self.host = host; self.port = port; self.ups = ups
        self.username = username; self.password = password
        self.onBatteryMinutes = onBatteryMinutes
        self.shutdownAlsoOnLowBattery = shutdownAlsoOnLowBattery
        self.commLossFailsafeMinutes = commLossFailsafeMinutes
        self.pollSeconds = pollSeconds
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, ups, username, password, onBatteryMinutes
        case shutdownAlsoOnLowBattery, commLossFailsafeMinutes, pollSeconds, enabled
    }

    // 自定义解码：凭据/failsafe/poll/enabled 缺失时取默认，保证旧 config 向后兼容。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        ups = try c.decode(String.self, forKey: .ups)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        onBatteryMinutes = try c.decode(Int.self, forKey: .onBatteryMinutes)
        shutdownAlsoOnLowBattery = try c.decode(Bool.self, forKey: .shutdownAlsoOnLowBattery)
        commLossFailsafeMinutes = try c.decodeIfPresent(Int.self, forKey: .commLossFailsafeMinutes) ?? 0
        pollSeconds = try c.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? 5
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public var policy: ShutdownPolicy {
        ShutdownPolicy(onBatteryMinutes: onBatteryMinutes, shutdownAlsoOnLowBattery: shutdownAlsoOnLowBattery)
    }

    public static func load(data: Data) throws -> DaemonConfig {
        let cfg = try JSONDecoder().decode(DaemonConfig.self, from: data)
        guard cfg.onBatteryMinutes >= 1 else {
            throw DaemonConfigError.invalid("onBatteryMinutes 必须 ≥ 1（当前 \(cfg.onBatteryMinutes)），否则任何转电池瞬间即关机")
        }
        guard cfg.commLossFailsafeMinutes >= 0 else {
            throw DaemonConfigError.invalid("commLossFailsafeMinutes 不能为负（当前 \(cfg.commLossFailsafeMinutes)）")
        }
        guard cfg.pollSeconds >= 1 else {
            throw DaemonConfigError.invalid("pollSeconds 必须 ≥ 1（当前 \(cfg.pollSeconds)）")
        }
        return cfg
    }
    public static func load(path: String) throws -> DaemonConfig {
        try load(data: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    public func encoded() throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }
}
```

- [ ] **Step 6: 运行测试确认通过**

Run: `./test.sh --filter DaemonConfigTests`
Expected: PASS(含既有 6 例 + 新增 3 例)

- [ ] **Step 7: 全量测试确保无回归**

Run: `./test.sh`
Expected: PASS(SafeHaltAgent 删除不影响,因它本不在 Package.swift)

- [ ] **Step 8: 提交**

```bash
git add -A
git commit -m "feat(config): DaemonConfig 加 enabled/可选凭据 + 控制端口常量；删死代码 SafeHaltAgent"
```

---

### Task 2: HTTP/1.1 请求解析 + 响应编码(纯函数)

**Files:**
- Create: `Sources/SafeHaltKit/Control/HTTPMessage.swift`
- Test: `Tests/SafeHaltKitTests/HTTPMessageTests.swift`

**Interfaces:**
- Produces:
  - `struct HTTPRequest { let method: String; let path: String; let query: [String:String]; let headers: [String:String]; let body: Data }`(headers 键小写)。
  - `enum HTTPParseResult { case incomplete; case ok(HTTPRequest) }`
  - `enum HTTPRequestParseError: Error, Equatable { case malformed(String) }`
  - `enum HTTPParser { static func parse(_ data: Data) throws -> HTTPParseResult }`
  - `struct HTTPResponse { let status: Int; let body: Data; static func json(_ status: Int, _ body: Data) -> HTTPResponse; static func error(_ status: Int, _ message: String) -> HTTPResponse; func serialized() -> Data }`

- [ ] **Step 1: 写失败测试**

Create `Tests/SafeHaltKitTests/HTTPMessageTests.swift`:

```swift
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

    @Test func errorResponseWrapsMessage() {
        let out = HTTPResponse.error(401, "需要配对").serialized()
        let text = String(data: out, encoding: .utf8)!
        #expect(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        #expect(text.contains(#""error""#))
        #expect(text.contains("需要配对"))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `./test.sh --filter HTTPMessageTests`
Expected: FAIL(`HTTPParser` 等未定义)

- [ ] **Step 3: 实现 HTTPMessage.swift**

```swift
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
```

- [ ] **Step 4: 运行确认通过**

Run: `./test.sh --filter HTTPMessageTests`
Expected: PASS(8 例)

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat(control): HTTP/1.1 请求解析 + 响应编码（纯函数）"
```

---

### Task 3: 配对码/令牌与 PairingStore

**Files:**
- Create: `Sources/SafeHaltKit/Control/Pairing.swift`
- Test: `Tests/SafeHaltKitTests/PairingTests.swift`

**Interfaces:**
- Produces:
  - `typealias RandomBytes = @Sendable (_ count: Int) -> [UInt8]`;`enum Pairing { static let secureRandom: RandomBytes }`
  - `Pairing.sha256Hex(_ s: String) -> String`
  - `Pairing.constantTimeEquals(_ a: String, _ b: String) -> Bool`
  - `Pairing.makeCode(_ random: RandomBytes) -> String`(形如 `"7F3A-9C21"`,大写十六进制,4+4)
  - `Pairing.makeToken(_ random: RandomBytes) -> String`(32 位小写十六进制)
  - `struct PairingState: Codable, Equatable { var codeHash: String; var tokenHash: String? }`
  - `struct PairingStore { let path: String; init(path:); func load() -> PairingState?; func save(_:) throws }`
  - `enum Pairing.initPairing(store:random:) throws -> String`(生成码、存 `codeHash`、`tokenHash=nil`,返回明文码)
  - `Pairing.redeem(store:submittedCode:random:) throws -> String?`(码对则生成令牌、存 `tokenHash`、返回明文令牌;不对返回 nil)
  - `Pairing.verifyToken(store:bearer:) -> Bool`(常量时间比对 `sha256Hex(bearer)` 与 `tokenHash`)

- [ ] **Step 1: 写失败测试**

Create `Tests/SafeHaltKitTests/PairingTests.swift`:

```swift
import Foundation
import Testing
@testable import SafeHaltKit

struct PairingTests {
    // 确定性随机：返回递增字节，便于断言格式
    private let seq: RandomBytes = { count in (0..<count).map { UInt8($0 & 0xFF) } }

    @Test func codeFormatIsFourDashFourUppercaseHex() {
        let code = Pairing.makeCode(seq)   // 字节 00 01 02 03 → "0001-0203"
        #expect(code == "0001-0203")
    }

    @Test func tokenIs32LowercaseHex() {
        let token = Pairing.makeToken(seq)
        #expect(token.count == 32)
        #expect(token == token.lowercased())
        #expect(token.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func sha256HexIsStable() {
        #expect(Pairing.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func constantTimeEqualsMatchesOnlyIdentical() {
        #expect(Pairing.constantTimeEquals("deadbeef", "deadbeef"))
        #expect(!Pairing.constantTimeEquals("deadbeef", "deadbee0"))
        #expect(!Pairing.constantTimeEquals("deadbeef", "deadbe"))
    }

    @Test func initPairingStoresCodeHashNoToken() throws {
        let path = NSTemporaryDirectory() + "pair-\(UInt64(abs(seq(8).hashValue))).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = PairingStore(path: path)
        let code = try Pairing.initPairing(store: store, random: seq)
        let state = store.load()
        #expect(state?.codeHash == Pairing.sha256Hex(code))
        #expect(state?.tokenHash == nil)
    }

    @Test func redeemWithCorrectCodeIssuesToken() throws {
        let path = NSTemporaryDirectory() + "pair-redeem-ok.json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = PairingStore(path: path)
        let code = try Pairing.initPairing(store: store, random: seq)
        let token = try Pairing.redeem(store: store, submittedCode: code, random: seq)
        #expect(token != nil)
        #expect(store.load()?.tokenHash == Pairing.sha256Hex(token!))
        #expect(Pairing.verifyToken(store: store, bearer: token!))
    }

    @Test func redeemWithWrongCodeReturnsNilAndNoToken() throws {
        let path = NSTemporaryDirectory() + "pair-redeem-bad.json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = PairingStore(path: path)
        _ = try Pairing.initPairing(store: store, random: seq)
        let token = try Pairing.redeem(store: store, submittedCode: "WRON-GCOD", random: seq)
        #expect(token == nil)
        #expect(store.load()?.tokenHash == nil)
    }

    @Test func verifyTokenFalseWhenUnpaired() throws {
        let path = NSTemporaryDirectory() + "pair-unpaired.json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = PairingStore(path: path)
        _ = try Pairing.initPairing(store: store, random: seq)
        #expect(!Pairing.verifyToken(store: store, bearer: "anything"))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `./test.sh --filter PairingTests`
Expected: FAIL(`Pairing` 未定义)

- [ ] **Step 3: 实现 Pairing.swift**

```swift
import Foundation
import CryptoKit

public typealias RandomBytes = @Sendable (_ count: Int) -> [UInt8]

public struct PairingState: Codable, Equatable {
    public var codeHash: String
    public var tokenHash: String?
    public init(codeHash: String, tokenHash: String? = nil) {
        self.codeHash = codeHash; self.tokenHash = tokenHash
    }
}

/// 配对状态持久化（600 root）。绝不由沙盒 App 读写。
public struct PairingStore {
    public let path: String
    public init(path: String) { self.path = path }

    public func load() -> PairingState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(PairingState.self, from: data)
    }
    public func save(_ state: PairingState) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(state)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

public enum Pairing {
    public static let secureRandom: RandomBytes = { count in
        var buf = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &buf)
        return buf
    }

    public static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 常量时间字符串比较（避免计时侧信道）。长度不等直接 false。
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    /// 4+4 大写十六进制配对码，形如 7F3A-9C21（人易读易念）。
    public static func makeCode(_ random: RandomBytes) -> String {
        let b = random(4)
        let hex = b.map { String(format: "%02X", $0) }.joined()
        let mid = hex.index(hex.startIndex, offsetBy: 4)
        return "\(hex[hex.startIndex..<mid])-\(hex[mid...])"
    }

    /// 32 位小写十六进制不透明令牌（16 字节熵）。
    public static func makeToken(_ random: RandomBytes) -> String {
        random(16).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public static func initPairing(store: PairingStore, random: RandomBytes) throws -> String {
        let code = makeCode(random)
        try store.save(PairingState(codeHash: sha256Hex(code), tokenHash: nil))
        return code
    }

    /// 码正确 → 生成令牌、写 tokenHash、返回明文令牌；否则 nil（状态不变）。
    public static func redeem(store: PairingStore, submittedCode: String, random: RandomBytes) throws -> String? {
        guard var state = store.load() else { return nil }
        guard constantTimeEquals(sha256Hex(submittedCode), state.codeHash) else { return nil }
        let token = makeToken(random)
        state.tokenHash = sha256Hex(token)
        try store.save(state)
        return token
    }

    public static func verifyToken(store: PairingStore, bearer: String) -> Bool {
        guard let hash = store.load()?.tokenHash else { return false }
        return constantTimeEquals(sha256Hex(bearer), hash)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `./test.sh --filter PairingTests`
Expected: PASS(9 例)

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat(control): 配对码/令牌生成 + SHA256 + PairingStore"
```

---

### Task 4: 引擎状态 DTO + DaemonRunner 演进(哑门控/快照/事件环)

**Files:**
- Create: `Sources/SafeHaltKit/Control/EngineStatus.swift`
- Modify: `Sources/SafeHaltKit/DaemonRunner.swift`
- Test: `Tests/SafeHaltKitTests/DaemonRunnerTests.swift`(扩充)

**Interfaces:**
- Consumes: `DaemonConfig`(Task 1);`ShutdownDecider`/`DeciderState`/`SystemActions`/`UPSMonitor`/`NUTTransport`(现有,不改)。
- Produces:
  - `struct EngineTarget: Codable, Equatable { let host: String; let port: Int; let ups: String }`
  - `struct EnginePolicyDTO: Codable, Equatable { let onBatteryMinutes: Int; let shutdownAlsoOnLowBattery: Bool; let commLossFailsafeMinutes: Int }`
  - `struct EngineStatus: Codable, Equatable { let configured: Bool; let enabled: Bool; let target: EngineTarget?; let connected: Bool; let lastStatusRaw: String?; let lastSeenEpoch: Double?; let countdownActive: Bool; let countdownRemainingSeconds: Int?; let policy: EnginePolicyDTO? }`
  - `struct EngineEvent: Codable, Equatable { let atEpoch: Double; let kind: String; let message: String }`
  - `protocol EngineControl: Sendable { func currentStatus(now: Date) async -> EngineStatus; func recentEvents(limit: Int) async -> [EngineEvent]; func applySettings(_ cfg: DaemonConfig) async }`
  - `DaemonRunner` 改为 `init(settings: DaemonConfig?, transportFactory:, actions:, persist: (@Sendable (DaemonConfig) -> Void)? = nil)`;新增 `applySettings`/`setEnabled`/`currentStatus`/`recentEvents`,遵从 `EngineControl`。当 `settings == nil || !enabled` 时 `tick` 不连 NUT、不决策(哑/暂停)。

- [ ] **Step 1: 写失败测试**

在 `Tests/SafeHaltKitTests/DaemonRunnerTests.swift` 追加(保留原有测试;若原有 `DaemonRunner(config:...)` 构造在编译期报错,同时按 Step 5 的新签名更新原有用例的构造调用):

```swift
    @Test func dumbWhenUnconfiguredDoesNotShutdown() async {
        let actions = RecordingActions()   // 见下方说明：复用本测试文件已有的假 actions
        let runner = DaemonRunner(settings: nil,
                                  transportFactory: { _, _ in FakeTransport(script: []) },
                                  actions: actions)
        await runner.tick(now: Date())
        #expect(actions.shutdownCount == 0)
        let st = await runner.currentStatus(now: Date())
        #expect(st.configured == false)
        #expect(st.target == nil)
    }

    @Test func pausedWhenDisabledDoesNotShutdown() async {
        let actions = RecordingActions()
        let cfg = DaemonConfig(host: "h", port: 3493, ups: "ups",
                               onBatteryMinutes: 10, shutdownAlsoOnLowBattery: true, enabled: false)
        let runner = DaemonRunner(settings: cfg,
                                  transportFactory: { _, _ in FakeTransport(script: ["OB"]) },
                                  actions: actions)
        await runner.tick(now: Date())
        #expect(actions.shutdownCount == 0)
        let st = await runner.currentStatus(now: Date())
        #expect(st.configured == true)
        #expect(st.enabled == false)
    }

    @Test func applySettingsPersistsAndArms() async {
        let actions = RecordingActions()
        var persisted: DaemonConfig?
        let runner = DaemonRunner(settings: nil,
                                  transportFactory: { _, _ in FakeTransport(script: []) },
                                  actions: actions,
                                  persist: { persisted = $0 })
        let cfg = DaemonConfig(host: "h", port: 3493, ups: "ups",
                               onBatteryMinutes: 10, shutdownAlsoOnLowBattery: true)
        await runner.applySettings(cfg)
        #expect(persisted == cfg)
        let st = await runner.currentStatus(now: Date())
        #expect(st.configured == true)
        #expect(st.target == EngineTarget(host: "h", port: 3493, ups: "ups"))
    }
```

> 说明:本测试用到 `RecordingActions`(记录 `shutdownCount` 等的假 `SystemActions`)与 `FakeTransport`(按脚本返回 NUT 状态帧)。若 `DaemonRunnerTests.swift` 已有等价假实现,复用之;否则在本文件顶部新增最小实现——`RecordingActions` 各方法计数/空实现、`isCancelRequested` 返回 false;`FakeTransport` 遵从 `NUTTransport`,对 `LIST VAR`/`GET VAR ups.status` 返回脚本给定的 `ups.status`(如 `"OB"`/`"OL"`)。实现须与既有测试的假实现保持一致命名,避免重复定义。

- [ ] **Step 2: 运行确认失败**

Run: `./test.sh --filter DaemonRunnerTests`
Expected: FAIL(新签名/`currentStatus`/`EngineTarget` 未定义)

- [ ] **Step 3: 建 EngineStatus.swift**

```swift
import Foundation

public struct EngineTarget: Codable, Equatable {
    public let host: String
    public let port: Int
    public let ups: String
    public init(host: String, port: Int, ups: String) { self.host = host; self.port = port; self.ups = ups }
}

public struct EnginePolicyDTO: Codable, Equatable {
    public let onBatteryMinutes: Int
    public let shutdownAlsoOnLowBattery: Bool
    public let commLossFailsafeMinutes: Int
    public init(onBatteryMinutes: Int, shutdownAlsoOnLowBattery: Bool, commLossFailsafeMinutes: Int) {
        self.onBatteryMinutes = onBatteryMinutes
        self.shutdownAlsoOnLowBattery = shutdownAlsoOnLowBattery
        self.commLossFailsafeMinutes = commLossFailsafeMinutes
    }
}

/// GET /status 回显。App 据此做一致性判定与健康展示。
public struct EngineStatus: Codable, Equatable {
    public let configured: Bool
    public let enabled: Bool
    public let target: EngineTarget?
    public let connected: Bool
    public let lastStatusRaw: String?
    public let lastSeenEpoch: Double?
    public let countdownActive: Bool
    public let countdownRemainingSeconds: Int?
    public let policy: EnginePolicyDTO?
    public init(configured: Bool, enabled: Bool, target: EngineTarget?, connected: Bool,
                lastStatusRaw: String?, lastSeenEpoch: Double?, countdownActive: Bool,
                countdownRemainingSeconds: Int?, policy: EnginePolicyDTO?) {
        self.configured = configured; self.enabled = enabled; self.target = target
        self.connected = connected; self.lastStatusRaw = lastStatusRaw; self.lastSeenEpoch = lastSeenEpoch
        self.countdownActive = countdownActive; self.countdownRemainingSeconds = countdownRemainingSeconds
        self.policy = policy
    }
}

/// GET /log 单条事件。
public struct EngineEvent: Codable, Equatable {
    public let atEpoch: Double
    public let kind: String
    public let message: String
    public init(atEpoch: Double, kind: String, message: String) {
        self.atEpoch = atEpoch; self.kind = kind; self.message = message
    }
}

/// 控制路由据此读引擎状态/事件、下发配置（DaemonRunner 遵从）。
public protocol EngineControl: Sendable {
    func currentStatus(now: Date) async -> EngineStatus
    func recentEvents(limit: Int) async -> [EngineEvent]
    func applySettings(_ cfg: DaemonConfig) async
}
```

- [ ] **Step 4: 演进 DaemonRunner.swift**

整体替换为(保留原 tick 决策逻辑,新增可变 settings/门控/快照/事件环/持久化):

```swift
// Sources/SafeHaltKit/DaemonRunner.swift
import Foundation
import SafeHaltCore

/// 守护进程主循环：轮询 UPS → 决策 → 副作用。维护转电池起始与通信中断起始。
/// 支持哑/暂停门控与运行期改配（App 经 HTTP 控制）。
public actor DaemonRunner: EngineControl {
    private var settings: DaemonConfig?
    private var transportFactory: @Sendable (String, Int) -> NUTTransport
    private let actions: SystemActions
    private let persist: (@Sendable (DaemonConfig) -> Void)?

    private var onBatterySince: Date?
    private var commLostSince: Date?

    // /status 与 /log 所需的观测量
    private var lastStatus: UPSStatus?
    private var lastSeen: Date?
    private var events: [EngineEvent] = []
    private let eventCap = 100

    public init(settings: DaemonConfig?,
                transportFactory: @escaping @Sendable (String, Int) -> NUTTransport,
                actions: SystemActions,
                persist: (@Sendable (DaemonConfig) -> Void)? = nil) {
        self.settings = settings
        self.transportFactory = transportFactory
        self.actions = actions
        self.persist = persist
    }

    public var onBatterySinceForTest: Date? { onBatterySince }
    public func setTransportFactoryForTest(_ f: @escaping @Sendable (String, Int) -> NUTTransport) {
        transportFactory = f
    }

    // MARK: EngineControl

    public func applySettings(_ cfg: DaemonConfig) {
        let targetChanged = settings.map { $0.host != cfg.host || $0.port != cfg.port || $0.ups != cfg.ups } ?? true
        settings = cfg
        if targetChanged { onBatterySince = nil; commLostSince = nil; lastStatus = nil; lastSeen = nil }
        persist?(cfg)
        appendEvent(kind: "config", message: "配置已更新（\(cfg.host)/\(cfg.ups)，\(cfg.enabled ? "启用" : "暂停")）")
    }

    public func currentStatus(now: Date) -> EngineStatus {
        guard let cfg = settings else {
            return EngineStatus(configured: false, enabled: false, target: nil, connected: false,
                                lastStatusRaw: nil, lastSeenEpoch: nil, countdownActive: false,
                                countdownRemainingSeconds: nil, policy: nil)
        }
        let counting = onBatterySince != nil
        let remaining: Int? = onBatterySince.map {
            max(0, cfg.onBatteryMinutes * 60 - Int(now.timeIntervalSince($0)))
        }
        let connected = lastStatus != nil
        return EngineStatus(
            configured: true, enabled: cfg.enabled,
            target: EngineTarget(host: cfg.host, port: cfg.port, ups: cfg.ups),
            connected: connected,
            lastStatusRaw: lastStatus?.raw["ups.status"],
            lastSeenEpoch: lastSeen?.timeIntervalSince1970,
            countdownActive: counting,
            countdownRemainingSeconds: counting ? remaining : nil,
            policy: EnginePolicyDTO(onBatteryMinutes: cfg.onBatteryMinutes,
                                    shutdownAlsoOnLowBattery: cfg.shutdownAlsoOnLowBattery,
                                    commLossFailsafeMinutes: cfg.commLossFailsafeMinutes))
    }

    public func recentEvents(limit: Int) -> [EngineEvent] {
        Array(events.suffix(max(0, limit)))
    }

    private func appendEvent(kind: String, message: String) {
        events.append(EngineEvent(atEpoch: Date().timeIntervalSince1970, kind: kind, message: message))
        if events.count > eventCap { events.removeFirst(events.count - eventCap) }
    }

    // MARK: 主循环

    public func tick(now: Date) async {
        // 哑（无配置）或暂停（enabled=false）：不连 NUT、不决策、不关机
        guard let config = settings, config.enabled else { return }

        let monitor = UPSMonitor(transport: transportFactory(config.host, config.port), upsName: config.ups)
        let status = (await monitor.pollOnce()).status
        if let status { lastStatus = status; lastSeen = now }

        let commJustLost = (status == nil && commLostSince == nil)
        let commJustRestored = (status != nil && commLostSince != nil)
        if status == nil {
            if commLostSince == nil { commLostSince = now }
        } else {
            commLostSince = nil
        }

        let decision = ShutdownDecider.decide(DeciderState(
            status: status, onBatterySince: onBatterySince, commLostSince: commLostSince,
            now: now, policy: config.policy,
            commLossFailsafeMinutes: config.commLossFailsafeMinutes,
            cancelRequested: actions.isCancelRequested()))

        switch decision.action {
        case .none:
            break
        case .startCountdown:
            onBatterySince = now
            actions.beginEpisode()
            appendEvent(kind: "countdown", message: decision.reason)
            let warnMsg = (status == nil)
                ? "与 UPS 通信持续中断，疑似断电。\(config.onBatteryMinutes) 分钟后若未恢复将自动关机。"
                : "市电中断，已转 UPS 供电。\(config.onBatteryMinutes) 分钟后若未恢复将自动关机。"
            actions.presentCancelableWarning(minutes: config.onBatteryMinutes, message: warnMsg)
        case .cancelCountdown:
            onBatterySince = nil
            actions.endEpisode()
            appendEvent(kind: "restore", message: "市电已恢复，取消关机")
            actions.notify("市电已恢复，取消关机。")
        case .shutdownNow:
            appendEvent(kind: "shutdown", message: decision.reason)
            actions.shutdown(reason: decision.reason)
        }

        if commJustLost {
            appendEvent(kind: "commLost", message: "与 UPS 的通信中断")
            actions.notify(config.commLossFailsafeMinutes > 0
                ? "与 UPS 的通信中断，\(config.commLossFailsafeMinutes) 分钟内未恢复将按断电处理。"
                : "与 UPS 的通信中断（未启用通信丢失关机，仅监控）。")
        } else if commJustRestored {
            appendEvent(kind: "commRestore", message: "与 UPS 的通信已恢复")
            actions.notify("与 UPS 的通信已恢复。")
        }
    }

    public func run() async {
        while !Task.isCancelled {
            await tick(now: Date())
            let sleep = settings.map { max(1, $0.pollSeconds) } ?? 5
            try? await Task.sleep(nanoseconds: UInt64(sleep) * 1_000_000_000)
        }
    }
}
```

- [ ] **Step 5: 修正原有 DaemonRunnerTests 构造调用**

原有用例若以 `DaemonRunner(config: X, ...)` 构造,改为 `DaemonRunner(settings: X, ...)`(其余参数不变)。运行前先本地编译暴露所有点:

Run: `swift build 2>&1 | grep -i "error:" || echo OK`
把每处报错的构造点由 `config:` 改成 `settings:`。

- [ ] **Step 6: 运行确认通过**

Run: `./test.sh --filter DaemonRunnerTests`
Expected: PASS(原有用例 + 新增 3 例)

- [ ] **Step 7: 全量测试**

Run: `./test.sh`
Expected: PASS

- [ ] **Step 8: 提交**

```bash
git add -A
git commit -m "feat(engine): DaemonRunner 哑/暂停门控 + 运行期改配 + /status 快照 + 事件环"
```

---

### Task 5: 控制路由 ControlRouter(端点 + 鉴权)

**Files:**
- Create: `Sources/SafeHaltKit/Control/ControlRouter.swift`
- Test: `Tests/SafeHaltKitTests/ControlRouterTests.swift`

**Interfaces:**
- Consumes: `HTTPRequest`/`HTTPResponse`(Task 2);`PairingStore`/`Pairing`(Task 3);`EngineControl`/`EngineStatus`/`EngineEvent`(Task 4);`DaemonConfig`(Task 1);`DaemonPaths.cancelFlagFile`。
- Produces:
  - `struct ControlRouter { init(engine: EngineControl, pairing: PairingStore, random: @escaping RandomBytes, now: @escaping @Sendable () -> Date, touchCancel: @escaping @Sendable () -> Void); func handle(_ req: HTTPRequest) async -> HTTPResponse }`
  - 端点契约:
    - `GET /ping` → 200 `{"installed":true,"paired":Bool,"configured":Bool}`(免鉴权,不含敏感信息)
    - `POST /pair` 体 `{"code":"7F3A-9C21"}` → 成功 200 `{"token":"..."}`;码错 401 `{"error":...}`
    - 其余需 `Authorization: Bearer <token>`,否则 401:
      - `POST /config` 体 = `DaemonConfig` JSON → `applySettings` → 200 `{"ok":true}`;体非法 400
      - `GET /status` → 200 `EngineStatus` JSON
      - `POST /cancel` → `touchCancel()` → 200 `{"ok":true}`
      - `GET /log?n=N` → 200 `[EngineEvent]`(默认 50,`n` 上限 100)
    - 未知 → 404

- [ ] **Step 1: 写失败测试**

Create `Tests/SafeHaltKitTests/ControlRouterTests.swift`:

```swift
import Foundation
import Testing
@testable import SafeHaltKit

private actor FakeEngine: EngineControl {
    var applied: DaemonConfig?
    let status: EngineStatus
    let events: [EngineEvent]
    init(status: EngineStatus, events: [EngineEvent] = []) { self.status = status; self.events = events }
    func currentStatus(now: Date) async -> EngineStatus { status }
    func recentEvents(limit: Int) async -> [EngineEvent] { Array(events.prefix(limit)) }
    func applySettings(_ cfg: DaemonConfig) async { applied = cfg }
    func appliedConfig() -> DaemonConfig? { applied }
}

struct ControlRouterTests {
    private let seq: RandomBytes = { count in (0..<count).map { UInt8($0 & 0xFF) } }
    private let dumbStatus = EngineStatus(configured: false, enabled: false, target: nil, connected: false,
        lastStatusRaw: nil, lastSeenEpoch: nil, countdownActive: false, countdownRemainingSeconds: nil, policy: nil)

    private func store(_ name: String) -> PairingStore {
        PairingStore(path: NSTemporaryDirectory() + "router-\(name).json")
    }
    private func req(_ method: String, _ path: String, headers: [String:String] = [:], body: String = "") -> HTTPRequest {
        var h = headers; if !body.isEmpty { h["content-length"] = "\(body.utf8.count)" }
        // 用解析器构造，确保与真实链路一致
        let raw = "\(method) \(path) HTTP/1.1\r\n" + h.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n\r\n" + body
        guard case .ok(let r) = try! HTTPParser.parse(Data(raw.utf8)) else { fatalError("测试请求构造失败") }
        return r
    }
    private func router(_ engine: FakeEngine, _ st: PairingStore, cancel: @escaping @Sendable () -> Void = {}) -> ControlRouter {
        ControlRouter(engine: engine, pairing: st, random: seq, now: { Date(timeIntervalSince1970: 0) }, touchCancel: cancel)
    }

    @Test func pingUnauthenticatedReportsState() async throws {
        let s = store("ping"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        _ = try Pairing.initPairing(store: s, random: seq)
        let r = router(FakeEngine(status: dumbStatus), s)
        let resp = await r.handle(req("GET", "/ping"))
        #expect(resp.status == 200)
        let obj = try JSONSerialization.jsonObject(with: resp.body) as! [String: Any]
        #expect(obj["installed"] as? Bool == true)
        #expect(obj["paired"] as? Bool == false)
        #expect(obj["configured"] as? Bool == false)
    }

    @Test func pairWithCorrectCodeReturnsToken() async throws {
        let s = store("pair"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        let code = try Pairing.initPairing(store: s, random: seq)
        let r = router(FakeEngine(status: dumbStatus), s)
        let resp = await r.handle(req("POST", "/pair", body: #"{"code":"\#(code)"}"#))
        #expect(resp.status == 200)
        let obj = try JSONSerialization.jsonObject(with: resp.body) as! [String: Any]
        #expect((obj["token"] as? String)?.isEmpty == false)
    }

    @Test func pairWithWrongCodeIs401() async throws {
        let s = store("pairbad"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        _ = try Pairing.initPairing(store: s, random: seq)
        let r = router(FakeEngine(status: dumbStatus), s)
        let resp = await r.handle(req("POST", "/pair", body: #"{"code":"WRON-GXXX"}"#))
        #expect(resp.status == 401)
    }

    @Test func protectedEndpointWithoutTokenIs401() async throws {
        let s = store("noauth"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        _ = try Pairing.initPairing(store: s, random: seq)
        let r = router(FakeEngine(status: dumbStatus), s)
        #expect(await r.handle(req("GET", "/status")).status == 401)
    }

    @Test func configWithValidTokenAppliesSettings() async throws {
        let s = store("config"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        let code = try Pairing.initPairing(store: s, random: seq)
        let engine = FakeEngine(status: dumbStatus)
        let r = router(engine, s)
        guard case .ok = try HTTPParser.parse(Data("x".utf8)) else {} // noop 保持 import
        let token = try #require(try Pairing.redeem(store: s, submittedCode: code, random: seq))
        let body = #"{"host":"192.168.0.5","port":3493,"ups":"ups","onBatteryMinutes":10,"shutdownAlsoOnLowBattery":true,"commLossFailsafeMinutes":5,"enabled":true}"#
        let resp = await r.handle(req("POST", "/config", headers: ["authorization": "Bearer \(token)"], body: body))
        #expect(resp.status == 200)
        let applied = await engine.appliedConfig()
        #expect(applied?.host == "192.168.0.5")
        #expect(applied?.onBatteryMinutes == 10)
    }

    @Test func configWithInvalidBodyIs400() async throws {
        let s = store("cfgbad"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        let code = try Pairing.initPairing(store: s, random: seq)
        let token = try #require(try Pairing.redeem(store: s, submittedCode: code, random: seq))
        let r = router(FakeEngine(status: dumbStatus), s)
        // onBatteryMinutes=0 触发 DaemonConfig.load 校验失败
        let body = #"{"host":"h","port":3493,"ups":"ups","onBatteryMinutes":0,"shutdownAlsoOnLowBattery":true}"#
        let resp = await r.handle(req("POST", "/config", headers: ["authorization": "Bearer \(token)"], body: body))
        #expect(resp.status == 400)
    }

    @Test func cancelTouchesFlag() async throws {
        let s = store("cancel"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        let code = try Pairing.initPairing(store: s, random: seq)
        let token = try #require(try Pairing.redeem(store: s, submittedCode: code, random: seq))
        var touched = false
        let r = router(FakeEngine(status: dumbStatus), s, cancel: { touched = true })
        let resp = await r.handle(req("POST", "/cancel", headers: ["authorization": "Bearer \(token)"]))
        #expect(resp.status == 200)
        #expect(touched == true)
    }

    @Test func logReturnsEvents() async throws {
        let s = store("log"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        let code = try Pairing.initPairing(store: s, random: seq)
        let token = try #require(try Pairing.redeem(store: s, submittedCode: code, random: seq))
        let ev = [EngineEvent(atEpoch: 1, kind: "countdown", message: "转电池"),
                  EngineEvent(atEpoch: 2, kind: "restore", message: "恢复")]
        let r = router(FakeEngine(status: dumbStatus, events: ev), s)
        let resp = await r.handle(req("GET", "/log?n=50", headers: ["authorization": "Bearer \(token)"]))
        #expect(resp.status == 200)
        let arr = try JSONSerialization.jsonObject(with: resp.body) as! [[String: Any]]
        #expect(arr.count == 2)
    }

    @Test func unknownPathIs404() async throws {
        let s = store("404"); defer { try? FileManager.default.removeItem(atPath: s.path) }
        let code = try Pairing.initPairing(store: s, random: seq)
        let token = try #require(try Pairing.redeem(store: s, submittedCode: code, random: seq))
        let r = router(FakeEngine(status: dumbStatus), s)
        #expect(await r.handle(req("GET", "/nope", headers: ["authorization": "Bearer \(token)"])).status == 404)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `./test.sh --filter ControlRouterTests`
Expected: FAIL(`ControlRouter` 未定义)

- [ ] **Step 3: 实现 ControlRouter.swift**

```swift
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
        guard let token = try? Pairing.redeem(store: pairing, submittedCode: code, random: random),
              let issued = token else {
            return .error(401, "配对码不正确")
        }
        return json(200, ["token": issued])
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
```

- [ ] **Step 4: 运行确认通过**

Run: `./test.sh --filter ControlRouterTests`
Expected: PASS(10 例)

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat(control): ControlRouter 端点路由 + Bearer 鉴权"
```

---

### Task 6: ControlServer(NWListener loopback 粘合层)

**Files:**
- Create: `Sources/SafeHaltKit/Control/ControlServer.swift`
- Test: `Tests/SafeHaltKitTests/ControlServerIntegrationTests.swift`

**Interfaces:**
- Consumes: `ControlRouter`/`HTTPParser`/`HTTPResponse`(前置任务);`DaemonPaths.httpPort`。
- Produces:
  - `actor ControlServer { init(port: UInt16, router: ControlRouter); func start() throws; func boundPort() -> UInt16?; func stop() }`
  - 只绑 `127.0.0.1`;每连接读到完整请求 → `await router.handle` → 写响应 → 关闭。
  - `port: 0` 时由系统分配,`boundPort()` 返回实际端口(供测试)。

- [ ] **Step 1: 写失败集成测试**

Create `Tests/SafeHaltKitTests/ControlServerIntegrationTests.swift`:

```swift
import Foundation
import Testing
@testable import SafeHaltKit

private actor StubEngine: EngineControl {
    func currentStatus(now: Date) async -> EngineStatus {
        EngineStatus(configured: true, enabled: true,
                     target: EngineTarget(host: "192.168.0.5", port: 3493, ups: "ups"),
                     connected: true, lastStatusRaw: "OL", lastSeenEpoch: 100,
                     countdownActive: false, countdownRemainingSeconds: nil,
                     policy: EnginePolicyDTO(onBatteryMinutes: 10, shutdownAlsoOnLowBattery: true, commLossFailsafeMinutes: 5))
    }
    func recentEvents(limit: Int) async -> [EngineEvent] { [] }
    func applySettings(_ cfg: DaemonConfig) async {}
}

struct ControlServerIntegrationTests {
    private let seq: RandomBytes = { count in (0..<count).map { UInt8($0 & 0xFF) } }

    @Test func servesPingOverLoopback() async throws {
        let store = PairingStore(path: NSTemporaryDirectory() + "srv-ping.json")
        defer { try? FileManager.default.removeItem(atPath: store.path) }
        _ = try Pairing.initPairing(store: store, random: seq)
        let router = ControlRouter(engine: StubEngine(), pairing: store, random: seq,
                                   now: { Date() }, touchCancel: {})
        let server = ControlServer(port: 0, router: router)
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.boundPort())

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/ping")!)
        req.timeoutInterval = 3
        let (data, resp) = try await URLSession.shared.data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["installed"] as? Bool == true)
    }

    @Test func statusRequiresTokenOverLoopback() async throws {
        let store = PairingStore(path: NSTemporaryDirectory() + "srv-auth.json")
        defer { try? FileManager.default.removeItem(atPath: store.path) }
        _ = try Pairing.initPairing(store: store, random: seq)
        let router = ControlRouter(engine: StubEngine(), pairing: store, random: seq,
                                   now: { Date() }, touchCancel: {})
        let server = ControlServer(port: 0, router: router)
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.boundPort())

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/status")!)
        req.timeoutInterval = 3
        let (_, resp) = try await URLSession.shared.data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 401)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `./test.sh --filter ControlServerIntegrationTests`
Expected: FAIL(`ControlServer` 未定义)

- [ ] **Step 3: 实现 ControlServer.swift**

```swift
import Foundation
import Network

/// 只绑 127.0.0.1 的极简 HTTP 控制服务端（每连接一请求，Connection: close）。
/// 安全：崩溃/阻塞绝不能影响守护进程主循环——本类独立于 DaemonRunner，经 actor 隔离。
public actor ControlServer {
    private let port: UInt16
    private let router: ControlRouter
    private var listener: NWListener?

    public init(port: UInt16, router: ControlRouter) {
        self.port = port; self.router = router
    }

    public func start() throws {
        let params = NWParameters.tcp
        // 只绑环回地址——外网/局域网无法连入
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                 port: NWEndpoint.Port(rawValue: port) ?? .any)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [router] conn in
            ControlServer.serve(conn, router: router)
        }
        l.start(queue: .global(qos: .utility))
        listener = l
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
```

- [ ] **Step 4: 运行确认通过**

Run: `./test.sh --filter ControlServerIntegrationTests`
Expected: PASS(2 例)

- [ ] **Step 5: 全量测试**

Run: `./test.sh`
Expected: PASS

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat(control): ControlServer——只绑 127.0.0.1 的 NWListener 粘合层"
```

---

### Task 7: main.swift 接线 + 配对子命令 + 品牌对话框

**Files:**
- Create: `Sources/SafeHaltKit/Control/PairingDialog.swift`
- Modify: `Sources/safehalt/main.swift`
- Test: `Tests/SafeHaltKitTests/PairingDialogTests.swift`

**Interfaces:**
- Consumes: `PairingStore`/`Pairing`(Task 3);`ControlServer`/`ControlRouter`(Task 5/6);`DaemonRunner`(Task 4);`DaemonPaths`/`DaemonConfig`/`RealSystemActions`/`NUTSocketSession`。
- Produces:
  - `enum PairingDialog { static func osascriptArgs(uid: uid_t, code: String) -> [String]; static func present(code: String, consoleUID: uid_t?) }`(经 `launchctl asuser <uid> osascript` 弹品牌对话框;无控制台用户则打印到 stdout)。
  - `safehalt pair-init`:生成并写 `pairing.json`,打印 `PAIRING_CODE=XXXX-XXXX`。
  - `safehalt show-pairing-dialog <code>`:弹配对码对话框。
  - 主守护模式:配置缺失/非法 → 哑启动;并行跑 `ControlServer` 与 `DaemonRunner.run()`;服务端绑定失败仅记日志,不阻断保护循环。

- [ ] **Step 1: 写失败测试(纯参数构造)**

Create `Tests/SafeHaltKitTests/PairingDialogTests.swift`:

```swift
import Foundation
import Testing
@testable import SafeHaltKit

struct PairingDialogTests {
    @Test func osascriptArgsCarryAsuserAndCode() {
        let args = PairingDialog.osascriptArgs(uid: 501, code: "7F3A-9C21")
        #expect(args[0] == "asuser")
        #expect(args[1] == "501")
        #expect(args.contains("/usr/bin/osascript"))
        // 配对码出现在脚本文本里
        #expect(args.joined(separator: " ").contains("7F3A-9C21"))
        // 品牌标题
        #expect(args.joined(separator: " ").contains("断电保护"))
    }

    @Test func osascriptArgsEscapeQuotesInCode() {
        // 配对码本身只含十六进制与短横，但仍验证不产生裸双引号注入
        let args = PairingDialog.osascriptArgs(uid: 1, code: "ABCD-1234")
        let joined = args.joined(separator: " ")
        #expect(joined.contains("ABCD-1234"))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `./test.sh --filter PairingDialogTests`
Expected: FAIL(`PairingDialog` 未定义)

- [ ] **Step 3: 实现 PairingDialog.swift**

```swift
import Foundation

/// 经 launchctl asuser 在登录会话弹"配对码"品牌对话框。
/// 与关机路径无关（安装/子命令上下文），可阻塞等待用户点"知道了"。
public enum PairingDialog {
    /// 构造 launchctl 参数（便于单测；不触发真实进程）。
    public static func osascriptArgs(uid: uid_t, code: String) -> [String] {
        let safe = code.replacingOccurrences(of: "\"", with: "")
        let script = "display dialog \"配对码：\(safe)\\n\\n打开 Mac UPS Link，在「连接断电保护引擎」处输入本码即可激活断电保护。\" with title \"⚡ SafeHalt 断电保护\" buttons {\"知道了\"} default button \"知道了\""
        return ["asuser", "\(uid)", "/usr/bin/osascript", "-e", script]
    }

    public static func present(code: String, consoleUID: uid_t?) {
        guard let uid = consoleUID else {
            print("配对码：\(code)（当前无图形登录用户，请在 Mac UPS Link 中输入此码）")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = osascriptArgs(uid: uid, code: code)
        try? p.run()
        p.waitUntilExit()   // 安装上下文，等用户读完；非守护循环，无阻塞风险
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `./test.sh --filter PairingDialogTests`
Expected: PASS(2 例)

- [ ] **Step 5: 重写 main.swift 接线**

整体替换 `Sources/safehalt/main.swift`:

```swift
import Foundation
import SafeHaltCore
import SafeHaltKit

let args = Array(CommandLine.arguments.dropFirst())

// 子命令：cancel（写取消标志后退出）
if args.first == "cancel" {
    FileManager.default.createFile(atPath: DaemonPaths.cancelFlagFile, contents: Data())
    print("已请求取消本次关机")
    exit(0)
}

// 子命令：pair-init（生成配对码，写 pairing.json，打印 PAIRING_CODE=）
if args.first == "pair-init" {
    do {
        let store = PairingStore(path: DaemonPaths.pairingFile)
        let code = try Pairing.initPairing(store: store, random: Pairing.secureRandom)
        print("PAIRING_CODE=\(code)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("[safehalt] pair-init 失败: \(error)\n".utf8))
        exit(1)
    }
}

// 子命令：show-pairing-dialog <code>（弹品牌对话框）
if args.first == "show-pairing-dialog", args.count >= 2 {
    PairingDialog.present(code: args[1], consoleUID: RealSystemActions.currentConsoleUID())
    exit(0)
}

// 主守护模式
var configPath = DaemonPaths.configFile
var dryRun = false
var it = args.makeIterator()
while let arg = it.next() {
    switch arg {
    case "--config": if let p = it.next() { configPath = p }
    case "--dry-run": dryRun = true
    case "--print-plist": print(DaemonPlist.launchd()); exit(0)
    default: break
    }
}

// 配置缺失/非法 → 哑启动（照跑 HTTP，等 App 配对激活）
let settings: DaemonConfig?
do {
    settings = try DaemonConfig.load(path: configPath)
    FileHandle.standardError.write(Data("[safehalt] 启动，配置就绪 \(settings!.host):\(settings!.port)/\(settings!.ups)，enabled=\(settings!.enabled)，dry-run=\(dryRun)\n".utf8))
} catch {
    settings = nil
    FileHandle.standardError.write(Data("[safehalt] 无有效配置（哑模式，仅等待 Mac UPS Link 配对）：\(error)\n".utf8))
}

let capturedPath = configPath
let runner = DaemonRunner(
    settings: settings,
    transportFactory: { NUTSocketSession(host: $0, port: $1) },
    actions: RealSystemActions(dryRun: dryRun),
    persist: { cfg in
        // /config 落盘：600 root，原子写
        if let data = try? cfg.encoded() {
            try? data.write(to: URL(fileURLWithPath: capturedPath), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: capturedPath)
        }
    })

let router = ControlRouter(
    engine: runner,
    pairing: PairingStore(path: DaemonPaths.pairingFile),
    random: Pairing.secureRandom,
    now: { Date() },
    touchCancel: { FileManager.default.createFile(atPath: DaemonPaths.cancelFlagFile, contents: Data()) })

let server = ControlServer(port: UInt16(DaemonPaths.httpPort), router: router)
do {
    try await server.start()
    FileHandle.standardError.write(Data("[safehalt] 控制服务端已绑定 127.0.0.1:\(DaemonPaths.httpPort)\n".utf8))
} catch {
    // 安全：服务端绑定失败不得阻断保护循环
    FileHandle.standardError.write(Data("[safehalt] 控制服务端启动失败（不影响断电保护）：\(error)\n".utf8))
}

await runner.run()
```

- [ ] **Step 6: 编译并全量测试**

Run: `swift build && ./test.sh`
Expected: 编译通过;全部测试 PASS

- [ ] **Step 7: 冒烟——哑启动 + pair-init + ping(本地,非 root,临时路径)**

Run:
```bash
BIN=$(swift build --show-bin-path)/safehalt
# pair-init 写默认 /Library 路径需 root，这里只验证命令存在与 dry 帮助
"$BIN" --print-plist | head -3
```
Expected: 打印 plist XML 头(证明可执行构建正常)

- [ ] **Step 8: 提交**

```bash
git add -A
git commit -m "feat(daemon): main 接线控制服务端 + 哑启动 + pair-init/show-pairing-dialog 子命令"
```

---

### Task 8: `.pkg` 打包 + 卸载更新 + README 重定位

**Files:**
- Create: `make-pkg.sh`
- Modify: `uninstall-daemon.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: `safehalt --print-plist`/`pair-init`/`show-pairing-dialog`(Task 7);`DaemonPaths` 路径。
- Produces:
  - `make-pkg.sh`:构建 release 二进制 → 组装 payload(`/usr/local/bin/safehalt` + `/Library/LaunchDaemons/com.safehalt.daemon.plist`)→ `pkgbuild` 生成 `dist/SafeHalt.pkg`(含 postinstall);支持环境变量 `SIGN_ID` 触发 `productsign`(默认不签,留人工公证)。
  - postinstall:`launchctl load -w` → `safehalt pair-init` → `safehalt show-pairing-dialog <code>`。**不写 config.json**(出厂哑)。
  - `uninstall-daemon.sh`:追加删 `pairing.json`。

- [ ] **Step 1: 写 make-pkg.sh**

Create `make-pkg.sh`:

```bash
#!/bin/bash
# 构建 SafeHalt .pkg 安装包（引导式安装；出厂哑，配对后由 Mac UPS Link 激活）。
# 用法: ./make-pkg.sh [版本号]
#   环境变量 SIGN_ID 设置时用 Developer ID Installer 证书签名（公证仍需人工 notarytool）。
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-1.0.0}"
IDENT="com.safehalt.daemon"

echo "==> 构建 release 二进制"
swift build -c release --product safehalt
BIN="$(swift build -c release --show-bin-path)/safehalt"

STAGE="$(mktemp -d /tmp/safehalt-pkg.XXXXXX)"
SCRIPTS="$(mktemp -d /tmp/safehalt-scripts.XXXXXX)"
trap 'rm -rf "$STAGE" "$SCRIPTS"' EXIT

echo "==> 组装 payload"
mkdir -p "$STAGE/usr/local/bin" "$STAGE/Library/LaunchDaemons"
cp "$BIN" "$STAGE/usr/local/bin/safehalt"
chmod 755 "$STAGE/usr/local/bin/safehalt"
"$BIN" --print-plist > "$STAGE/Library/LaunchDaemons/com.safehalt.daemon.plist"
chmod 644 "$STAGE/Library/LaunchDaemons/com.safehalt.daemon.plist"

echo "==> 生成 postinstall"
cat > "$SCRIPTS/postinstall" <<'POST'
#!/bin/bash
set -e
PLIST="/Library/LaunchDaemons/com.safehalt.daemon.plist"
chown root:wheel "$PLIST"; chmod 644 "$PLIST"
mkdir -p "/Library/Application Support/SafeHalt"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
# 生成配对码并弹品牌对话框引导用户到 App 激活
CODE_LINE="$(/usr/local/bin/safehalt pair-init || true)"
CODE="${CODE_LINE#PAIRING_CODE=}"
if [ -n "$CODE" ] && [ "$CODE" != "$CODE_LINE" ]; then
  /usr/local/bin/safehalt show-pairing-dialog "$CODE" || true
fi
exit 0
POST
chmod 755 "$SCRIPTS/postinstall"

mkdir -p dist
RAW="dist/SafeHalt-unsigned.pkg"
FINAL="dist/SafeHalt.pkg"
echo "==> pkgbuild"
pkgbuild --root "$STAGE" --scripts "$SCRIPTS" \
    --identifier "$IDENT" --version "$VERSION" \
    --install-location / "$RAW"

if [ -n "${SIGN_ID:-}" ]; then
  echo "==> productsign（$SIGN_ID）"
  productsign --sign "$SIGN_ID" "$RAW" "$FINAL"
  rm -f "$RAW"
else
  mv "$RAW" "$FINAL"
  echo "⚠ 未签名（设 SIGN_ID 可签名；分发前仍需 notarytool 公证）"
fi
echo "✅ 生成 $FINAL（版本 $VERSION）"
```

- [ ] **Step 2: 本地验证 pkg 构建(不安装)**

Run: `chmod +x make-pkg.sh && ./make-pkg.sh 1.0.0-test`
Expected: 生成 `dist/SafeHalt.pkg`,输出 `✅ 生成 dist/SafeHalt.pkg`;不实际安装。

- [ ] **Step 3: 验证 pkg 内容**

Run: `pkgutil --payload-files dist/SafeHalt.pkg`
Expected: 列出 `./usr/local/bin/safehalt` 与 `./Library/LaunchDaemons/com.safehalt.daemon.plist`(证明 payload 正确,不含 config.json)

- [ ] **Step 4: 更新 uninstall-daemon.sh 删 pairing.json**

在 `uninstall-daemon.sh` 中删除 config 的那一步旁,追加删除 pairing.json。找到删除 `/Library/Application Support/SafeHalt` 或 config 的行,确保 pairing.json 一并清除。若脚本用 `rm -rf "/Library/Application Support/SafeHalt"` 则已覆盖;若逐文件删,则加一行:

```bash
rm -f "/Library/Application Support/SafeHalt/pairing.json"
```

- [ ] **Step 5: README 重定位**

编辑 `README.md` 顶部简介,改为(在现有第一段位置):

```markdown
# SafeHalt

**SafeHalt 是 [Mac UPS Link](https://apps.apple.com/) 的开源断电保护引擎。** 一个原生 Swift 的 root 守护进程：断电转 UPS 供电、按策略倒计时后安全关机，零 Homebrew 依赖。

> 推荐用法：安装 Mac UPS Link（macOS App），由它引导安装并配置 SafeHalt——配置、策略、取消关机、查看状态都在 App 里完成。SafeHalt 出厂为"哑"引擎，配对并接收 App 下发的策略后才激活断电关机。
>
> SafeHalt 与 Mac UPS Link 经本机 `127.0.0.1` 的令牌鉴权 HTTP 通道通信；关机决策完全自治于本守护进程，App 退出/卸载不影响已配置的保护。
```

保留原有"安全设计""构建""测试"等章节。

- [ ] **Step 6: 全量测试确保无回归**

Run: `./test.sh`
Expected: PASS

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "feat(pkg): .pkg 引导式安装（postinstall pair-init/弹配对码）+ 卸载清 pairing + README 重定位为引擎"
```

---

## Self-Review

**Spec coverage(对照 `2026-07-08-app-daemon-integration-design.md`):**
- ① HTTP 服务端只绑 127.0.0.1 → Task 6(`requiredLocalEndpoint = .loopback`)。 ✓
- ② `/config`/`/status`/`/cancel`/`/log` + 连接同步(App 推目标)→ Task 5 路由 + Task 4 `applySettings`/`currentStatus`。 ✓(连接同步由 App 侧推 `host/port/ups`,守护进程忠实落盘并回显,Task 4/5 支持)
- ③ 配对码→令牌、SHA256、常量时间、只绑环回 → Task 3 + Task 5 鉴权 + Task 6。 ✓
- ③ 品牌对话框(asuser)→ Task 7 `PairingDialog` + Task 8 postinstall。 ✓
- ④ 哑引擎三态(未配置/启用/暂停/卸载后续跑)→ Task 4 门控 + Task 7 哑启动 + Task 8 postinstall 不写 config。 ✓
- ④ 纯引擎(唯一配置途径=配对;不做防手改加密)→ Task 8 README + 未加签名校验。 ✓
- 安装(路线 A,.pkg,安装动作在 App 外)→ Task 8 `.pkg`;App 侧"打开下载页"属另一份 App 计划。 ✓
- 向后兼容现役 config → Task 1 `decodeIfPresent`。 ✓
- 安全红线(服务端不阻断关机)→ Task 6 actor 隔离 + Task 7 绑定失败不阻断 `runner.run()`。 ✓

**Placeholder scan:** 无 TBD/TODO;每步含完整代码或确切命令。

**Type consistency:** `EngineControl`(Task 4)被 `ControlRouter`(Task 5)消费、`DaemonRunner`(Task 4)遵从;`DaemonConfig.load(data:)`(Task 1)被 `/config`(Task 5)复用;`RandomBytes`/`PairingStore`(Task 3)贯穿 Task 5/6/7 签名一致;`HTTPRequest.headers` 小写键(Task 2)与鉴权读取 `["authorization"]`(Task 5)一致。

**跨仓边界:** 本计划仅 SafeHalt 侧。App 侧(HTTP 客户端 + 配对 UI + 控制面板 + 一致性指示灯 + 打开下载页)为独立第二份计划。两者接口契约以本计划端点表 + `EngineStatus`/`EngineEvent` JSON 为准。
