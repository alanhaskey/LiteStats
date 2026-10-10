# LiteStats

macOS 原生轻量系统监控。**信息不占菜单栏、不进 Dock，全部收进屏幕顶部的刘海（灵动岛）里**：
鼠标悬浮刘海 → 面板下坠展开显示 CPU（总体 + 每核心）、GPU、内存、网络、磁盘；鼠标移开 → 自动收起。

> 为什么要自己做：Stats 信息量大、常驻开销高，很多东西用不上也没法裁剪。
> LiteStats 只做一件事——把最关键的几项系统状态，放在你本来就一直在看的位置。

---

## 快速开始

```bash
./scripts/build-app.sh          # 组装 .app（本机只有 Command Line Tools，全走 SPM）
open "dist/LiteStats.app"       # 启动：常驻后台，无 Dock 图标
```

启动后**把鼠标移到屏幕顶部的刘海上**（刘海左右各 26pt 也算），面板会在 0.1s 后下坠展开。

| 操作 | 行为 |
| --- | --- |
| 鼠标移到刘海 | 0.1s 后展开，数据 1s 刷新 |
| 鼠标移到面板上 | 保持展开，可以慢慢看 |
| 鼠标移开 | 0.35s 后收起，采样自动降到 2s 一次 |
| 点击刘海/面板 | 固定展开（再点一次取消固定，随后鼠标移开会收起） |
| 菜单栏仪表盘图标 | 展开/收起、采样间隔、当前自身开销、退出 |
| 退出 | 菜单栏图标 → 退出 LiteStats；或 `pkill -f 'LiteStats.app/Contents/MacOS/LiteStats'` |

开发命令：

```bash
./scripts/run.sh                   # 前台运行（Ctrl-C 退出）
./scripts/run.sh --selftest        # 无头自检：几何 + 窗口 + 真实离屏渲染 + 传感器
./scripts/run.sh --benchmark 45    # 报告自身 CPU / 内存开销，跑完退出
./scripts/test.sh                  # 单元测试 + 泄漏压测
./scripts/e2e-hover-test.sh        # 端到端悬浮测试（会短暂移动光标，结束自动还原）
```

## 面板内容

```
CPU 15 核                                [CPU 60 点折线]
14.1%                                    负载 3.73 4.14 4.31
用户 9% · 系统 5% · 空闲 86%
────────────────────────────────────────────────────────
▮▮▯▯▯▮▯▯▯▯▯▯▯▯▯   ← 15 个核心各一根条，颜色随负载变（绿→琥珀→红），下面是各自百分比
0  0  0  1  1 24 19 19 15 12 46 28 20 14 13
────────────────────────────────────────────────────────
GPU 86%          内存 66%              网络
[███████░]       [██████░░]            ╱╲___  双线：下行(绿)/上行(橙)
显存 1.8 GB      15.9 GB / 24.0 GB     ↓ 68.2 KB/s ↑ 4.0 KB/s
────────────────────────────────────────────────────────
磁盘 42% 已用 · 可用 537.2 GB · en0              已开机 2 天 4 小时
```

## 实测开销

`--benchmark` 让 App **自己**用 `getrusage` + `task_info(mach_task_self())` 报告，
口径与活动监视器一致（本机沙箱里 `ps`/`top` 不可用，这样反而更准）。
5 段共 45s，本机 MacBook Pro M5 Pro / macOS 27.0.1 / 1800×1169 内置刘海屏：

| 阶段 | 平均 CPU | 物理占用 | RSS |
| --- | --- | --- | --- |
| ① 完全空闲（采样器与悬浮轮询全停） | 0.14 % | 10.0 MB | 51 MB |
| ② **收起态常驻**（采样 2s + 悬浮判定 0.1s） | **0.09 %** | **10.1 MB** | 51.6 MB |
| ③ 展开态（采样 1s + 面板渲染中） | 1.01 % | 17.5 MB | 68 MB |
| ④ 再收起 | 0.11 % | 14.9 MB | 67.8 MB |
| ⑤ 展开但停止采样（区分"持续重绘"与"每次更新重绘"） | 0.67 % | 16.9 MB | 67.7 MB |

