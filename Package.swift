// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SafeHalt",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SafeHaltCore", targets: ["SafeHaltCore"]),
        .library(name: "SafeHaltKit", targets: ["SafeHaltKit"]),
        .executable(name: "safehalt", targets: ["safehalt"])
    ],
    targets: [
        // 原生 NUT 客户端 + UPS 状态建模（无 Homebrew 依赖）
        .target(name: "SafeHaltCore"),
        // 关机决策状态机 + 守护进程循环 + 系统副作用
        .target(name: "SafeHaltKit", dependencies: ["SafeHaltCore"]),
        // 常驻可执行文件
        .executableTarget(name: "safehalt", dependencies: ["SafeHaltKit", "SafeHaltCore"]),
        .testTarget(name: "SafeHaltCoreTests", dependencies: ["SafeHaltCore"]),
        .testTarget(name: "SafeHaltKitTests", dependencies: ["SafeHaltKit"])
    ]
)
