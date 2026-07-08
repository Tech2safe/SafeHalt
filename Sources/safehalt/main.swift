import Foundation
import SafeHaltCore
import SafeHaltKit

// 子命令：cancel（写取消标志后退出）
if CommandLine.arguments.dropFirst().first == "cancel" {
    FileManager.default.createFile(atPath: DaemonPaths.cancelFlagFile, contents: Data())
    print("已请求取消本次关机")
    exit(0)
}

var configPath = DaemonPaths.configFile
var dryRun = false
var it = CommandLine.arguments.dropFirst().makeIterator()
while let arg = it.next() {
    switch arg {
    case "--config": if let p = it.next() { configPath = p }
    case "--dry-run": dryRun = true
    case "--print-plist": print(DaemonPlist.launchd()); exit(0)
    default: break
    }
}

do {
    let config = try DaemonConfig.load(path: configPath)
    let runner = DaemonRunner(
        settings: config,
        transportFactory: { NUTSocketSession(host: $0, port: $1) },
        actions: RealSystemActions(dryRun: dryRun))
    FileHandle.standardError.write(Data("[safehalt] 启动，轮询 \(config.host):\(config.port)/\(config.ups)，dry-run=\(dryRun)\n".utf8))
    await runner.run()
} catch {
    FileHandle.standardError.write(Data("[safehalt] 配置加载失败 \(configPath): \(error)\n".utf8))
    exit(1)
}
