import AppKit

/// 屏幕几何与面板布局（纯值类型，无副作用，可用 `--selftest` 验证）
///
/// 坐标系约定：全部使用 AppKit 全局坐标（原点在**左下角**）作为窗口 frame 的依据；
/// SwiftUI 绘制用的窗口内坐标（原点左上）由 `PanelLayout` 提供，避免两套坐标混淆。
///
/// 关键设计：**所有屏幕都有 `notchRect`**。
/// 有物理刘海时是它本身；没有刘海（外接屏 / 非刘海机型）时，用**顶部中心一个等高的"合成缺口"**代替，
/// 这样"收起态极小窗口 + 顶部中心悬浮热区 + 展开动画"整套交互在任何屏幕上完全一致。
struct ScreenGeometry: Equatable {
    /// 屏幕 ID（CGDirectDisplayID），用于跨次刷新识别同一块屏
    let displayID: UInt32
    let name: String
    let screenFrame: CGRect
    let visibleFrame: CGRect
    /// 菜单栏高度（有物理刘海时即刘海高度）
    let menuBarHeight: CGFloat
    /// "刘海"矩形（全局坐标）：物理刘海，或顶部中心的合成缺口
    let notchRect: CGRect
    /// true = 物理刘海；false = 合成缺口（无刘海屏）
    let hasPhysicalNotch: Bool
    let backingScale: CGFloat

    var screenTop: CGFloat { screenFrame.maxY }
    /// 面板水平锚点 = 缺口中心（无刘海屏就是屏幕中心）
    var anchorX: CGFloat { notchRect.midX }

    // MARK: - 检测

    /// 读取某块屏幕的物理刘海矩形。
    /// `auxiliaryTopLeftArea/RightArea` 只在 macOS 12+ 且屏幕有摄像头凹口时非 nil。
    static func detectNotch(of screen: NSScreen) -> CGRect? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let width = right.minX - left.maxX
        guard width > 40, left.height > 0 else { return nil }
        // 文档说明这两个矩形已是屏幕（全局）坐标，直接用，不要再用 frame 换算，
        // 否则多显示器（frame.origin 非零）时会错位。
        return CGRect(x: left.maxX, y: left.minY, width: width, height: left.height)
    }

    static func displayID(of screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// 无刘海屏的"圆槽"：顶部居中的一颗胶囊（不是与菜单栏同高的假刘海）。
    ///
    /// 为什么不照搬物理刘海的形状：物理刘海有屏幕顶部那条边可以"融进去"，
    /// 外接屏没有，画一个贴顶的黑色方块只会像个突兀的补丁。
    /// 一颗常驻胶囊既能一直看得见（可发现性），又能放数据/表情，悬浮时再长成面板。
    static func syntheticSlot(screenFrame: CGRect, menuBarHeight: CGFloat,
                              size: CGSize = CGSize(width: 138, height: 26)) -> CGRect {
        let width = min(size.width, max(90, screenFrame.width * 0.2))
        let height = min(size.height, max(18, menuBarHeight - 4))
        return CGRect(x: screenFrame.midX - width / 2,
                      y: screenFrame.maxY - menuBarHeight + (menuBarHeight - height) / 2,
                      width: width, height: height)
    }

    /// 兼容旧名（自检里用到）
    static func syntheticNotch(screenFrame: CGRect, menuBarHeight: CGFloat) -> CGRect {
        syntheticSlot(screenFrame: screenFrame, menuBarHeight: menuBarHeight)
    }

    /// 某块屏幕的完整几何。
    ///
    /// `previous` 用于菜单栏自动隐藏（此时系统可能不再返回 auxiliary 区域）时，
    /// 复用上一次测到的刘海尺寸，避免"岛"突然换成合成缺口。
    static func geometry(for screen: NSScreen, previous: ScreenGeometry? = nil) -> ScreenGeometry {
        let id = displayID(of: screen)
        let frame = screen.frame
        let derivedBar = frame.maxY - screen.visibleFrame.maxY
        let physical = detectNotch(of: screen)

        // 菜单栏自动隐藏兜底：同一块屏上次测到过物理刘海，就用上次的尺寸在原位置重建
        var notch = physical
        if notch == nil, let prev = previous, prev.displayID == id, prev.hasPhysicalNotch {
            let h = prev.notchRect.height
            notch = CGRect(x: prev.notchRect.midX - prev.notchRect.width / 2,
                           y: frame.maxY - h, width: prev.notchRect.width, height: h)
        }

        let menuBar = max(notch?.height ?? 0, max(screen.safeAreaInsets.top, derivedBar, 24))
        let rect = notch ?? syntheticSlot(screenFrame: frame, menuBarHeight: menuBar)
        return ScreenGeometry(displayID: id,
                              name: screen.localizedName,
                              screenFrame: frame,
                              visibleFrame: screen.visibleFrame,
                              menuBarHeight: menuBar,
                              notchRect: rect,
                              hasPhysicalNotch: notch != nil,
                              backingScale: screen.backingScaleFactor)
    }

    /// 所有屏幕的几何（多屏同时显示时用）
    static func all(screens: [NSScreen] = NSScreen.screens,
                    previous: [UInt32: ScreenGeometry] = [:]) -> [ScreenGeometry] {
        screens.map { geometry(for: $0, previous: previous[displayID(of: $0)]) }
    }

    /// 自动挑一块屏：优先带物理刘海的，其次主屏，最后第一块。
    static func resolve(screens: [NSScreen] = NSScreen.screens,
                        main: NSScreen? = NSScreen.main,
                        previous: ScreenGeometry? = nil) -> ScreenGeometry? {
        guard !screens.isEmpty else { return nil }
        let notched = screens.first { detectNotch(of: $0) != nil }
        let target = notched ?? previous.flatMap { prev in
            screens.first { displayID(of: $0) == prev.displayID }
        } ?? main ?? screens[0]
        return geometry(for: target, previous: previous)
    }
}

