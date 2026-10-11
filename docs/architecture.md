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

## 6. 验收标准与实测结果

| # | 标准 | 结果 |
| --- | --- | --- |
| 1 | `swift build` / `swift test` 通过 | ✅ 64 tests in 8 suites passed（`scripts/test.sh`） |
| 2 | 探针输出真实值 | ✅ `cores=15 gpu 62-73% mem 15.4G/24.0G net en0 disk 42.1% cpuTemp 63°C fans 4092/4425rpm` |
| 3 | 常驻 CPU < 1 %、内存 < 60 MB | ✅ 收起态 **0.08 % / 14.2 MB 物理占用**（RSS 53.5 MB） |
| 4 | 窗口几何与刘海对齐、展开包含收起 | ✅ `--selftest` 52/52 通过 |
| 5 | 悬浮展开 / 移开收起 / 不遮菜单栏 | ✅ 端到端光标测试 PASS；收起态离屏位图最大 alpha = 0 |
| 6 | 常驻指示条可配、可关、不破坏常驻开销 | ✅ 自检 62/62 含指示条几何/绘制断言：两侧等长、内容居中、没指标不画、展开不多耳朵 |
| 7 | 设置界面可开、可渲染、可持久化 | ✅ 自检对设置窗口做离屏渲染断言（覆盖率 99.8 %） |
| 8 | 温度/风扇可读且不拖垮开销 | ✅ 三级节流后单次读取 ≤ 8 ms；无人查看时降到 30 拍一次 |

补充实测（6 段 60s `--benchmark`，两次运行取一致值）：收起态 0.07–0.08 %、展开态 0.80–1.02 %、
展开静态重绘地板 0.33 %、完全空闲 0.12–0.18 %。
无泄漏（`scripts/soak.sh` 单进程 20000 拍）：全部传感器 0.8 B/拍。

## 7. 后期修正（与初版设计的差异）

1. **收起态不构建 SwiftUI 视图树**（原设计是 `opacity(0)` 保留视图）。
   实测只要内容存在，SwiftUI 就初始化渲染管线，物理占用 101.5 MB；改为条件构建后降到 10.3 MB。
   代价：首次悬浮时现构建视图树（实测无感）。
2. **弃用 `.ultraThinMaterial`**：灵动岛本体是纯黑，实色更还原，且少一层背景滤镜。
3. **CPU 计量改用 `getrusage`**：`task_info(MACH_TASK_BASIC_INFO)` 的 user_time/system_time
   在本机会长时间不更新，导致"采样 8 次却报告 0 ms"的假数据。
4. **`setEventHandler` 闭包必须标 `@Sendable`**：否则继承 `@MainActor` 隔离，运行时刷 data race 警告。
5. **"240 字节/拍的泄漏"是误判**：`/usr/bin/time -l` 报的是峰值 RSS，
   不同时长对比会得出假结论；正确的做法是同进程内前后差值 + 加大拍数看是否线性
   （已固化为 `scripts/soak.sh`）。
6. **面板里不能用 `Image(systemName:)`**：SF Symbol 在每秒重绘时会被反复渲染，
   展开态 CPU 明显上升；改用文字标签 + `Canvas` 绘制。
7. **每核心占用条改为单个 `Canvas`**：15 组 VStack/Shape/Text（≈45 个视图）→ 1 个 Canvas，
   展开态更新重绘成本显著下降。

## 8. 刘海常驻指示条与设置界面

- **指示条**：刘海左右各可选一个指标（CPU／内存／GPU／网络／磁盘／温度／风扇）。
  做法是 `NotchIndicatorView`（**纯 AppKit 手绘**，不引入 SwiftUI）——因为 SwiftUI 只要渲染就会
  拉起整条渲染管线，常驻物理占用会从 14 MB 涨到 100 MB。
  - 耳长是**统一的单一配置**（`Preferences.earWidth`，默认 88pt），两侧等长、与内容无关，数值居中；
    没选指标那一侧 `earWidth = 0`，折叠与展开都不多出耳朵（`tabRect = 刘海 + 有指标侧的黑耳`）。
  - 填充必须是**纯黑**：物理刘海是纯黑，近黑（RGB 11,11,13）在浅色壁纸下会明显色差，
    看起来像"指示条和灵动岛分离"。
  - 底边贴齐**刘海底边**而非菜单栏底边（`notchBottomInset`，本机 1pt）；
    内侧沿刘海圆角弧走，半径**故意 +2pt**（系统读不到真实圆角，宁多覆盖不留缝）。
- **布局不变式**（指示条左右宽度可能不等时尤其重要）：收起 frame 不再以刘海为对称中心，
  因此展开 frame 必须取「居中面板矩形 ∪ 收起 frame」的并集，面板体仍以刘海居中。
  自检里有对应断言（`展开 frame 仍完整包含收起 frame`、`面板体以刘海为水平居中`）。
- **设置界面**：SwiftUI `Form` + 实时刘海示意图；窗口关闭即释放 controller（连带释放 SwiftUI 图）。
  自检通过离屏渲染断言它真的画出了内容（无法用鼠标点的环境下这是唯一可行的验证）。
