# LiteStats

macOS 原生轻量系统监控。**信息不占菜单栏、不进 Dock，全部收进屏幕顶部的刘海（灵动岛）里**：
鼠标悬浮刘海 → 面板下坠展开显示 CPU（总体 + 每核心）、GPU、内存、网络、磁盘、温度、风扇；鼠标移开 → 自动收起。
刘海两侧还能常驻一行自己选的指标（CPU／内存／GPU／网络／磁盘／温度／风扇）。

> 为什么要自己做：Stats 信息量大、常驻开销高，很多东西用不上也没法裁剪。
> LiteStats 只做一件事——把最关键的几项系统状态，放在你本来就一直在看的位置。

---

## 快速开始

```bash
./scripts/build-app.sh          # 组装 .app（本机没有可用 Xcode 工具链，全走 SPM）
open "dist/LiteStats.app"       # 启动：常驻后台，无 Dock 图标
```

启动后**把鼠标移到屏幕顶部的刘海上**（刘海左右各 26pt 也算），面板会在 0.1s 后下坠展开。

| 操作 | 行为 |
| --- | --- |
| 鼠标移到刘海 | 0.1s 后展开，数据 1s 刷新 |
| 鼠标移到面板上 | 保持展开，可以慢慢看 |
| 鼠标移开 | 0.35s 后收起，采样自动降到 2s 一次 |
| 点击刘海/面板 | 固定展开（再点一次取消固定，随后鼠标移开会收起） |
| 菜单栏仪表盘图标 | **只有「设置…」和「退出 LiteStats」**（展开/收起、采样间隔、自身开销都在设置界面里） |
| 退出 | 菜单栏图标 → 退出 LiteStats；或 `pkill -f 'LiteStats.app/Contents/MacOS/LiteStats'` |

开发命令：

```bash
./scripts/run.sh                   # 前台运行（Ctrl-C 退出）
./scripts/run.sh --selftest        # 无头自检：几何 + 窗口 + 指示条 + 离屏渲染 + 设置界面 + 传感器
./scripts/run.sh --benchmark 60    # 报告自身 CPU / 内存开销，跑完退出
./scripts/test.sh                  # 单元测试 + 泄漏压测
./scripts/e2e-hover-test.sh        # 端到端悬浮测试（会短暂移动光标，结束自动还原）
```

## 界面

### 悬浮面板

```
CPU 15 核                                [CPU 60 点折线]
10.0%                                    负载 5.17 4.52 4.02
用户 5% · 系统 5% · 空闲 90%
────────────────────────────────────────────────────────
▮▮▯▯▯▮▯▯▯▯▯▯▯▯▯   ← 15 个核心各一根条（单个 Canvas 绘制），颜色随负载变（绿→琥珀→红）
12 10  9  4  5  2  0  0  0  0 53 27 13 10  5
────────────────────────────────────────────────────────
GPU 0%           内存 68%              网络
[░░░░░░░░]       [██████░░]            ╱╲___  双线：下行(绿)/上行(橙)
显存 1.6 GB      16.4 GB / 24.0 GB     ↓ 7.6 KB/s ↑ 586 B/s
────────────────────────────────────────────────────────
温度 63°C        风扇 2709 · 2927 rpm
────────────────────────────────────────────────────────
磁盘 42% 已用 · 可用 536.0 GB · en0              已开机 2 天 5 小时
```

### 刘海常驻指示条

设置里可以给刘海左侧、右侧各选一个常驻指标。**默认一个都不选 —— 收起态什么也不画，轮廓与物理刘海完全重合，彻底藏进灵动岛里**：

| 可选 | 指示条显示 |
| --- | --- |
| CPU 占用 | `CPU 12%`（颜色随负载） |
| 内存占用 | `MEM 68%` |
| GPU 占用 | `GPU 86%`（取不到时显示 `—`，不会假装 0） |
| 网络上下行 | `↓ 1.2M ↑ 32K`（极简单位，双色） |
| 磁盘占用 | `DSK 42%` |
| CPU 温度 | `℃ 63°`（颜色随温度） |
| 风扇转速 | `FAN 2709`（多风扇取最高） |