**日常状态（面板收起）≈ 0.1 % CPU / 10 MB 物理占用**；只有鼠标停在面板上的那几秒约 1 %。
单次采样 0.3–1.0 ms（debug 约 3 ms），GPU 按 `gpuRefreshEveryNTicks` 隔拍读取。

开销从哪来（分层隔离实验，每层叠加后跑 8s）：

| 叠加的东西 | 平均 CPU |
| --- | --- |
| 裸 AppKit `.accessory` 应用（无窗口无定时器） | 0.165 % |
| + 菜单栏图标 | 0.307 % |
| + 状态级透明浮层窗口（灵动岛本体） | 0.602 % |
| + SwiftUI 内容（收起态） | 0.801 % |
| + 0.1s 悬浮轮询定时器 | 0.846 % |
| + 每 2s 采一次（CPU + 内存） | 0.953 % |

> 也就是说：**开销主要来自"常驻透明浮层 + SwiftUI"这个设计本身，而不是我的轮询/采样逻辑**——
> 10 Hz 悬浮轮询只占 0.045 %，采样只占 0.1 %。

### 两个关键优化（都有实测支撑）

1. **收起时完全不构建 SwiftUI 视图树**（而不是设成 `opacity(0)`）。
   只要内容存在，SwiftUI 就会初始化渲染管线：物理占用 **101.5 MB → 10.3 MB**。
2. **不用 `.ultraThinMaterial` 毛玻璃**。灵动岛本体就是纯黑，实色更还原；且少一个
   `NSVisualEffectView` 背景滤镜（实测对内存影响不大，但少一层合成）。
   同时 GPU 只读 `PerformanceStatistics` 单个属性（不是 `IORegistryEntryCreateCFProperties`），
   并用 `IORegistryEntryCreateProperty` 缓存句柄 —— 快 50 倍。

## 无泄漏

`./scripts/test.sh` 里包含逐传感器的泄漏压测（常驻工具最怕这个）：

```
[soak] CPUSensor: 20000 拍 RSS +0.05 MB → 2.5 B/拍
[soak] NetworkSensor: 20000 拍 RSS +0.05 MB → 2.5 B/拍
[soak] GPUSensor: 20000 拍 RSS +0.02 MB → 0.8 B/拍
[soak] SystemMonitor(全部传感器): 10000 拍 RSS +0.08 MB → 8.2 B/拍
```

> 这几 B/拍是 malloc arena 噪声：把拍数从 6000 加到 30000，增长不随之线性增长（反而摊薄到 3 B/拍）。
> `host_processor_info` 返回的内核 vm 内存有 `vm_deallocate`，`mach_host_self()` 的 send right 有归还。

## 目录结构

```
Package.swift                 # 唯一构建清单
Sources/LiteStatsCore/        # 传感器层：纯数据 + 系统调用，不依赖 AppKit/SwiftUI
  Models.swift                #   对外数据模型（公开接口）
  SamplingMath.swift          #   纯函数：tick 差分、速率换算（可单测）
  CPUSensor.swift             #   host_processor_info + getloadavg
  MemorySensor.swift          #   host_statistics64 + swap
  GPUSensor.swift             #   IOKit IOAccelerator，句柄缓存
  NetworkSensor.swift         #   getifaddrs / IFMIB，主接口识别
  DiskSensor.swift            #   statfs
  SystemMonitor.swift         #   编排 + 线程安全
Sources/LiteStatsProbe/       # 无头探针 CLI（人类可读 + --json JSONL）
Tests/LiteStatsCoreTests/     # 44 个测试：纯函数边界、传感器降级、契约、泄漏压测
Sources/LiteStats/            # 应用层
  App/                        #   启动装配、菜单栏、偏好、自检、开销测量
  Notch/                      #   屏幕几何、浮层窗口、悬浮状态机
  Monitor/                    #   采样调度 + 历史环形缓冲
  UI/                         #   SwiftUI 面板（岛形轮廓、指标区块、迷你折线）
  Support/                    #   格式化、诊断日志
docs/architecture.md          # 架构、坐标系约定、接口契约、验收标准
scripts/                      # 构建 / 运行 / 测试 / 端到端脚本
tools/cursor-warp.swift       # 端到端测试用的光标移动小工具
```