/// 面板布局：由 `ScreenGeometry` 推导收起/展开两态窗口 frame 与 SwiftUI 绘制区域。
struct PanelLayout: Equatable {
    var geometry: ScreenGeometry
    /// 展开面板体宽度
    var panelWidth: CGFloat = 400
    /// 展开面板体高度（不含菜单栏带）
    var bodyHeight: CGFloat = 234
    /// 收起态热区在刘海左右各外扩多少（有刘海时）
    var collapsedFlank: CGFloat = 26
    /// 刘海两侧黑耳的**统一长度**（pt）。两侧等长、与显示内容无关，内容在其中居中。
    var earWidth: CGFloat = 88
    /// 该侧是否有指示条（没有就完全不画黑耳，折叠/展开都不额外露耳朵）
    var leftEarActive = false
    var rightEarActive = false
    /// 面板体底部圆角
    var cornerRadius: CGFloat = 20

    /// 无刘海屏上那颗常驻圆槽：中间"表情"那块的基础宽度 + 高度
    var slotCenterWidth: CGFloat = 32
    var slotHeight: CGFloat = 26

    /// 是否是无刘海屏（用圆槽而不是物理刘海）
    var usesSlot: Bool { !geometry.hasPhysicalNotch }

    /// 圆槽左右两段的宽度：有指标的那一侧 = **黑耳长度**（和物理刘海屏的黑耳同一个设置），
    /// 没有指标就是 0。所以"黑耳长度"同样决定圆槽有多长。
    var slotLeftWidth: CGFloat { leftEarActive ? earWidth : 0 }
    var slotRightWidth: CGFloat { rightEarActive ? earWidth : 0 }

    /// 无刘海屏：收起态就是这颗圆槽。三段式 `[左指标] 表情 [右指标]`：
    /// 两边都没配指标时只剩中间那颗表情。
    var slotRect: CGRect {
        let width = slotCenterWidth + slotLeftWidth + slotRightWidth
        return CGRect(x: geometry.notchRect.midX - width / 2,
                      y: geometry.notchRect.minY,
                      width: width, height: slotHeight)
    }

    /// 顶部菜单栏带高度：岛颈就画在这一带里
    var bandHeight: CGFloat { geometry.menuBarHeight }

    /// 黑耳在刘海左右的实际额外宽度：**只有该侧选了指标才画**，两侧长度一致。
    /// 没选指标那一侧为 0 —— 折叠和展开都不会多出一块耳朵。
    var leftEarWidth: CGFloat { leftEarActive ? earWidth : 0 }
    var rightEarWidth: CGFloat { rightEarActive ? earWidth : 0 }

    /// 收起态热区左右外扩量（必须 ≥ 耳宽，否则鼠标够不到指示条）
    var collapsedLeftExtent: CGFloat { max(collapsedFlank, leftEarWidth) }
    var collapsedRightExtent: CGFloat { max(collapsedFlank, rightEarWidth) }

    /// 收起态窗口 frame（全局坐标）
    /// - 有物理刘海：贴着屏幕顶部、以刘海为中心的一条带（悬浮热区在菜单栏带里）
    /// - 无刘海屏：就是那颗圆槽本身（位置/高度都跟着圆槽走）
    var collapsedFrame: CGRect {
        if usesSlot {
            var rect = slotRect
            // 圆槽外仍然留一点热区，避免必须精确压中
            rect = rect.insetBy(dx: -6, dy: -2)
            return rect
        }
        let notchWidth = geometry.notchRect.width
        let left = geometry.anchorX - notchWidth / 2 - collapsedLeftExtent
        let right = geometry.anchorX + notchWidth / 2 + collapsedRightExtent
        let height = geometry.menuBarHeight
        return CGRect(x: left, y: geometry.screenTop - height, width: right - left, height: height)
    }