指示条画在刘海两侧的黑色"耳朵"里——鼠标悬浮这一带同样会展开面板。
它用**纯 AppKit 手绘**（不是 SwiftUI），所以即使常驻也只多几百 KB，不会把渲染管线拉起来。

> 注意：只有真的选了指标才会画黑耳。一个都不选时收起态是**零像素**绘制
> （自检里有回归断言：`不选指标时收起态完全隐形 | 最大 alpha=0`），
> 不会出现"刘海两边莫名其妙多出黑边、看起来被撑宽"的情况。

### 展开动效（水滴形变）

展开不是简单的淡入，而是**轮廓本身在做液体形变**：

1. 起点 `progress = 0`：轮廓与物理刘海**逐像素重合**（所以在收起态它是不存在的）；
2. 岛颈先横向铺开（`pow(p, 0.5)`），面板体随后坠下（`pow(p, 1.35)`）—— 差速缓动制造"液体错位感"；
3. 面板体开始时比目标窄（0.62 倍）、底部圆角接近半圆，像一颗**水滴**挂着；随进度摊平成面板；
4. 落定用弹簧（`response 0.46 / damping 0.72`），带一点回弹；
5. 文字内容被轮廓**裁切着"挤出来"**，并且比形变晚 30% 才开始淡入，避免形变中途文字乱跳。

收起方向是对称的：轮廓先退回刘海，视图树**在形变结束后才卸载**（这样才看得到"水滴收回去"，
同时保证收起后立刻回到低常驻内存）。中间帧可以直接导出来看：
`--selftest --dump-render /tmp/x.png` 会输出 `x-morph-25/50/75.png`。

> 实现上有个必须注意的时序：**不能在同一轮 runloop 里既"挂载视图"又"把进度设成 1"**，
> 否则 SwiftUI 首次渲染看到的就是终值、没有起始值可插值，表现成"展开是瞬间出现的"。
> 现在是先以 `p=0` 挂上去，隔一次 main queue 再启动弹簧。
> 自检里有断言守着：展开过程中连续采样离屏渲染，必须采到"尺寸介于刘海和成品之间"的中间帧
> （实测时间线 `143ms:45 → 277ms:216 → 367ms:294 落定`）。

### 设置界面

菜单栏图标 → **设置…**：

- **刘海常驻指示条**：左右各选一个指标，带实时的刘海示意图
- **灵动岛**：岛颈外扩宽度 0–60 pt（不同机型刘海宽度不同，可微调；0 = 只保留物理刘海）
- **采样**：展开时刷新 / 收起时刷新
- **通用**：菜单栏图标开关、开机自启
- **关于**：版本、**本 App 当前开销**（每秒自测 CPU 与物理占用）、当前刘海几何

设置窗口关闭即释放（SwiftUI 只在窗口存在时才有渲染开销）。

开机自启优先用 `SMAppService.mainApp`（系统「登录项」里可见、可管理）；
ad-hoc 签名或不在 `/Applications` 时会自动退回写一个 `~/Library/LaunchAgents/dev.litestats.app.plist`。

## 实测开销

`--benchmark` 让 App **自己**用 `getrusage` + `task_info(mach_task_self())` 报告，
口径与活动监视器一致（本机沙箱里 `ps`/`top` 不可用，这样反而更准）。
6 段共 60s，本机 MacBook Pro M5 Pro / macOS 27.0.1 / 1800×1169 内置刘海屏：

| 阶段 | 平均 CPU | 物理占用 | RSS |
| --- | --- | --- | --- |
| ① 完全空闲（采样器与悬浮轮询全停） | 0.12 % | 14.1 MB | 53.5 MB |
| ② **收起态常驻**（采样 2s + 悬浮判定 0.1s） | **0.08 %** | **14.2 MB** | 53.5 MB |
| ③ 展开态（采样 1s + 面板渲染中） | 1.02 % | 31.1 MB | 77.0 MB |
| ④ 再收起 | 0.07 % | 31.7 MB | 77.7 MB |
| ⑤ 展开但停止采样（面板可见时的持续重绘地板） | 0.33 % | 28.2 MB | 75.1 MB |
| ⑥ 展开 + 温度高频刷新（有人看温度/风扇） | 0.09 % | 25.5 MB | 75.0 MB |

