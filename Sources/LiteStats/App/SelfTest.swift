import AppKit
import LiteStatsCore

/// 无头自检：验证屏幕几何、窗口不变式、命中判定、真实绘制、以及传感器数值。
///
/// 用法：`LiteStats --selftest [--dump-render <path.png>]`
/// 需要屏幕录制权限才能截图，但**本自检不需要**：绘制验证是进程内把视图层级渲染成位图。
@MainActor
enum SelfTest {
    private static var checkCount = 0
    private static var failures: [String] = []

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checkCount += 1
        print("\(ok ? "PASS" : "FAIL") | \(name)\(detail.isEmpty ? "" : " | \(detail)")")
        if !ok { failures.append(name) }
    }

    private static func info(_ text: String) {
        print("     · \(text)")
    }

    private static func rect(_ r: CGRect) -> String {
        String(format: "(%.0f, %.0f, %.0f×%.0f)", r.minX, r.minY, r.width, r.height)
    }

    private static func nearlyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    static func run() -> Never {
        print("=== LiteStats 自检 ===")

        // MARK: 1. 屏幕几何

        guard let geometry = ScreenGeometry.resolve() else {
            print("FAIL | 无法解析屏幕几何")
            exit(2)
        }
        info("屏幕 frame=\(rect(geometry.screenFrame)) visible=\(rect(geometry.visibleFrame)) scale=\(geometry.backingScale)")
        info("菜单栏高度=\(geometry.menuBarHeight)")
        info("缺口矩形=\(rect(geometry.notchRect))（\(geometry.hasPhysicalNotch ? "物理刘海" : "合成缺口")）屏幕=\(geometry.name)")
        check("拿到有效屏幕", geometry.screenFrame.width > 100 && geometry.screenFrame.height > 100)
        check("菜单栏/刘海高度 > 0", geometry.menuBarHeight > 0, "\(geometry.menuBarHeight)")

        // 自检用的偏好（独立 suite，不碰用户真实设置）
        let slotDefaults = UserDefaults(suiteName: "litestats-selftest-slot") ?? .standard
        slotDefaults.removePersistentDomain(forName: "litestats-selftest-slot")
        let prefs = Preferences(defaults: slotDefaults)
        prefs.leftIndicator = .cpu
        prefs.rightIndicator = .temperature

        let layout = AppDelegate.standardLayout(geometry: geometry)
        info("收起 frame=\(rect(layout.collapsedFrame))")
        info("展开 frame=\(rect(layout.expandedFrame))")
        info("岛颈 rect(窗口内)=\(rect(layout.tabRect)) 面板体=\(rect(layout.bodyRect))")

        // MARK: 2. 布局不变式

        check("展开 frame 完整包含收起 frame", layout.expandedFrame.contains(layout.collapsedFrame))
        check("两态水平居中对齐", abs(layout.collapsedFrame.midX - layout.expandedFrame.midX) < 0.5)
        check("面板体以刘海为水平居中",
              abs(layout.bodyRect.midX - (geometry.anchorX - layout.expandedFrame.minX)) < 0.5,
              "面板体中轴 \(layout.bodyRect.midX) vs 刘海中心 \(geometry.anchorX - layout.expandedFrame.minX)")
        check("面板体不超出窗口", layout.bodyRect.width <= layout.expandedFrame.width + 0.5)
        check("窗口高度 == 岛颈 + 面板体",
              abs(layout.windowSize.height - layout.bodyRect.maxY) < 0.5,
              "窗口 \(layout.windowSize.height) vs 内容 \(layout.bodyRect.maxY)")

        do {
            let notch = geometry.notchRect
            check("展开 frame 顶边贴屏幕顶部", abs(layout.expandedFrame.maxY - geometry.screenTop) < 0.5)
            // 菜单栏带（本机 39pt）比物理刘海（38pt）高 1pt 属正常：岛颈要一直画到菜单栏底边，
            // 才能和下方的面板体无缝相接，否则中间会出现 1pt 缝隙。
            check("收起 frame 高度 ≈ 刘海高度（差 ≤2pt）",
                  abs(layout.collapsedFrame.height - notch.height) <= 2,
                  "\(layout.collapsedFrame.height) vs 刘海 \(notch.height)")
            check("收起 frame 底边与菜单栏底边对齐",
                  abs(layout.collapsedFrame.minY - geometry.visibleFrame.maxY) < 0.5,
                  "\(layout.collapsedFrame.minY) vs \(geometry.visibleFrame.maxY)")
            check("收起热区比刘海宽（左右可悬浮）",
                  layout.collapsedFrame.width > notch.width,
                  "热区 \(layout.collapsedFrame.width) vs 刘海 \(notch.width)")
            check("岛颈完全覆盖刘海宽度", layout.tabRect.width >= notch.width,
                  "岛颈 \(layout.tabRect.width) vs 刘海 \(notch.width)")
        }

        // MARK: 2b. 无刘海屏的"合成缺口"（外接屏 / 非刘海机型走这条）

        let wide = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let synthetic = ScreenGeometry.syntheticSlot(screenFrame: wide, menuBarHeight: 39)
        check("圆槽：水平居中", abs(synthetic.midX - wide.midX) < 0.5, rect(synthetic))
        check("圆槽：整颗落在菜单栏带内",
              synthetic.minY >= wide.maxY - 39 - 0.5 && synthetic.maxY <= wide.maxY + 0.5,
              rect(synthetic))
        check("圆槽：高度适中（不占满菜单栏、也不至于看不见）",
              synthetic.height >= 18 && synthetic.height <= 39 - 4, "\(synthetic.height)")
        check("圆槽：是胶囊比例（圆角 = 半高）", abs(synthetic.height - 26) < 6, "\(synthetic.height)")
        let narrow = ScreenGeometry.syntheticSlot(screenFrame: CGRect(x: 0, y: 0, width: 600, height: 800),
                                                  menuBarHeight: 24)
        check("圆槽：窄屏有最小宽度兜底", narrow.width >= 90, "\(narrow.width)")

        // 圆槽宽度规则：中间是表情，两侧各按"黑耳长度"展开
        func slotWidth(left: IndicatorMetric, right: IndicatorMetric, earWidth: CGFloat) -> CGFloat {
            let prefs = Preferences(defaults: UserDefaults(suiteName: "litestats-selftest-slotwidth") ?? .standard)
            prefs.leftIndicator = left
            prefs.rightIndicator = right
            prefs.earWidth = Double(earWidth)
            let geo = ScreenGeometry(displayID: 99, name: "合成屏",
                                     screenFrame: wide, visibleFrame: wide,
                                     menuBarHeight: 38,
                                     notchRect: ScreenGeometry.syntheticSlot(screenFrame: wide, menuBarHeight: 38),
                                     hasPhysicalNotch: false, backingScale: 2)
            return AppDelegate.standardLayout(geometry: geo, preferences: prefs).slotRect.width
        }
        let slotNone = slotWidth(left: .none, right: .none, earWidth: 88)
        let slotLeft = slotWidth(left: .cpu, right: .none, earWidth: 88)
        let slotBoth = slotWidth(left: .cpu, right: .temperature, earWidth: 88)
        let slotBothWide = slotWidth(left: .cpu, right: .temperature, earWidth: 140)
        info("圆槽宽度：无指标 \(Int(slotNone)) / 仅左 \(Int(slotLeft)) / 左右都有 \(Int(slotBoth)) / 黑耳 140pt 时 \(Int(slotBothWide))")
        check("圆槽：两边都没指标时只剩表情那点宽度", slotNone < 40, "\(Int(slotNone))")
        check("圆槽：只有左侧指标时 = 表情 + 一个黑耳长度",
              abs(slotLeft - (slotNone + 88)) < 0.5, "\(Int(slotLeft))")
        check("圆槽：左右都有 = 表情 + 两个黑耳长度",
              abs(slotBoth - (slotNone + 176)) < 0.5, "\(Int(slotBoth))")
        check("圆槽：黑耳长度设置会改变圆槽长度（140 > 88）",
              slotBothWide - slotBoth > 100, "\(Int(slotBothWide)) vs \(Int(slotBoth))")
        let allGeometries = ScreenGeometry.all()
        check("每块屏幕都能算出几何", allGeometries.count == NSScreen.screens.count,
              "\(allGeometries.count) vs \(NSScreen.screens.count)")
        check("每块屏幕都有可用的缺口矩形",
              allGeometries.allSatisfy { $0.notchRect.width > 40 && $0.notchRect.height > 10 })
        info("屏幕几何：" + allGeometries.map {
            "\($0.name)[\($0.hasPhysicalNotch ? "刘海" : "合成") \(Int($0.notchRect.width))×\(Int($0.notchRect.height))]"
        }.joined(separator: " "))

        // MARK: 3. 命中判定

        let topCenter = CGPoint(x: geometry.anchorX, y: geometry.screenTop - 8)
        let farAway = CGPoint(x: geometry.anchorX, y: geometry.screenTop - 500)
        check("悬浮刘海中心 → 展开", layout.shouldExpand(point: topCenter))
        check("屏幕中部 → 不展开", !layout.shouldExpand(point: farAway))
        let bodyCenter = CGPoint(x: layout.expandedFrame.midX,
                                 y: layout.expandedFrame.minY + layout.bodyRect.height / 2)
        check("鼠标在面板体内 → 保持展开", layout.keepsExpanded(point: bodyCenter))
        check("鼠标移开 → 收起",
              !layout.keepsExpanded(point: CGPoint(x: layout.expandedFrame.minX - 120, y: bodyCenter.y)))

        // MARK: 4. 窗口与真实绘制

        let service = MonitorService()
        let controller = NotchPanelController(layout: layout, service: service)
        // 关掉真实鼠标轮询，保证测试可复现（不受当前物理鼠标位置影响）
        controller.hoverEnabled = false
        controller.start()
        pump(0.20)

        check("窗口已显示", controller.isWindowVisible)
        check("窗口层级 = statusBar(25)", controller.windowLevel == 25, "实际 \(controller.windowLevel)")
        check("收起态窗口 frame 正确", nearlyEqual(controller.windowFrame, layout.collapsedFrame),
              rect(controller.windowFrame))

        if let bitmap = controller.renderContentBitmap() {
            let maxAlpha = maxAlpha(bitmap)
            check("收起态完全不绘制内容（绝不会遮挡菜单栏）", maxAlpha < 24, "最大 alpha=\(maxAlpha)")
        }

        controller.forceState(.expanded, animated: false)
        pump(0.45)
        check("展开态窗口 frame 正确", nearlyEqual(controller.windowFrame, layout.expandedFrame),
              rect(controller.windowFrame))

        if let bitmap = controller.renderContentBitmap() {
            let scale = CGFloat(bitmap.pixelsWide) / max(layout.windowSize.width, 1)
            let cover = alphaCoverage(bitmap, region: layout.bodyRect, scale: scale)
            let center = alphaAt(bitmap, point: CGPoint(x: layout.bodyRect.midX, y: layout.bodyRect.midY), scale: scale)
            let outsideIsland = alphaAt(bitmap, point: CGPoint(x: 3, y: 3), scale: scale)
            let roundedCorner = alphaAt(bitmap, point: CGPoint(x: 2, y: layout.bodyRect.maxY - 2), scale: scale)
            info("绘制位图 \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)px scale=\(scale) 面板体覆盖率 \(String(format: "%.1f%%", cover * 100))")
            check("面板体已渲染（覆盖率 > 90%）", cover > 0.90)
            check("面板体中心不透明", center > 200, "alpha=\(center)")
            check("岛颈以外的菜单栏区域保持透明", outsideIsland < 24, "alpha=\(outsideIsland)")
            // 圆角外允许有阴影（实测 alpha≈38），只要不是实心绘制即可
            check("面板体圆角外未被实心绘制", roundedCorner < 100, "alpha=\(roundedCorner)")
            dump(bitmap, suffix: "expanded")
        } else {
            check("面板离屏渲染可用", false, "bitmapImageRepForCachingDisplay 返回 nil")
        }

        controller.forceState(.collapsed, animated: false)
        pump(0.25)
        check("收起后窗口 frame 复位", nearlyEqual(controller.windowFrame, layout.collapsedFrame),
              rect(controller.windowFrame))

        // MARK: 4b. 常驻指示条（收起态画在刘海两侧的黑耳里）
        verifyIndicators(geometry: geometry, baseLayout: layout, service: service, prefs: prefs)

        // MARK: 4c. 形变动画（水滴展开）
        verifyIslandMorph(layout: layout, service: service)

        // MARK: 5. 采样数据（端到端）

        service.isPanelExpanded = true
        service.start()
        pump(1.4)

        if let snap = service.snapshot {
            info(String(format: "CPU 总 %.1f%% 每核心 %d 个 首核 %.1f%% 用户 %.1f%% 系统 %.1f%% 负载 %.2f",
                        snap.cpu.total * 100, snap.cpu.perCore.count,
                        (snap.cpu.perCore.first ?? 0) * 100,
                        snap.cpu.user * 100, snap.cpu.system * 100, snap.cpu.load1))
            info("内存 已用 \(Fmt.bytes(snap.memory.used)) / \(Fmt.bytes(snap.memory.total)) (\(Fmt.percent(snap.memory.usage, decimals: 0))) 交换 \(Fmt.bytes(snap.memory.swapUsed))")
            info("GPU \(snap.gpu.name ?? "?") 利用率 \(snap.gpu.utilization.map { Fmt.percent($0, decimals: 0) } ?? "不可用") 显存 \(snap.gpu.inUseMemory.map(Fmt.bytes) ?? "?")")
            info("网络 \(snap.network.interfaceName ?? "?") ↓\(Fmt.rate(snap.network.download)) ↑\(Fmt.rate(snap.network.upload))")
            info("磁盘 \(snap.disk.map { "\(Fmt.percent($0.usage, decimals: 0)) 已用，可用 \(Fmt.bytes($0.free))" } ?? "不可用")  采样耗时 \(String(format: "%.2f", service.lastSampleMillis)) ms")

            check("每核心数量 == 逻辑核心数", snap.cpu.perCore.count == service.coreCount,
                  "\(snap.cpu.perCore.count) vs \(service.coreCount)")
            check("内存总量 == 物理内存", snap.memory.total == ProcessInfo.processInfo.physicalMemory)
            check("内存已用 > 0", snap.memory.used > 0)
            check("CPU 占用率在 0...1", snap.cpu.total >= 0 && snap.cpu.total <= 1.0001, "\(snap.cpu.total)")
            check("每核心占用率均在 0...1", snap.cpu.perCore.allSatisfy { $0 >= 0 && $0 <= 1.0001 })
            check("CPU 至少有一个核心在动（非全 0）", snap.cpu.total > 0, "\(snap.cpu.total)")
            check("GPU 利用率可读", snap.gpu.utilization != nil,
                  snap.gpu.utilization.map { "\(Int($0 * 100))%" } ?? "nil")
            check("网络主接口可识别", snap.network.interfaceName != nil, snap.network.interfaceName ?? "nil")
            check("磁盘信息可读", snap.disk != nil)
            // 采样耗时：看多次采样的中位数（典型路径），不看某一拍。
            // 原因：温度是"每 N 拍刷一次、每次轮转读 8 个传感器"，那一拍本来就要 10–20ms，
            // 只有最后一拍的断言会偶发误报。
            var durations: [Double] = [service.lastSampleMillis]
            for _ in 0..<7 {
                pump(0.25)
                durations.append(service.lastSampleMillis)
            }
            let sortedDurations = durations.sorted()
            let median = sortedDurations[sortedDurations.count / 2]
            let slowTicks = durations.filter { $0 > 10 }.count
            info(String(format: "采样耗时：中位 %.2f ms，最大 %.2f ms，>10ms 的拍数 %d/%d",
                        median, sortedDurations.last ?? 0, slowTicks, durations.count))
            check("典型采样耗时中位数 < 5 ms", median < 5, String(format: "%.2f ms", median))
            check("采样耗时上界 < 40 ms（温度刷新拍也在内）", (sortedDurations.last ?? 0) < 40,
                  String(format: "%.2f ms", sortedDurations.last ?? 0))
        } else {
            check("采样到数据", false, "snapshot 为 nil")
        }

        service.stop()
        controller.stop()

        // MARK: 6. 带真实数据的绘制（真实数值更长，用来确认没有截断）

        let dataService = MonitorService()
        let dataController = NotchPanelController(layout: layout, service: dataService)
        dataController.hoverEnabled = false
        dataController.start()
        dataController.forceState(.expanded, animated: false)
        dataService.isPanelExpanded = true
        dataService.start()
        pump(4.2) // 至少 3 拍，折线图才有形态
        if let bitmap = dataController.renderContentBitmap() {
            dump(bitmap, suffix: "data")
        }
        dataService.stop()
        dataController.stop()
        info("带数据渲染时的采样：\(dataService.sampleCount) 次，末次耗时 \(String(format: "%.2f", dataService.lastSampleMillis)) ms")

        // MARK: 7. 设置界面

        verifySettingsWindow(service: dataService)

        // MARK: 8. 历史统计

        verifyHistory(service: dataService)

        print("=== 自检结果：\(checkCount - failures.count)/\(checkCount) 通过 ===")
        if !failures.isEmpty {
            print("失败项：\(failures.joined(separator: "、"))")
            exit(1)
        }
        print("SELFTEST RESULT: PASS")
        exit(0)
    }

    // MARK: - 工具

    /// 形变动画检查：progress=0 必须与物理刘海完全重合（这就是"完全收入灵动岛"），
    /// progress=1 必须等于岛颈 ∪ 面板体，中间帧必须是"半途"且不越出窗口。
    private static func verifyIslandMorph(layout: PanelLayout, service: MonitorService) {
        guard layout.notchRect.width > 1 else {
            info("缺口宽度异常，跳过形变动画检查")
            return
        }
        let notch = layout.notchRect
        let target = layout.tabRect.union(layout.bodyRect)

        func bounds(_ progress: CGFloat) -> CGRect {
            IslandShape(progress: progress, notch: notch, tab: layout.tabRect, body: layout.bodyRect,
                        bodyRadius: Theme.cornerRadius, tabRadius: Theme.tabCornerRadius)
                .path(in: .zero).boundingRect
        }

        // 无刘海屏：进度 0 必须正好是圆槽（这样和 AppKit 画的收起态无缝衔接）
        var slotLayout = layout
        slotLayout.geometry = ScreenGeometry(displayID: 99, name: "外接屏(合成)",
                                             screenFrame: layout.geometry.screenFrame,
                                             visibleFrame: layout.geometry.visibleFrame,
                                             menuBarHeight: layout.geometry.menuBarHeight,
                                             notchRect: ScreenGeometry.syntheticSlot(
                                                screenFrame: layout.geometry.screenFrame,
                                                menuBarHeight: layout.geometry.menuBarHeight),
                                             hasPhysicalNotch: false,
                                             backingScale: 1)
        let slotShape = { (p: CGFloat) in
            IslandShape(progress: p,
                        usesSlot: true,
                        slot: slotLayout.slotRectInExpandedWindow,
                        notch: slotLayout.notchRect,
                        tab: slotLayout.tabRect,
                        body: slotLayout.bodyRect,
                        bodyRadius: Theme.cornerRadius,
                        tabRadius: Theme.tabCornerRadius)
                .path(in: .zero).boundingRect
        }
        let slotStart = slotShape(0)
        let slotEnd = slotShape(1)
        info("合成屏形变：p=0 \(rect(slotStart))（圆槽 \(rect(slotLayout.slotRectInExpandedWindow))）p=1 \(rect(slotEnd))")
        check("合成屏：p=0 的轮廓正好是圆槽",
              nearlyEqual(slotStart, slotLayout.slotRectInExpandedWindow, tolerance: 1.5),
              "\(rect(slotStart))")
        // 关键：展开完成时轮廓必须**正好**是面板体本身 —— 圆槽不能还多出一截压在面板上
        check("合成屏：p=1 正好等于面板体（圆槽被完全吃掉）",
              nearlyEqual(slotEnd, slotLayout.bodyRect, tolerance: 1.5),
              "轮廓 \(rect(slotEnd)) vs 面板 \(rect(slotLayout.bodyRect))")
        // 中间帧必须是"一个形状"，不能出现上面一颗胶囊 + 下面一块面板的叠加：
        // 判据是中间帧高度落在圆槽与面板之间、且顶边单调下移
        let slotMid = slotShape(0.5)
        check("合成屏：中间帧是单一形状（高度介于圆槽与面板之间）",
              slotMid.height > slotStart.height + 2 && slotMid.height < slotEnd.height - 2,
              "高度 \(Int(slotMid.height))")

        let start = bounds(0)
        let end = bounds(1)
        let mid = bounds(0.5)
        info("形变轮廓：p=0 \(rect(start)) · p=0.5 \(rect(mid)) · p=1 \(rect(end))")

        check("p=0 轮廓与物理刘海完全重合（收起态彻底隐形）",
              start.width <= notch.width + 0.5 && start.height <= notch.height + 0.5
              && abs(start.midX - notch.midX) < 0.5,
              "\(rect(start)) vs 刘海 \(rect(notch))")
        check("p=1 轮廓 = 岛颈 ∪ 面板体",
              nearlyEqual(end, target, tolerance: 1.0), "\(rect(end)) vs \(rect(target))")
        check("中间帧确实是半途（既不是刘海也不是成品）",
              mid.height > notch.height * 0.2 && mid.height < layout.bodyRect.height,
              "高度 \(mid.height) vs 目标 \(layout.bodyRect.height)")
        check("形变过程全程不越出窗口",
              mid.maxX <= layout.windowSize.width + 0.5 && mid.maxY <= layout.windowSize.height + 0.5,
              rect(mid))

        // 导出几张中间帧，肉眼确认"水滴"形状
        let controller = NotchPanelController(layout: layout, service: service)
        controller.hoverEnabled = false
        controller.start()
        controller.forceState(.expanded, animated: false)
        pump(0.4)
        for progress in [CGFloat(0.25), 0.5, 0.75] {
            controller.setMorphProgressForTest(progress)
            pump(0.12)
            if let bitmap = controller.renderContentBitmap() {
                dump(bitmap, suffix: "morph-\(Int(progress * 100))")
            }
        }
        controller.stop()

        // ── 动画过程验证：展开必须"长出来"，不能瞬间出现 ──
        // 这是用户实际看到的那个 bug（收起有动效、展开是直接出现），所以要有断言守住：
        // 在展开动画进行中连续采样离屏渲染，必须采到"尺寸介于刘海和成品之间"的中间帧。
        let animated = NotchPanelController(layout: layout, service: service)
        animated.hoverEnabled = false
        animated.start()
        animated.forceState(.collapsed, animated: false)
        pump(0.3)

        let growing = NotchPanelController(layout: layout, service: service)
        growing.hoverEnabled = false
        growing.start()
        growing.forceState(.expanded, animated: true)
        var heights: [CGFloat] = []
        var timeline: [String] = []
        let animationStart = Date()
        for _ in 0..<14 {
            pump(0.04)
            if let bitmap = growing.renderContentBitmap(),
               let bounds = alphaBounds(bitmap, scale: CGFloat(bitmap.pixelsWide) / max(layout.windowSize.width, 1)) {
                heights.append(bounds.height)
                timeline.append(String(format: "%.0fms:%d", Date().timeIntervalSince(animationStart) * 1000, Int(bounds.height)))
            }
        }
        info("展开时间线 \(timeline.joined(separator: " "))")
        pump(0.8)
        let settled = growing.renderContentBitmap().flatMap {
            alphaBounds($0, scale: CGFloat($0.pixelsWide) / max(layout.windowSize.width, 1))
        }
        info("展开动画采样到的高度序列：\(heights.map { Int($0) })（落定 \(settled.map { Int($0.height) } ?? -1)）")
        let intermediates = heights.filter { $0 > layout.notchRect.height + 4 && $0 < (settled?.height ?? 0) - 6 }
        check("展开动画确实有中间帧（不是瞬间出现）", intermediates.count >= 2,
              "中间帧 \(intermediates.count) 个：\(intermediates.map { Int($0) })")
        growing.stop()
        animated.stop()
    }

    /// 历史统计：临时目录里的端到端（灌数据 → 汇总非空 → 清空归零 → 窗口能渲染）
    private static func verifyHistory(service: MonitorService) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("litestats-selftest-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        guard let store = try? HistoryStore(directory: directory) else {
            check("历史存储可在指定目录创建", false, directory.path)
            return
        }
        check("历史存储可在指定目录创建", true, directory.path)
        check("初始时无历史数据", store.storageBytes == 0, "\(store.storageBytes) 字节")

        // 灌入真实快照（每拍记为 1 秒；store 内部按分钟聚合）
        let monitor = SystemMonitor()
        _ = monitor.sample()
        for _ in 0..<40 {
            let snapshot = monitor.sample()
            store.record(snapshot: snapshot, interval: 1)
        }
        // 也灌一点按应用的数据，顺便验证聚合路径
        store.record(appSamples: [
            AppUsageSample(name: "Safari", path: "/Applications/Safari.app", cpuSeconds: 1.2,
                           memoryBytes: 400 * 1_048_576, networkIn: 5_000_000, networkOut: 200_000),
            AppUsageSample(name: "Xcode", path: "/Applications/Xcode.app", cpuSeconds: 8.5,
                           memoryBytes: 2_000 * 1_048_576, networkIn: 100_000, networkOut: 50_000),
        ], interval: 5)
        store.flush()

        let summary = store.today()
        info(String(format: "历史汇总：网络 ↓%@ ↑%@ CPU %.2f 核·秒 应用 %d 个 存储 %.1f KB",
                    Fmt.bytes(summary.networkIn), Fmt.bytes(summary.networkOut),
                    summary.cpuSeconds, summary.apps.count, Double(store.storageBytes) / 1024))
        check("历史汇总记录了 CPU 时间", summary.cpuSeconds > 0, "\(summary.cpuSeconds)")
        check("历史汇总有应用维度数据", !summary.apps.isEmpty, "\(summary.apps.count) 个")
        check("应用排行按影响降序（Xcode 应排在 Safari 前）",
              summary.apps.first?.name == "Xcode", summary.apps.map(\.name).joined(separator: ","))

        // 日历网格纯计算：月首对齐、天数、周一起始
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 1
        if let october = Calendar.current.date(from: components) {
            let weeks = HistoryCalendar.weeks(in: october)
            let days = weeks.flatMap { $0 }.compactMap { $0 }
            check("日历：2026 年 10 月有 31 天", days.count == 31, "\(days.count)")
            check("日历：固定 6 周 × 7 天网格",
                  weeks.count == 6 && weeks.allSatisfy { $0.count == 7 },
                  "\(weeks.count) 周")
            if let first = days.first, let last = days.last {
                check("日历：首格 = 10 月 1 日", Calendar.current.component(.day, from: first) == 1)
                check("日历：末格 = 10 月 31 日", Calendar.current.component(.day, from: last) == 31)
                // 周一起始：1 号是周四 → 第一行应有 3 个空位（周一~周三）
                let leadingNils = weeks[0].prefix { $0 == nil }.count
                check("日历：周一起始对齐（10/1 是周四 → 前置 3 个空位）", leadingNils == 3, "\(leadingNils)")
            }
            check("日历：今天能被识别",
                  HistoryCalendar.isCurrentMonth(HistoryCalendar.startOfMonth(for: Date())))
        } else {
            check("日历：能构造测试月份", false)
        }

        // 图表 24 槽位（纯函数）
        let emptySlots = HistoryChartData.singleDaySlots(hourly: [], metric: .cpu)
        check("今日时段图固定 24 个槽位（没有数据时也占位）",
              emptySlots.count == 24 && emptySlots.allSatisfy { $0.isEmpty && $0.rawValue == 0 },
              "\(emptySlots.count) 个")
        check("时段标签是 00…23", emptySlots.first?.hour == 0 && emptySlots.last?.hour == 23,
              "\(emptySlots.first?.hour ?? -1)…\(emptySlots.last?.hour ?? -1)")
        if let day = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 17)) {
            let bucket = HourlyBucket(hourStart: day, cpuSeconds: 3600, gpuPercentAverage: 0.5,
                                      memoryBytesAverage: 8_000_000_000, networkIn: 1_000_000,
                                      networkOut: 500_000, sampleCount: 60)
            let slots = HistoryChartData.singleDaySlots(hourly: [bucket], metric: .cpu)
            check("只有 17 点有数据时，其余 23 个槽位为空",
                  slots.filter { !$0.isEmpty }.count == 1 && slots[17].isPeak && !slots[17].isEmpty,
                  "非空 \(slots.filter { !$0.isEmpty }.count) 个，峰值时刻 \(slots.firstIndex { $0.isPeak } ?? -1)")
        }

        // 窗口能渲染（无法点鼠标，只能离屏渲染确认它真的画出来了）
        let controller = HistoryWindowController(store: store)
        controller.present()
        pump(0.8)
        if let content = controller.window?.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / max(content.bounds.width, 1)
            let coverage = alphaCoverage(bitmap, region: CGRect(origin: .zero, size: content.bounds.size),
                                        scale: scale, threshold: 128)
            // 注意：窗口内容视图本身是"透明底"（底色由 NSWindow 画），
            // 所以覆盖率天然很低，这里改为"有内容 + 内容铺满大半个窗口"。
            let ink = alphaBounds(bitmap, scale: scale, threshold: 40)
            info(String(format: "历史窗口离屏渲染 %d×%dpx 着色覆盖率 %.1f%% 内容范围 %@",
                        bitmap.pixelsWide, bitmap.pixelsHigh, coverage * 100,
                        ink.map { rect($0) } ?? "无"))
            check("历史统计窗口渲染出内容并铺满窗口",
                  coverage > 0.04 && (ink?.width ?? 0) > content.bounds.width * 0.7
                  && (ink?.height ?? 0) > content.bounds.height * 0.7,
                  "着色 \(String(format: "%.1f%%", coverage * 100)) 范围 \(ink.map { rect($0) } ?? "无")")
            dump(bitmap, suffix: "history")
        } else {
            check("历史统计窗口离屏渲染可用", false, "contentView/bitmap 为 nil")
        }
        controller.close()
        pump(0.2)

        // 清空
        do {
            try store.resetAll()
            check("清空后存储归零", store.storageBytes == 0, "\(store.storageBytes) 字节")
            check("清空后汇总为空", store.today().cpuSeconds == 0 && store.today().apps.isEmpty)
        } catch {
            check("清空历史数据", false, String(describing: error))
        }
    }

    /// 常驻指示条验证：几何（黑耳放得下指示条、不越界/不覆盖刘海）+ 真实绘制 + 展开后自动隐藏
    private static func verifyIndicators(geometry: ScreenGeometry, baseLayout: PanelLayout,
                                         service: MonitorService, prefs: Preferences) {
        let notch = geometry.notchRect
        guard notch.width > 1 else {
            info("缺口宽度异常，跳过指示条验证")
            return
        }

        // 回归断言：没选任何指标时，收起态必须一个像素都不画。
        // （之前 NotchIndicatorView 无条件按 collapsedLeftExtent 画黑耳，
        //   导致"没配指示条"时刘海两边各多出 26pt 黑边，看起来像被撑宽了。）
        let plain = NotchPanelController(layout: baseLayout, service: service)
        plain.hoverEnabled = false
        plain.applyIndicators(left: .none, right: .none)
        plain.start()
        pump(0.25)
        check("不选指标时不画黑耳", !plain.indicatorIsActive)
        if let bitmap = plain.renderContentBitmap() {
            let maxA = maxAlpha(bitmap)
            check("不选指标时收起态完全隐形（彻底藏进物理刘海）", maxA < 24, "最大 alpha=\(maxA)")
        }
        plain.stop()

        var layout = baseLayout
        layout.earWidth = 88
        layout.leftEarActive = true
        layout.rightEarActive = true
        let leftEar = layout.collapsedLeftEarRect
        let rightEar = layout.collapsedRightEarRect
        info("指示条布局：收起 frame=\(rect(layout.collapsedFrame)) 左耳=\(rect(leftEar)) 右耳=\(rect(rightEar))")

        check("两侧黑耳长度完全一致（与内容无关）", abs(leftEar.width - rightEar.width) < 0.5,
              "左 \(leftEar.width) vs 右 \(rightEar.width)")
        check("黑耳长度 = 设置值", abs(leftEar.width - layout.earWidth) < 0.5, "\(leftEar.width)")
        check("黑耳不侵占刘海区域",
              leftEar.maxX <= notch.minX - layout.collapsedFrame.minX + 0.5
              && rightEar.minX >= notch.maxX - layout.collapsedFrame.minX - 0.5)
        check("收起热区比刘海宽出指示条部分",
              layout.collapsedFrame.width > notch.width + layout.earWidth)
        check("展开 frame 仍完整包含收起 frame", layout.expandedFrame.contains(layout.collapsedFrame))

        // 先采一拍，让指示条渲染出真实数值（不然预览里只有 "CPU —"）
        service.start()
        pump(1.4)

        let controller = NotchPanelController(layout: layout, service: service)
        controller.hoverEnabled = false
        controller.applyIndicators(left: .cpu, right: .network)
        controller.updateIndicator(service.snapshot)
        controller.start()
        pump(0.25)

        check("指示条已激活", controller.indicatorIsActive)
        check("收起态耳朵完全伸出（earProgress = 1）", controller.indicatorEarProgress > 0.99,
              "\(controller.indicatorEarProgress)")
        check("指示条布局下窗口 frame 正确",
              nearlyEqual(controller.windowFrame, layout.collapsedFrame), rect(controller.windowFrame))

        if let bitmap = controller.renderContentBitmap() {
            let scale = CGFloat(bitmap.pixelsWide) / max(layout.collapsedFrame.width, 1)
            // 窗口内左上原点坐标：黑耳占满整个高度，x 与左下原点一致
            let leftPoint = CGPoint(x: leftEar.midX, y: leftEar.height / 2)
            let rightPoint = CGPoint(x: rightEar.midX, y: rightEar.height / 2)
            let notchPoint = CGPoint(x: layout.collapsedFrame.width / 2, y: layout.collapsedFrame.height / 2)
            let leftAlpha = alphaAt(bitmap, point: leftPoint, scale: scale)
            let rightAlpha = alphaAt(bitmap, point: rightPoint, scale: scale)
            let notchAlpha = alphaAt(bitmap, point: notchPoint, scale: scale)
            let leftCover = alphaCoverage(bitmap, region: CGRect(x: 0, y: 0, width: leftEar.width, height: leftEar.height), scale: scale)
            let rightCover = alphaCoverage(bitmap, region: CGRect(x: rightEar.minX, y: 0, width: rightEar.width, height: rightEar.height), scale: scale)

            info(String(format: "指示条离屏渲染：左耳覆盖率 %.1f%%（alpha=%d）右耳覆盖率 %.1f%%（alpha=%d）刘海区 alpha=%d",
                        leftCover * 100, leftAlpha, rightCover * 100, rightAlpha, notchAlpha))
            check("左耳已绘制出指示条", leftCover > 0.80)
            check("右耳已绘制出指示条", rightCover > 0.80)
            check("刘海正上方保持透明（没有画成整条黑带）", notchAlpha < 24, "alpha=\(notchAlpha)")
            dump(bitmap, suffix: "indicators")

        // 无刘海屏的圆槽：真的渲染一张图出来（收起态长什么样全靠它）
        if let geometry = ScreenGeometry.resolve() {
            var slotGeometry = geometry
            slotGeometry = ScreenGeometry(displayID: 99, name: "合成屏",
                                          screenFrame: geometry.screenFrame,
                                          visibleFrame: geometry.visibleFrame,
                                          menuBarHeight: geometry.menuBarHeight,
                                          notchRect: ScreenGeometry.syntheticSlot(
                                            screenFrame: geometry.screenFrame,
                                            menuBarHeight: geometry.menuBarHeight),
                                          hasPhysicalNotch: false,
                                          backingScale: geometry.backingScale)
            let slotLayout = AppDelegate.standardLayout(geometry: slotGeometry, preferences: prefs)
            let slotView = NotchIndicatorView(frame: CGRect(origin: .zero, size: slotLayout.collapsedFrame.size))
            slotView.configure(layout: slotLayout, leftMetric: prefs.leftIndicator, rightMetric: prefs.rightIndicator)
            slotView.update(snapshot: service.snapshot)
            let slotWindow = NSWindow(contentRect: slotLayout.collapsedFrame, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
            slotWindow.contentView = slotView
            slotView.setEarProgress(1, animated: false, duration: 0)
            slotView.display()
            // 再渲染一张"圆槽长成面板之后"的样子：不应该再看到圆槽压在面板上
            let slotController = NotchPanelController(layout: slotLayout, service: service)
            slotController.forceState(.expanded, animated: false)
            slotController.setMorphProgressForTest(1)
            pump(0.2)
            if let bitmap = slotController.renderContentBitmap() {
                dump(bitmap, suffix: "slot-expanded")
                // 展开完成时，窗口顶部（菜单栏带）里除了岛颈不该再有别的黑色块
                let bandBottom = slotLayout.bandHeight
                let scale = CGFloat(bitmap.pixelsWide) / max(slotLayout.expandedFrame.width, 1)
                let abovePanel = CGRect(x: 0, y: 0, width: slotLayout.expandedFrame.width,
                                        height: max(1, bandBottom - 1))
                let coverage = alphaCoverage(bitmap, region: abovePanel, scale: scale, threshold: 200)
                info(String(format: "展开后菜单栏带内的绘制覆盖率 %.1f%%（岛颈宽度 %.0fpt / 窗口 %.0fpt）",
                            coverage * 100, slotLayout.slotRect.width, slotLayout.expandedFrame.width))
                check("展开后圆槽不再单独存在（菜单栏带内只剩岛颈那一条）",
                      coverage < 0.35, String(format: "覆盖率 %.1f%%", coverage * 100))
            }
            slotController.stop()

            // 另渲染一张"两边都没配指标"的最小圆槽（只有表情）
            var minimalPrefsLayout = slotLayout
            minimalPrefsLayout.leftEarActive = false
            minimalPrefsLayout.rightEarActive = false
            let minimalView = NotchIndicatorView(frame: CGRect(origin: .zero,
                                                               size: minimalPrefsLayout.collapsedFrame.size))
            // 必须挂进窗口：绘制时要用 window.frame 把全局坐标换算成窗口内坐标
            let minimalWindow = NSWindow(contentRect: minimalPrefsLayout.collapsedFrame,
                                         styleMask: [.borderless], backing: .buffered, defer: false)
            minimalWindow.contentView = minimalView
            minimalView.configure(layout: minimalPrefsLayout, leftMetric: .none, rightMetric: .none)
            minimalView.update(snapshot: service.snapshot)
            minimalView.setEarProgress(1, animated: false, duration: 0)
            minimalView.display()
            if let bitmap = minimalView.bitmapImageRepForCachingDisplay(in: minimalView.bounds) {
                minimalView.cacheDisplay(in: minimalView.bounds, to: bitmap)
                let coverage = alphaCoverage(bitmap,
                                             region: CGRect(origin: .zero, size: minimalPrefsLayout.collapsedFrame.size),
                                             scale: 1)
                check("最小圆槽（只有表情）也渲染出内容", coverage > 0.3,
                      String(format: "%.0f×%.0fpt 覆盖率 %.1f%%",
                             minimalPrefsLayout.collapsedFrame.width,
                             minimalPrefsLayout.collapsedFrame.height, coverage * 100))
                dump(bitmap, suffix: "slot-min")
            }

            if let bitmap = slotView.bitmapImageRepForCachingDisplay(in: slotView.bounds) {
                slotView.cacheDisplay(in: slotView.bounds, to: bitmap)
                let coverage = alphaCoverage(bitmap,
                                             region: CGRect(origin: .zero, size: slotLayout.collapsedFrame.size),
                                             scale: 1)
                check("圆槽渲染出内容", coverage > 0.4, String(format: "覆盖率 %.1f%%", coverage * 100))
                dump(bitmap, suffix: "slot")
            }
        }
        } else {
            check("指示条离屏渲染可用", false, "bitmapImageRepForCachingDisplay 返回 nil")
        }

        controller.forceState(.expanded, animated: false)
        pump(0.45)
        check("展开后耳朵完全收进刘海（earProgress = 0）", controller.indicatorEarProgress < 0.01,
              "\(controller.indicatorEarProgress)")
        check("展开态岛颈宽度 = 物理刘海宽度（不多露任何耳朵）",
              abs(layout.tabRect.width - notch.width) < 0.5,
              "岛颈 \(layout.tabRect.width) vs 刘海 \(notch.width)")
        if let bitmap = controller.renderContentBitmap() {
            // 只检查顶部菜单栏带里的耳朵区域：面板体本身当然是有内容的，
            // 而且它的阴影（alpha≈38）会落进这一带，所以用高阈值只认"实心黑耳"。
            let scale = CGFloat(bitmap.pixelsWide) / max(layout.expandedFrame.width, 1)
            // 探测区高度要停在菜单栏带内部：带的最底一行正好是面板体顶边的 1px 描边，
            // 那属于正常内容，不是"残留的耳朵"。
            let earBand = CGRect(x: 0, y: 0, width: layout.collapsedLeftEarRect.width,
                                 height: max(4, layout.bandHeight - 4))
            let ear = alphaBounds(bitmap, region: earBand, scale: scale, threshold: 200)
            check("展开态耳朵区域不再绘制任何东西", ear == nil,
                  ear.map { rect($0) } ?? "无内容")
        }
        controller.stop()

        verifyEarAnimation(geometry: geometry, layout: layout, service: service)
    }

    /// 耳朵伸缩动画验证：展开时左右耳必须**逐渐收进刘海**，收起时再长回来。
    private static func verifyEarAnimation(geometry: ScreenGeometry, layout: PanelLayout,
                                           service: MonitorService) {
        let controller = NotchPanelController(layout: layout, service: service)
        controller.hoverEnabled = false
        controller.applyIndicators(left: .cpu, right: .cpu)
        controller.start()
        pump(0.3)

        func renderedEarWidth() -> CGFloat {
            guard let bitmap = controller.renderContentBitmap() else { return -1 }
            let scale = CGFloat(bitmap.pixelsWide) / max(layout.collapsedFrame.width, 1)
            // 只看左半侧（刘海左边那块），量它非透明像素的宽度
            let probe = CGRect(x: 0, y: 0, width: layout.collapsedLeftEarRect.width,
                               height: layout.collapsedFrame.height)
            // 阈值必须高：展开态面板体的阴影（alpha≈38）会落进这一带
            guard let bounds = alphaBounds(bitmap, region: probe, scale: scale, threshold: 200) else { return 0 }
            return bounds.width
        }

        let full = renderedEarWidth()
        check("收起态耳朵宽度 ≈ 配置值", abs(full - layout.earWidth) < 6,
              "实测 \(full) vs 配置 \(layout.earWidth)")

        // 量的不只是宽度，还有它相对刘海的位置：
        // 内边缘必须钉在刘海边缘（固定），收缩时**外边缘**往里收。
        func renderedEarBox() -> CGRect? {
            guard let bitmap = controller.renderContentBitmap() else { return nil }
            let frame = controller.windowFrame
            let scale = CGFloat(bitmap.pixelsWide) / max(frame.width, 1)
            let notchLeft = geometry.notchRect.minX - frame.minX
            // 探测区要越过刘海边缘一点：黑耳内侧会故意多画 12pt 去填刘海的圆角
            let probe = CGRect(x: max(0, notchLeft - layout.earWidth - 6), y: 0,
                               width: layout.earWidth + 20, height: max(4, layout.bandHeight - 4))
            return alphaBounds(bitmap, region: probe, scale: scale, threshold: 200)
        }
        if let box = renderedEarBox() {
            let notchLeft = geometry.notchRect.minX - controller.windowFrame.minX
            check("收起态左耳内边缘贴在刘海左边缘（锚点正确）",
                  abs(box.maxX - notchLeft) < 4, "内边缘 \(Int(box.maxX)) vs 刘海 \(Int(notchLeft))")
        }

        // 展开：采样耳朵宽度，必须是"逐渐收进去"而不是瞬间消失
        controller.forceState(.expanded, animated: true)
        var shrinking: [CGFloat] = []
        let start = Date()
        var timeline: [String] = []
        for _ in 0..<12 {
            pump(0.04)
            let w = renderedEarWidth()
            shrinking.append(w)
            timeline.append(String(format: "%.0fms:%d", Date().timeIntervalSince(start) * 1000, Int(w)))
        }
        info("耳朵收起时间线 \(timeline.joined(separator: " "))")
        let intermediates = shrinking.filter { $0 > 4 && $0 < full - 6 }
        check("展开时耳朵是逐渐收进去的（有中间宽度）", intermediates.count >= 2,
              "中间宽度 \(intermediates.count) 个：\(intermediates.map { Int($0) })")

        // 关键回归断言：整个收缩过程中，内边缘必须始终贴住刘海边缘（不动），
        // 否则黑耳是"朝屏幕外缩走"，方向就反了。
        var innerEdges: [CGFloat] = []
        controller.setIndicatorEarProgressForTest(1)
        pump(0.15)
        for progress in [CGFloat(1.0), 0.75, 0.5, 0.25] {
            controller.setIndicatorEarProgressForTest(progress)
            pump(0.06)
            if let box = renderedEarBox() {
                let notchLeft = geometry.notchRect.minX - controller.windowFrame.minX
                innerEdges.append(box.maxX - notchLeft)
            }
        }
        info("各进度下「内边缘 - 刘海边缘」的偏差：\(innerEdges.map { Int($0) })")
        // 判据：1) 全程恒定（内边缘不移动）；2) 停在刘海边缘附近（允许故意越过 12pt 填圆角）。
        // 若锚点错了（按窗口边缘起画），这里会看到偏差随时间从 ~12 一路涨到 earWidth。
        let spread = (innerEdges.max() ?? 0) - (innerEdges.min() ?? 0)
        check("收缩全程内边缘不移动（钉在刘海边缘，不会朝屏幕外缩）",
              // 判定要点是"恒定"：锚点若错（按窗口边缘起画），偏差会随进度一路涨到耳宽。
              // 允许一个小常量偏移 —— 那是黑耳刻意越过刘海边缘、去填刘海圆角的部分。
              innerEdges.count >= 3 && spread <= 2
              && innerEdges.allSatisfy { $0 > -4 && $0 < layout.earWidth * 0.35 },
              "偏差 \(innerEdges.map { Int($0) })，波动 \(Int(spread))")
        check("展开结束时耳朵已完全收起", (shrinking.last ?? 99) < 6, "末值 \(shrinking.last ?? -1)")

        // 收起：耳朵要长回来
        controller.forceState(.collapsed, animated: true)
        pump(0.6)
        let regrown = renderedEarWidth()
        check("收起后耳朵长回原长度", abs(regrown - layout.earWidth) < 6,
              "实测 \(regrown) vs 配置 \(layout.earWidth)")
        controller.stop()
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func dumpPathArgument() -> String? {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--dump-render"), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private static func dump(_ bitmap: NSBitmapImageRep, suffix: String) {
        guard let path = dumpPathArgument() else { return }
        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension().lastPathComponent
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(base)-\(suffix)")
            .appendingPathExtension("png")
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: target)
        info("已导出渲染结果：\(target.path)")
    }

    // MARK: - 位图取样

    /// 设置界面验证：能打开、能渲染出内容、关闭后释放。
    /// （无法用鼠标点，所以用离屏渲染确认它真的画出来了）
    private static func verifySettingsWindow(service: MonitorService) {
        let suite = "dev.litestats.selftest"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check("设置界面：可创建独立偏好域", false)
            return
        }
        defaults.removePersistentDomain(forName: suite)
        let preferences = Preferences(defaults: defaults)
        preferences.leftIndicator = .cpu
        preferences.rightIndicator = .temperature
        preferences.earWidth = 104

        let controller = SettingsWindowController(preferences: preferences, service: service,
                                                  onOpenHistory: {})
        controller.present()
        pump(0.8)

        guard let window = controller.window, let content = window.contentView else {
            check("设置窗口可以打开", false, "window/contentView 为 nil")
            return
        }
        check("设置窗口可以打开", window.isVisible)
        check("设置窗口标题正确", window.title == "LiteStats 设置", window.title)

        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / max(content.bounds.width, 1)
            let whole = CGRect(origin: .zero, size: content.bounds.size)
            let coverage = alphaCoverage(bitmap, region: whole, scale: scale, threshold: 128)
            info(String(format: "设置界面离屏渲染 %d×%dpx 覆盖率 %.1f%%",
                        bitmap.pixelsWide, bitmap.pixelsHigh, coverage * 100))
            check("设置界面渲染出内容（覆盖率 > 85%）", coverage > 0.85,
                  String(format: "%.1f%%", coverage * 100))
            dump(bitmap, suffix: "settings")
        } else {
            check("设置界面离屏渲染可用", false, "bitmapImageRepForCachingDisplay 返回 nil")
        }

        // 偏好改动要能落盘（用独立 suite，不污染真实设置）
        let reread = Preferences(defaults: defaults)
        check("设置项可持久化", reread.leftIndicator == .cpu && reread.rightIndicator == .temperature
              && abs(reread.earWidth - 104) < 0.01,
              "左=\(reread.leftIndicator.rawValue) 右=\(reread.rightIndicator.rawValue) 耳长=\(reread.earWidth)")

        window.close()
        pump(0.2)
        defaults.removePersistentDomain(forName: suite)
    }

    private static func alphaIndex(_ bitmap: NSBitmapImageRep) -> Int? {
        guard bitmap.hasAlpha else { return nil }
        return bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : max(bitmap.samplesPerPixel, 1) - 1
    }

    /// `point` 为窗口内左上原点的点坐标
    private static func alphaAt(_ bitmap: NSBitmapImageRep, point: CGPoint, scale: CGFloat) -> Int {
        guard let data = bitmap.bitmapData, let index = alphaIndex(bitmap) else { return bitmap.hasAlpha ? 0 : 255 }
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else { return 0 }
        let row = data + y * bitmap.bytesPerRow
        return Int(row[x * max(bitmap.samplesPerPixel, 1) + index])
    }

    /// 区域内"接近不透明"的像素占比（阈值 200，用来排除阴影与半透明羽化）
    private static func alphaCoverage(_ bitmap: NSBitmapImageRep, region: CGRect, scale: CGFloat,
                                      threshold: UInt8 = 200) -> Double {
        guard let data = bitmap.bitmapData, let index = alphaIndex(bitmap) else { return 0 }
        let spp = max(bitmap.samplesPerPixel, 1)
        let minX = max(0, Int(region.minX * scale))
        let maxX = min(bitmap.pixelsWide, Int(region.maxX * scale))
        let minY = max(0, Int(region.minY * scale))
        let maxY = min(bitmap.pixelsHigh, Int(region.maxY * scale))
        guard maxX > minX, maxY > minY else { return 0 }
        var opaque = 0
        var total = 0
        for y in minY..<maxY {
            let row = data + y * bitmap.bytesPerRow
            for x in minX..<maxX {
                total += 1
                if row[x * spp + index] >= threshold { opaque += 1 }
            }
        }
        return total == 0 ? 0 : Double(opaque) / Double(total)
    }

    /// 非透明像素的包围盒（窗口内左上原点、点坐标）。用于判断"画出来的东西长到多大了"
    private static func alphaBounds(_ bitmap: NSBitmapImageRep, region: CGRect? = nil, scale: CGFloat,
                                    threshold: UInt8 = 40) -> CGRect? {
        guard let data = bitmap.bitmapData, let index = alphaIndex(bitmap) else { return nil }
        let spp = max(bitmap.samplesPerPixel, 1)
        let x0 = max(0, Int((region?.minX ?? 0) * scale))
        let x1 = min(bitmap.pixelsWide, Int((region?.maxX ?? CGFloat(bitmap.pixelsWide)) * scale))
        let y0 = max(0, Int((region?.minY ?? 0) * scale))
        let y1 = min(bitmap.pixelsHigh, Int((region?.maxY ?? CGFloat(bitmap.pixelsHigh)) * scale))
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in y0..<max(y0, y1) {
            let row = data + y * bitmap.bytesPerRow
            for x in x0..<max(x0, x1) where row[x * spp + index] >= threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY, scale > 0 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    private static func maxAlpha(_ bitmap: NSBitmapImageRep) -> Int {
        guard let data = bitmap.bitmapData, let index = alphaIndex(bitmap) else { return bitmap.hasAlpha ? 0 : 255 }
        let spp = max(bitmap.samplesPerPixel, 1)
        var maximum = 0
        for y in 0..<bitmap.pixelsHigh {
            let row = data + y * bitmap.bytesPerRow
            for x in 0..<bitmap.pixelsWide {
                maximum = max(maximum, Int(row[x * spp + index]))
            }
        }
        return maximum
    }
}
