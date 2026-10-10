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
        info("刘海矩形=\(geometry.notchRect.map(rect) ?? "无（回退为菜单栏下方胶囊）")")
        check("拿到有效屏幕", geometry.screenFrame.width > 100 && geometry.screenFrame.height > 100)
        check("菜单栏/刘海高度 > 0", geometry.menuBarHeight > 0, "\(geometry.menuBarHeight)")

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

        if let notch = geometry.notchRect {
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
        verifyIndicators(geometry: geometry, baseLayout: layout, service: service)

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
            check("单次采样耗时 < 10 ms", service.lastSampleMillis < 10,
                  String(format: "%.2f ms", service.lastSampleMillis))
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

        print("=== 自检结果：\(checkCount - failures.count)/\(checkCount) 通过 ===")
        if !failures.isEmpty {
            print("失败项：\(failures.joined(separator: "、"))")
            exit(1)
        }
        print("SELFTEST RESULT: PASS")
        exit(0)
    }

    // MARK: - 工具

    /// 常驻指示条验证：几何（黑耳放得下指示条、不越界/不覆盖刘海）+ 真实绘制 + 展开后自动隐藏
    private static func verifyIndicators(geometry: ScreenGeometry, baseLayout: PanelLayout,
                                         service: MonitorService) {
        guard geometry.hasNotch, let notch = geometry.notchRect else {
            info("无刘海屏幕，跳过指示条验证（回退模式下用菜单栏下方胶囊）")
            return
        }

        var layout = baseLayout
        layout.leftIndicatorWidth = IndicatorMetric.cpu.indicatorWidth
        layout.rightIndicatorWidth = IndicatorMetric.network.indicatorWidth
        let leftEar = layout.collapsedLeftEarRect
        let rightEar = layout.collapsedRightEarRect
        info("指示条布局：收起 frame=\(rect(layout.collapsedFrame)) 左耳=\(rect(leftEar)) 右耳=\(rect(rightEar))")

        check("左侧黑耳容得下指示条", leftEar.width >= layout.leftIndicatorWidth + 2,
              "耳 \(leftEar.width) vs 指示条 \(layout.leftIndicatorWidth)")
        check("右侧黑耳容得下指示条", rightEar.width >= layout.rightIndicatorWidth + 2,
              "耳 \(rightEar.width) vs 指示条 \(layout.rightIndicatorWidth)")
        check("黑耳不侵占刘海区域",
              leftEar.maxX <= notch.minX - layout.collapsedFrame.minX + 0.5
              && rightEar.minX >= notch.maxX - layout.collapsedFrame.minX - 0.5)
        check("收起热区比刘海宽出指示条部分",
              layout.collapsedFrame.width > notch.width + layout.leftIndicatorWidth)
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
        check("收起态指示条可见", !controller.indicatorIsHidden)
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
        } else {
            check("指示条离屏渲染可用", false, "bitmapImageRepForCachingDisplay 返回 nil")
        }

        controller.forceState(.expanded, animated: false)
        pump(0.45)
        check("展开后指示条自动隐藏（由岛颈接管）", controller.indicatorIsHidden)
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
        preferences.tabFlank = 30

        let controller = SettingsWindowController(preferences: preferences, service: service)
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
              && abs(reread.tabFlank - 30) < 0.01,
              "左=\(reread.leftIndicator.rawValue) 右=\(reread.rightIndicator.rawValue) 岛颈=\(reread.tabFlank)")

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