> 连跑两次复核：①②③⑤⑥ 分别是 (0.12 / 0.18)、(0.08 / 0.07)、(1.02 / 0.80)、(0.33 / 0.33)、(0.09 / 0.09)，
> 偏差在噪声范围内。注意物理占用是"面板渲染过之后"的稳态值（面板可见时会涨到 ~30 MB，
> 首次渲染前是 ~14 MB）——因为收起时不构建视图树，渲染缓存不会在收起后立刻归还。

**日常状态（面板收起）≈ 0.1 % CPU / 14 MB 物理占用**。

开销从哪来（分层隔离实验，每层叠加后跑 8s）：

| 叠加的东西 | 平均 CPU |
| --- | --- |
| 裸 AppKit `.accessory` 应用（无窗口无定时器） | 0.165 % |
| + 菜单栏图标 | 0.307 % |
| + 状态级透明浮层窗口（灵动岛本体） | 0.602 % |
| + SwiftUI 内容（收起态） | 0.801 % |
| + 0.1s 悬浮轮询定时器 | 0.846 % |
| + 每 2s 采一次（CPU + 内存） | 0.953 % |

> 也就是说：**开销主要来自"常驻透明浮层 + SwiftUI"这个设计本身，而不是轮询/采样逻辑**——
> 10 Hz 悬浮轮询只占 0.045 %，采样只占 0.1 %。

### 四个关键优化（都有实测支撑）

1. **收起时完全不构建 SwiftUI 视图树**（而不是设成 `opacity(0)`）。
   只要内容存在，SwiftUI 就会初始化渲染管线：物理占用 **101.5 MB → 10.3 MB**。
2. **面板里不用 `Image(systemName:)`（SF Symbol）**。实测展开态每秒重绘时矢量符号会被反复渲染，
   展开态 CPU 明显变高；改用文字后回落。
3. **每核心占用条用单个 `Canvas` 画完**（而不是 15 组 VStack/Shape/Text ≈ 45 个视图），
   展开态的数据更新重绘成本大幅下降。
4. **GPU 只读 `PerformanceStatistics` 单个属性**（不是 `IORegistryEntryCreateCFProperties`）+ 缓存 IOKit 句柄 —— 快 50 倍。

## 温度与风扇（Apple Silicon）

两项都能读到，**不需要 root**，但路径和 Intel 机器完全不同：

| 指标 | 路径 | 实测 |
| --- | --- | --- |
| 芯片温度 | 私有 HID：`IOHIDEventSystemClientCreateWithType(type: 1 Admin)` → `IOHIDServiceClientCopyEvent(type 15)` | 76 个服务 / 17 个唯一名字，`PMU tdie*` 最高 ~63 °C |
| 电池温度 | HID `TB0T` / `Ts0P`，或 SMC 同键兜底 | ~36 °C |
| 风扇转速 | AppleSMC `selector 2`，键 `F0Ac`/`F1Ac`（+ `F0Mn`/`F0Mx`/`F0Tg`） | ~2700 / ~2900 rpm，上限 7826 rpm |

三个必须知道的坑（都已在代码注释里写清）：

1. **HID 客户端类型必须是 1（Admin）**；类型 2（Monitor）能匹配到 77 个服务但一个读数都读不出来。
2. **未接传感器的槽位会返回垃圾值**（`PMU tdev*` 报 -9199 ~ -9203 °C）。只接受 `(0, 125]` 区间，否则界面上会出现 -9201°C。
3. **`SMCKeyData` 结构体必须精确 80 字节**：Swift 里 `dataSize/dataType/attrs` 之后要手动补 3 个 pad，
   否则 selector 2 直接返回 `0xE00002C2 (kIOReturnBadArgument)`，所有键都读不到。

### 温度的读取成本（它唯一"贵"的地方）

Apple Silicon 上每次 `IOHIDServiceClientCopyEvent` 都是一次 **~0.75 ms 的同步 IPC**（实测），
所以"每拍全量读 76 个传感器" = **78 ms/拍**，按 1 Hz 折算就是 1.8 % CPU——会直接毁掉常驻开销目标。三级应对：

