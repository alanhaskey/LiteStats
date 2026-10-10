# LiteStats 架构

macOS 原生轻量系统监控。信息锚定在 MacBook 刘海（灵动岛）区域，鼠标悬浮刘海时展开面板。

## 0. 为什么要自己做

Stats 这类工具常驻开销较大（多进程、多定时器、每指标独立轮询）且不可裁剪。LiteStats 的取舍：

| 目标 | 做法 |
| --- | --- |
| 低常驻开销 | 单一定时器（默认 1 Hz）+ 单后台串行队列；IOKit 句柄缓存；GPU 隔拍采样 |
| 无 Dock 图标 | `LSUIElement = true` + `NSApp.setActivationPolicy(.accessory)` |
| UI 只在需要时渲染 | 收起态只做几何命中判定；展开时才渲染 SwiftUI 视图树 |
| 不干扰菜单栏 | 展开面板位于菜单栏下方，不覆盖菜单项 |

## 1. 本机环境事实（实测）

- MacBook Pro `Mac17,9`，Apple M5 Pro（15 逻辑核心），24 GB 统一内存，macOS 27.0.1 (26A434)。
- 只有 Command Line Tools，**没有完整 Xcode** → 不能用 `xcodebuild`/`.xcodeproj`，全部走 SPM。
- SwiftPM 的 `sandbox-exec` 在本环境不可用 → 所有命令需加 `--disable-sandbox`。
- `~/Library/...` 在受限环境下可能不可写 → 用 `--scratch-path .build`（包内）。
- 屏幕：1800×1169 pt，`safeAreaInsets.top = 38`，
  `auxiliaryTopLeftArea = (0, 1131, 790, 38)`，`auxiliaryTopRightArea = (1010, 1131, 790, 38)`
  → **刘海矩形 = (790, 1131, 220, 38)**（AppKit 全局坐标，原点左下）。
- 屏幕录制权限未授予 → 不能用 `screencapture` 做视觉验证，改用「几何自检 + 真实运行指标 + 人工确认」。

## 2. 目录与职责

```
Package.swift                 # 唯一构建清单，由 Lead 维护
Sources/LiteStatsCore/        # 传感器层（core-agent 负责）：纯数据 + 系统调用，禁止 import AppKit/SwiftUI
Sources/LiteStatsProbe/       # 无头探针 CLI（core-agent 负责）：验证真实数值
Tests/LiteStatsCoreTests/     # 纯函数单测（core-agent 负责）
Sources/LiteStats/            # 应用层（Lead 负责）：AppKit 窗口 + SwiftUI 面板
docs/architecture.md          # 本文件
scripts/build-app.sh          # 组装 .app
```

## 3. LiteStatsCore 公开接口（**已冻结**，签名不得改动）

```swift
public struct MonitorConfiguration: Sendable {
    public var gpuRefreshEveryNTicks: Int   // 默认 2
    public var includeDisk: Bool            // 默认 true
    public init(gpuRefreshEveryNTicks: Int = 2, includeDisk: Bool = true)
}

public struct CPUStats: Sendable, Equatable {
    public let total, user, system, idle: Double        // 0...1
    public let perCore: [Double]                        // count == coreCount
    public let coreCount: Int
    public let load1, load5, load15: Double
}

public struct MemoryStats: Sendable, Equatable {
    public let total, used, free, active, inactive, wired, compressed, cached: UInt64
    public let swapTotal, swapUsed: UInt64
    public var usage: Double { get }
}

public struct GPUStats: Sendable, Equatable {
    public let name: String?
    public let utilization: Double?          // nil = 取不到
    public let inUseMemory: UInt64?
    public let allocatedMemory: UInt64?
}

public struct NetworkStats: Sendable, Equatable {
    public let download, upload: Double      // bytes/sec
    public let received, sent: UInt64        // 累计
    public let interfaceName: String?
    public let isConnected: Bool
}

public struct DiskStats: Sendable, Equatable {
    public let total, free, used: UInt64
    public var usage: Double { get }
}

public struct SystemSnapshot: Sendable {
    public let timestamp: Date
    public let cpu: CPUStats
    public let memory: MemoryStats
    public let gpu: GPUStats
    public let network: NetworkStats
    public let disk: DiskStats?
    public let uptime: TimeInterval
    public let thermalState: ProcessInfo.ThermalState
    public let sampleIndex: Int              // 0 = 基线采样
}

public enum CPUUsageMath {
    public static func compute(previous: [UInt32], current: [UInt32], coreCount: Int)
        -> (total: Double, user: Double, system: Double, idle: Double, perCore: [Double])
}

public enum NetworkRateMath {
    public static func bytesPerSecond(previous: UInt64, current: UInt64, interval: TimeInterval) -> Double
}

public final class SystemMonitor: @unchecked Sendable {
    public init(configuration: MonitorConfiguration = .init())
    public var configuration: MonitorConfiguration { get set }
    public var coreCount: Int { get }
    public func sample() -> SystemSnapshot   // 线程安全；首次调用返回基线（增量=0）
    public func reset()
}
```