- **开机自启**：优先 `SMAppService.mainApp`（系统登录项可见可管理），失败退回 `~/Library/LaunchAgents` plist。

## 9. 温度/风扇的性能设计（Apple Silicon）

每次 `IOHIDServiceClientCopyEvent` 是一次 ~0.75 ms 的同步 IPC，全量读 76 个服务 = 78 ms/拍。
三级应对：轮转切片（每拍 8 个，≈7 ms，按同名实例交错排序）→ 隔拍刷新（默认 5 拍）→
自适应降频（无人查看时 30 拍，`MonitorService.thermalIsVisible`）。
另外 HID 的 76 个服务只有 17 个唯一名字，对外按名字去重保留最大值（否则 `ThermalSensor.id == name`
会出现重复 id，SwiftUI `ForEach` 会异常）。

## 10. 历史统计（本地记录）

三层数据 + 三份文件，全部定长记录、追加为主：

| 层 | 文件 | 保留 |
| --- | --- | --- |
| 分钟明细 | `minutes.bin` | 7 天 |
| 小时聚合 | `hours.bin` / `app-hours.bin` | 180 天 |
| 天聚合 | `days.bin` / `app-days.bin` | 永久 |
| 应用名表 | `app-names.bin` | 只追加 |

按应用归属的两条数据来源（都实测过）：

- **CPU / 内存**：`proc_listallpids` + `proc_pid_rusage(RUSAGE_INFO_CURRENT)`，196 个进程 **0.49 ms**；
  `ri_user_time`/`ri_system_time` 是纳秒，`ri_phys_footprint` 是字节；用 `proc_name` 取名字。
- **网络**：调用 `/usr/bin/nettop -P -x -l 1 -J bytes_in,bytes_out -n`（**单次 10 ms**），
  它给的是**进程启动以来的累计值** → 按 `(pid, 名字)` 缓存上次值做差分；PID 会复用，
  名字变了必须重置基线（所以启动后的第一拍只建立基线、没有应用流量数据）。

写入路径全部是"内存聚合 + 后台队列落盘"：`record(snapshot:)` 实测 **0.0008 ms**，
`record(appSamples:)` 0.006 ms，采集器 2.38 ms/5s。开启后常驻开销 0.07% → **约 0.15% CPU / 16 MB**。

> 踩坑：压缩/清理会为所有文件调度 `rewriteAll`，而名字表的 `rewritePayloadLocked` 返回空 Data
> （它设计上只追加）→ 第一次清理就把名字表清空，重启后应用 `path` 全丢。
> 现在 `.appNames` 跳过整体重写，并有单元测试守住。

## 11. 适配不同核心数的 Mac

**面板宽度固定（`Theme.panelWidth` = 400pt），核心数只改变每根柱子的宽度。**

列宽 = `(内容宽度 − 间距 × (核数 − 1)) / 核数`，几何部分抽成纯函数 `CoreGridLayout`：

| 核心数 | 6 | 8 | 10 | 12 | 15 | 18 | 24 | 32 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 柱宽 | 58.8pt | 43.4pt | 34.1pt | 27.9pt | **21.7pt** | 17.6pt | 13.4pt | 9.6pt |

每种核心数下柱子总宽都正好填满 368pt 内容宽，不溢出（自检逐项断言）。

两个适配点：

1. **柱下的百分比数字不能无条件画**。font 8 的等宽数字放三位数需要约 15.5pt 列宽；
   24 核只有 13.4pt、32 核 9.6pt，画上去会挤成一团。
   现在列宽 < 15.5pt 时自动隐藏数字，把高度让给柱子（信息反而更清楚）。
2. 核数 ≥ 20 时间距从 3pt 收紧到 2pt，给柱子多留宽度。

核心数取自 `ProcessInfo.processorCount`；刘海与屏幕几何逐机探测（`ScreenGeometry`）；
没有刘海的机型走顶部圆槽模式。代码里没有任何写死的机型/核心数假设。

## 12. 历史统计的两个显示 bug（1.0.3 修复）

1. **"每天负载"的悬浮提示把日期显示成了钟点**：多日视图沿用了单日的 `label + ":00"`，
   于是"10 号"显示成 `10:00`。现在统一走纯函数 `HistoryChartData.tooltipTitle`
   ——单日按钟点（`17:00`）、多日按月日（`10 月 10 日`）。
2. **每天的文字数值取了当天最后一个小时**：柱高用的是当天总和（对），但文字是逐小时覆盖
   而不是累加（错）。现在用 `HistoryChartData.dailyTotals` 按天汇总，文字与柱高同源。

两条都补了纯函数断言（跨小时相加 400 = 100 + 300、不丢小时、流量同样按天汇总）。

> 排查时还遇到一次"看起来翻倍"的假警报：探针把数据**按逆序灌入**（先记前天再记昨天），
> 命中了存储层的已知限制——加载时只合并**相邻**的同 start 记录。
> 顺序采样（真实运行的情况）实测倍数精确 1.00。**测试数据必须按时间顺序灌**，否则会误导。