1. **轮转切片**：每次只读 8 个服务（≈7 ms），按"同名实例交错"排序，保证每个传感器名字在 2 次刷新内被采到；
2. **隔拍刷新**：默认每 5 拍读一次（`MonitorConfiguration.thermalRefreshEveryNTicks`）；
3. **自适应降频**：没人看温度时（面板收起且指示条没选温度/风扇）自动放宽到每 30 拍一次
   （`MonitorService.thermalIsVisible`），折算 ≈0.03 % CPU。

> 另外：HID 有 76 个"服务"但只有 17 个**唯一名字**（同名实例读数不同）。
> 冻结的 `ThermalSensor.id == name`，所以对外按名字去重并保留最大值，否则 SwiftUI `ForEach` 会因重复 id 异常。

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
  ThermalHIDReader.swift      #   私有 HID 温度（Admin 客户端 + 轮转切片）
  SMCReader.swift             #   AppleSMC（80 字节结构体）+ 键值解析
  ThermalSampler.swift        #   温度/风扇编排 + 垃圾值过滤 + 降级
  SystemMonitor.swift         #   编排 + 线程安全
Sources/LiteStatsProbe/       # 无头探针 CLI（人类可读 + --json JSONL）
Tests/LiteStatsCoreTests/     # 单元测试：纯函数边界、传感器降级、契约、泄漏压测
Sources/LiteStats/            # 应用层
  App/                        #   启动装配、菜单栏、偏好、设置窗口、开机自启、自检、开销测量
  Notch/                      #   屏幕几何、浮层窗口、悬浮状态机、常驻指示条（AppKit 手绘）
  Monitor/                    #   采样调度 + 历史环形缓冲 + 温度自适应降频
  UI/                         #   SwiftUI 面板（岛形轮廓、指标区块、迷你折线、设置界面）
  Support/                    #   格式化、诊断日志
