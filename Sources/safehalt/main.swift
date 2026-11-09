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
let eventStore = EventStore(path: DaemonPaths.eventsFile)
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
    },
    initialEvents: eventStore.load(),
    persistEvents: { eventStore.save($0) })

let router = ControlRouter(
    engine: runner,
    pairing: PairingStore(path: DaemonPaths.pairingFile),
    random: Pairing.secureRandom,
    now: { Date() },
    touchCancel: { FileManager.default.createFile(atPath: DaemonPaths.cancelFlagFile, contents: Data()) })

let server = ControlServer(port: UInt16(DaemonPaths.httpPort), router: router)
// 安全铁律：控制服务端在独立 Task 里启动，绝不排在保护循环之前。
// 即便它启动慢或失败，runner.run() 也立即开跑——断电保护不被服务端拖延分毫。
Task {
    do {
        try await server.start()
        FileHandle.standardError.write(Data("[safehalt] 控制服务端已绑定 127.0.0.1:\(DaemonPaths.httpPort)\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("[safehalt] 控制服务端启动失败（不影响断电保护）：\(error)\n".utf8))
    }
}

await runner.run()