## 关键实现约定（踩过的坑）

- **窗口层级 `.statusBar(25)`**：低于菜单栏（`.mainMenu = 24`）会收不到刘海区域的鼠标事件。
- **必须重写 `constrainFrameRect`**：AppKit 默认把窗口往下压以避免遮挡菜单栏，会让贴顶的岛颈错位。
- **展开 frame 必须完整包含收起 frame**：否则鼠标从刘海往面板移动途中会触发"移出"→ 收起 → 又进入
  → 展开，面板疯狂抖动。
- **菜单栏带比物理刘海高 1pt**（本机 39 vs 38）：岛颈要画到菜单栏底边，才能和面板体无缝相接。
- **收起态窗口完全不绘制**（自检断言整张离屏位图最大 alpha = 0）→ 绝不会遮挡菜单栏。
- **`NSEvent.mouseLocation` 是左下原点**，CG 坐标是左上原点，两套坐标不能混。
- **Swift 6 + `DispatchSource.setEventHandler`**：参数类型没标 `@Sendable`，闭包会继承外层的
  `@MainActor` 隔离，被后台队列调用时运行时会反复报 data race → 必须显式写 `{ @Sendable in }`。
- **`task_info(MACH_TASK_BASIC_INFO)` 的 CPU 时间在本机不可靠**（长时间不更新，会报出 0 ms），
  改用 POSIX `getrusage`。
- **`/usr/bin/time -l` 的 maximum RSS 是峰值**，用它对比不同时长的运行来判泄漏会得出假结论。

## 本机环境注意

- 只有 Command Line Tools，没有完整 Xcode → **不能用 `xcodebuild`**，全走 SPM。
- SwiftPM 的 `sandbox-exec` 在此环境不可用 → 所有 swift 命令都要 `--disable-sandbox`（脚本已内置）。
- `~/Library/Caches/org.swift.swiftpm` 可能不可写（只是警告，无害）。
- `swift-testing` 的宏插件路径有时解析不到（`plugin for module 'TestingMacros' not found`），
  `scripts/test.sh` 已显式传 `-Xswiftc -plugin-path ...` 绕过。
- 屏幕录制权限未授予 → 无法 `screencapture`。因此视觉验证改用**进程内离屏渲染**
  （`--selftest --dump-render`），照样能看到真实画面。

## 验证记录（本机实测原始输出）

| 项目 | 命令 | 结果 |
| --- | --- | --- |
| 单元测试 + 泄漏压测 | `./scripts/test.sh` | ✔ 44 tests in 6 suites passed |
| 无头自检 | `LiteStats --selftest` | **35/35 通过**（几何不变式、窗口层级、真实渲染、传感器数值） |
| 端到端悬浮 | `./scripts/e2e-hover-test.sh` | **PASS**，日志：`state=expanded mouse=(900.0,1150.0)` → `state=collapsed mouse=(900.0,569.0)` |
| 传感器数值 | `litestats-probe --seconds 4` | `cores=15 cpu 9.5% gpu 62% mem 15.4G/24.0G net en0 ↓550B/s disk 42.1% sampleMs 0.35–1.88` |
| 自身开销 | `LiteStats --benchmark 45` | 见上表 |
| 稳定性 | 12000 拍压测 | 无崩溃、无线性内存增长 |

离屏渲染验证（`--dump-render`）产出的真实画面：岛颈贴合刘海、面板体圆角与阴影、
15 个核心条、三条迷你折线、页脚 —— 全部按设计渲染，无文字截断。

## 还没做

- 温度 / 风扇（需要 SMC 或 IOHIDEventSystem，权限与机型差异大）
- 进程列表 / 单进程占用
- 阈值告警（CPU 持续 100%、内存压力、磁盘将满）
- 开机自启（LaunchAgent）
- 收起态常驻小指示条（现在收起时完全不可见，靠"知道刘海在哪"来用）
- 签名与公证（目前 ad-hoc 签名，仅本机可用；要分发给别人需要开发者证书）