    /// 展开态窗口 frame（全局坐标）。
    /// 不变式：**必须完整包含 `collapsedFrame`**，否则鼠标从刘海移到面板途中会触发移出、导致反复抖动。
    var expandedFrame: CGRect {
        // 指示条左右宽度可能不等 → 收起 frame 不再以刘海为对称中心，
        // 所以展开 frame 不能只"宽度取大"，而要真正取两者的并集。
        let collapsed = collapsedFrame
        let centered = CGRect(x: geometry.anchorX - panelWidth / 2, y: 0, width: panelWidth, height: 0)
        let left = min(centered.minX, collapsed.minX)
        let right = max(centered.maxX, collapsed.maxX)
        let height = bodyHeight + bandHeight
        return CGRect(x: left, y: geometry.screenTop - height, width: right - left, height: height)
    }

    /// SwiftUI 绘制用：窗口内左上原点坐标下的"岛颈"矩形（有刘海时才有意义）。
    ///
    /// **永远等于物理刘海宽度**：黑耳在展开过程中会收进刘海（`NotchIndicatorView.earProgress`），
    /// 所以展开态的岛颈不带任何多余的黑耳 —— 展开后只剩"刘海 + 下方面板"。
    var tabRect: CGRect { notchRect }

    /// 物理刘海的底边比菜单栏底边高出的量（本机 39 - 38 = 1pt）。
    /// 收起态的黑耳要和物理刘海"无缝连成一体"，所以它的底边必须贴齐**刘海**底边，
    /// 而不是菜单栏底边；否则会多出一条 1pt 的错台。
    var notchBottomInset: CGFloat {
        max(0, bandHeight - geometry.notchRect.height)
    }

    /// 缺口底部圆角半径。物理刘海的真实半径系统读不到，按机型取经验值 10pt。
    var notchCornerRadius: CGFloat { 10 }

    /// SwiftUI 绘制用：展开窗口内（左上原点）的**物理刘海**矩形。
    /// 形变动画的起点就是它 —— progress = 0 时轮廓与物理刘海完全重合，所以"完全收入灵动岛"。
    var notchRect: CGRect {
        let notch = geometry.notchRect
        return CGRect(x: notch.minX - expandedFrame.minX, y: 0,
                      width: notch.width, height: bandHeight)
    }

    /// AppKit 指示条绘制用：**收起态**窗口内（左下原点，与容器视图一致）的左右黑耳矩形
    var collapsedLeftEarRect: CGRect {
        let notch = geometry.notchRect
        let frame = collapsedFrame
        let notchLeft = notch.minX - frame.minX
        return CGRect(x: 0, y: 0, width: max(0, notchLeft), height: frame.height)
    }

    var collapsedRightEarRect: CGRect {
        let notch = geometry.notchRect
        let frame = collapsedFrame
        let notchRight = notch.maxX - frame.minX
        return CGRect(x: notchRight, y: 0, width: max(0, frame.width - notchRight), height: frame.height)
    }

    /// SwiftUI 绘制用：展开窗口内（左上原点）的圆槽矩形（无刘海屏的画法）
    var slotRectInExpandedWindow: CGRect {
        let frame = expandedFrame
        var rect = slotRect
        rect.origin.x -= frame.minX
        rect.origin.y = frame.maxY - rect.maxY
        return rect
    }

    /// SwiftUI 绘制用：窗口内左上原点坐标下的面板体矩形。
    /// 窗口可能因为指示条而比面板宽，此时面板体仍然要**以刘海为居中**。
    var bodyRect: CGRect {
        let width = min(panelWidth, expandedFrame.width)
        let centerInWindow = geometry.anchorX - expandedFrame.minX
        return CGRect(x: centerInWindow - width / 2, y: bandHeight,
                      width: width, height: bodyHeight)
    }

    /// 窗口总尺寸（SwiftUI 根视图尺寸）
    var windowSize: CGSize {
        CGSize(width: expandedFrame.width, height: bodyHeight + bandHeight)
    }

    /// 判定某个全局坐标点是否落在"展开时应保持展开"的区域内。
    /// = 收起热区 ∪ 面板体（不含顶部菜单栏带的空白部分），这样鼠标从刘海滑到面板的路径是连续的。
    func keepsExpanded(point: CGPoint) -> Bool {
        let slack: CGFloat = 2
        if collapsedFrame.insetBy(dx: -slack, dy: -slack).contains(point) { return true }
        let local = bodyRect
        let bodyGlobal = CGRect(x: expandedFrame.minX + local.minX,
                                y: expandedFrame.maxY - local.maxY,
                                width: local.width, height: local.height)
        return bodyGlobal.insetBy(dx: -slack, dy: -slack).contains(point)
    }

    /// 收起态是否应该开始展开
    func shouldExpand(point: CGPoint) -> Bool {
        collapsedFrame.insetBy(dx: -1, dy: -1).contains(point)
    }
}
