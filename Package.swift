// swift-tools-version: 6.0
// LiteStats — 轻量 macOS 原生系统监控（刘海 / 灵动岛）
//
// 注意：本机只装了 Command Line Tools（无完整 Xcode），因此所有 swift/swiftc 命令
// 都需要 `--disable-sandbox`（SwiftPM 的 sandbox-exec 在受限环境下无法 apply）。
import PackageDescription

let package = Package(
    name: "LiteStats",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LiteStats", targets: ["LiteStats"]),
        .executable(name: "litestats-probe", targets: ["LiteStatsProbe"]),
        .library(name: "LiteStatsCore", targets: ["LiteStatsCore"]),
    ],
    targets: [
        // 传感器层：纯数据 + 系统调用，禁止依赖 AppKit/SwiftUI。
        .target(name: "LiteStatsCore"),

        // 无头自检 / 命令行探针，用于验证传感器数值是否真实合理。
        .executableTarget(name: "LiteStatsProbe", dependencies: ["LiteStatsCore"]),

        // 应用层：AppKit 窗口 + SwiftUI 面板。
        .executableTarget(name: "LiteStats", dependencies: ["LiteStatsCore"]),

        .testTarget(name: "LiteStatsCoreTests", dependencies: ["LiteStatsCore"]),
    ]
)