约定：
- `sample()` 可在任意线程调用；内部状态用锁保护。
- 取不到的指标用 `nil` / 0，**不要抛错**，不要阻塞超过 ~10 ms。
- 不做定时器：调度由应用层负责（核心层只提供「被调用一次 = 采样一次」）。
- 不依赖 AppKit/SwiftUI/Foundation 之外的第三方库。

## 4. 传感器实现选型（已实测可用）

| 指标 | API | 备注 |
| --- | --- | --- |
| CPU 总体/每核心 | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | 15 核 tick 数组，需 `vm_deallocate` |
| 负载 | `sysctl vm.loadavg` / `getloadavg()` | |
| 内存 | `host_statistics64(HOST_VM_INFO64)` + `host_page_size` | `used = active + wired + compressed` |
| Swap | `sysctl vm.swapusage` | |
| GPU | `IOServiceMatching("IOAccelerator")` → `PerformanceStatistics["Device Utilization %"]` | 实测 `AGXAcceleratorG17X`，**缓存句柄**，别每拍全量枚举 |
| 网络 | `getifaddrs` + `if_data`（`AF_LINK`） | 主接口优先用 `SCDynamicStore` 的 `State:/Network/Global/IPv4 → PrimaryInterface`，避免 utun/bridge 重复计数 |
| 磁盘 | `statfs("/")` | `f_blocks/f_bavail × f_bsize` |
| 开机时长/热状态 | `ProcessInfo` | |

## 5. 窗口层设计（Lead）

- 单个 `NSPanel`：`styleMask = [.borderless, .nonactivatingPanel]`，`isFloatingPanel = true`，
  `level = .mainMenu + 1`（25，即 status 级，仍低于 popUpMenu/screensaver），
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`，
  透明背景、`hasShadow = false`、`canBecomeKey = false`。
- 收起态：窗口 = 刘海矩形左右各外扩 26 pt（268×38）的悬浮热区。此区域在菜单栏带内，
  但刘海处本身无像素、两侧通常是菜单栏空白区，吞掉点击无副作用（原生在此也没有点击行为）。
- 展开态：窗口 frame **必须包含收起态 frame**（否则鼠标从刘海移到面板途中会触发 exit → 抖动），
  即 frame = 顶部 38 pt 菜单栏带 + 下方面板体，宽度 = 面板宽（420）。
  面板体顶边正好贴菜单栏底边，因此常规情况下不遮挡菜单项；仅在悬浮展开期间临时占据
  刘海左右各 100 pt 的菜单栏空白带。
- 状态机：`collapsed → (hover 0.08 s) → expanded → (exit 0.35 s 延迟) → collapsed`；
  0.2 s 的安全轮询（仅在收起态）兜底 tracking area 漏掉的 enter 事件，避免全局鼠标监听。
- 无刘海屏幕（外接显示器）：回退为菜单栏下方居中的常驻小胶囊，交互一致。
- 屏幕参数变化（`NSApplication.didChangeScreenParametersNotification`）重新计算几何。

## 6. 验收标准

1. `swift build --disable-sandbox` 与 `swift test --disable-sandbox` 通过。
2. `swift run --disable-sandbox litestats-probe --seconds 5` 输出真实值：
   15 个核心、内存 total ≈ 24 GiB、GPU 利用率非 nil、网速在有大流量时 > 0。
3. App 启动后进程存活，`ps` 测得平均 CPU < 1.0%、RSS < 60 MB（1 Hz 采样）。
4. 窗口几何自检：`--selftest` 打印收起/展开 frame 并与刘海几何对齐（误差 0）。
5. 人工确认：悬浮刘海 → 面板下坠展开；移开 → 收起；不遮挡菜单栏。