docs/architecture.md          # 架构、坐标系约定、接口契约、验收标准
scripts/                      # 构建 / 运行 / 测试 / 端到端脚本（含环境适配）
tools/cursor-warp.swift       # 端到端测试用的光标移动小工具
```

## 关键实现约定（踩过的坑）

- **窗口层级 `.statusBar(25)`**：低于菜单栏（`.mainMenu = 24`）会收不到刘海区域的鼠标事件。
- **必须重写 `constrainFrameRect`**：AppKit 默认把窗口往下压以避免遮挡菜单栏，会让贴顶的岛颈错位。
- **展开 frame 必须完整包含收起 frame**：否则鼠标从刘海往面板移动途中会触发"移出"→ 收起 → 又进入 → 展开，面板疯狂抖动。
  指示条左右宽度不等时，收起 frame 不再以刘海为对称中心，展开 frame 必须**取并集**而不是"宽度取大"。
- **菜单栏带比物理刘海高 1pt**（本机 39 vs 38）：岛颈要画到菜单栏底边，才能和面板体无缝相接。
- **收起态默认完全不绘制**（自检断言整张离屏位图最大 alpha = 0）→ 绝不会遮挡菜单栏；开了指示条则只画两侧黑耳。
- **`NSEvent.mouseLocation` 是左下原点**，CG 坐标是左上原点，两套坐标不能混。
- **Swift 6 + `DispatchSource.setEventHandler`**：参数类型没标 `@Sendable`，闭包会继承外层 `@MainActor` 隔离，
  被后台队列调用时运行时会反复报 data race → 必须显式写 `{ @Sendable in }`。
- **`task_info(MACH_TASK_BASIC_INFO)` 的 CPU 时间在本机不可靠**（长时间不更新，会报出 0 ms），改用 POSIX `getrusage`。
- **`/usr/bin/time -l` 的 maximum RSS 是峰值**，用它对比不同时长的运行来判泄漏会得出假结论。

## 本机环境注意

- **Xcode.app 装着但没同意许可证**（`xcode-select` 指向 Command Line Tools），所以不能用 `xcodebuild`，全走 SPM。
- SwiftPM 的 `sandbox-exec` 在此环境不可用 → 所有 swift 命令都要 `--disable-sandbox`。
- SwiftPM 有时解析不到宏插件路径（SwiftUI 的 `@State`/`@Bindable` 需要 `SwiftUIMacros`，swift-testing 需要 `TestingMacros`），
  报 `plugin ... not found`。`scripts/_common.sh` 会显式把 Xcode 与 CLT 两处的插件目录都传给 swiftc。
- 工作目录路径含空格，所以脚本里的 swift 参数必须用数组 `"${LITESTATS_FLAGS[@]}"` 展开。
- 屏幕录制权限未授予 → 无法 `screencapture`。视觉验证改用**进程内离屏渲染**
  （`--selftest --dump-render`），照样能看到真实画面。

## 验证记录（本机实测原始输出）

| 项目 | 命令 | 结果 |
| --- | --- | --- |
| 单元测试 + 泄漏压测 | `./scripts/test.sh` | 见下方 |
| 无头自检 | `LiteStats --selftest` | **52/52 通过**（几何不变式、窗口层级、指示条几何与绘制、设置界面渲染、传感器数值） |
| 端到端悬浮 | `./scripts/e2e-hover-test.sh` | **PASS**，真实光标驱动：`state=expanded` → `state=collapsed` |
| 传感器数值 | `litestats-probe --seconds 10` | 见下方 |
| 自身开销 | `LiteStats --benchmark 60` | 见上表 |

**单元测试 + 泄漏压测**（`./scripts/test.sh`）：

```
✔ Test run with 64 tests in 8 suites passed
```

**权威泄漏检查**（`./scripts/soak.sh all-sensors 20000`，单进程、无并行测试干扰）：

```
cpu  20000 拍  RSS 5.83 → 5.83 MB   +0.00 MB   0.0 B/拍
mem  20000 拍  RSS 5.81 → 5.81 MB   +0.00 MB   0.0 B/拍
net  20000 拍  RSS 6.55 → 6.59 MB   +0.05 MB   2.5 B/拍
gpu  20000 拍  RSS 6.08 → 6.08 MB   +0.00 MB   0.0 B/拍
disk 20000 拍  RSS 5.83 → 5.83 MB   +0.00 MB   0.0 B/拍
all  20000 拍  RSS 8.06 → 8.08 MB   +0.02 MB   0.8 B/拍
```

> 单元测试里也有一份 soak 断言，但阈值故意放得很宽：swift-testing 默认并行跑各 suite，
> 温度测试做 HID/SMC 发现时会一次性分配几 MB，把同一进程里测到的 RSS 抬高
> （实测 CPUSensor 从 2.5 B/拍 被污染成 288 B/拍）。所以**权威测量只认 `scripts/soak.sh`**。

**传感器数值**（`litestats-probe --seconds 32 --json`，末拍）：

```
cpuTemp 63.1 °C · batteryTemp 38.0 °C · gpuTemp null（本机无 GPU 专属传感器，不冒充）
sensorCount 17（76 个 HID 服务按名字去重后的有效传感器数）
fans 4092 / 4425 rpm（F0Mn 2317、F0Mx 7826）· thermal readMs 7.93 ms
source "HID(36 个传感器) + SMC(2 个风扇)"
```

**端到端悬浮**（`./scripts/e2e-hover-test.sh`，程序化移动真实光标）：

```
1791613896.029 state=expanded  mouse=(900.0, 1150.0) frame={{764, 1130}, {272, 39}}
1791613897.679 state=collapsed mouse=(895.4, 458.2)  frame={{700, 875}, {400, 294}}
E2E RESULT: PASS（展开 1 次 / 收起 1 次）
```

## 还没做

- 进程列表 / 单进程占用
- 阈值告警（CPU 持续 100%、内存压力、磁盘将满）
- GPU 温度（本机没有 GPU 专属传感器，`gpuTemperature` 保持 nil 而不是拿 CPU 温度冒充）
- 正式签名与公证（目前 ad-hoc 签名，仅本机可用；要分发给别人需要开发者证书）
