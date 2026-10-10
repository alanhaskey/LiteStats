import AppKit

/// 屏幕几何与面板布局（纯值类型，无副作用，可用 `--selftest` 验证）
///
/// 坐标系约定：全部使用 AppKit 全局坐标（原点在**左下角**）作为窗口 frame 的依据；
/// SwiftUI 绘制用的窗口内坐标（原点左上）由 `PanelLayout` 提供，避免两套坐标混淆。
struct ScreenGeometry: Equatable {
    /// 屏幕 ID（CGDirectDisplayID），用于跨次刷新识别同一块屏
    let displayID: UInt32
    let screenFrame: CGRect
    let visibleFrame: CGRect
    /// 菜单栏高度（有刘海时即刘海高度）
    let menuBarHeight: CGFloat
    /// 刘海矩形（全局坐标）；无刘海屏为 nil
    let notchRect: CGRect?
    let backingScale: CGFloat

    var screenTop: CGFloat { screenFrame.maxY }
    var hasNotch: Bool { notchRect != nil }
    /// 面板水平锚点：刘海中心；无刘海时用屏幕中心
    var anchorX: CGFloat { notchRect?.midX ?? screenFrame.midX }

    // MARK: - 检测

    /// 读取某块屏幕的刘海矩形。
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

    /// 选择要挂载面板的屏幕：优先带刘海的内置屏，其次主屏。
    ///
    /// `previous` 用于菜单栏自动隐藏（此时系统可能不再返回 auxiliary 区域）时兜底复用上一次的刘海尺寸，
    /// 避免面板突然"掉"到菜单栏下方。
    static func resolve(screens: [NSScreen] = NSScreen.screens,
                        main: NSScreen? = NSScreen.main,
                        previous: ScreenGeometry? = nil) -> ScreenGeometry? {
        guard !screens.isEmpty else { return nil }
        let notched = screens.first { detectNotch(of: $0) != nil }
        let target = notched ?? previous.flatMap { prev in
            screens.first { displayID(of: $0) == prev.displayID }
        } ?? main ?? screens[0]

        let id = displayID(of: target)
        var notch = detectNotch(of: target)

        // 菜单栏自动隐藏兜底：同一块屏上次测到过刘海，就用上次的尺寸重建
        if notch == nil, let prev = previous, prev.displayID == id, let prevNotch = prev.notchRect {
            let h = prevNotch.height
            notch = CGRect(x: prevNotch.midX - prevNotch.width / 2,
                           y: target.frame.maxY - h,
                           width: prevNotch.width, height: h)
        }

        let derivedBar = target.frame.maxY - target.visibleFrame.maxY
        let menuBar = max(notch?.height ?? 0, max(target.safeAreaInsets.top, derivedBar))
        return ScreenGeometry(displayID: id,
                              screenFrame: target.frame,
                              visibleFrame: target.visibleFrame,
                              menuBarHeight: menuBar,
                              notchRect: notch,
                              backingScale: target.backingScaleFactor)
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
    /// 展开态"岛颈"在刘海左右各外扩多少（可见的小黑耳）。
    /// 不同机型刘海宽度不同，这里由用户配置（0 = 完全不外扩）。
    var tabFlank: CGFloat = 24
    /// 常驻指示条占用宽度（0 = 该侧不显示）
    var leftIndicatorWidth: CGFloat = 0
    var rightIndicatorWidth: CGFloat = 0
    /// 指示条文本与刘海边缘之间的最小留白
    var indicatorInset: CGFloat = 10
    /// 无刘海屏时，收起态小胶囊的尺寸与距屏幕顶部的间距
    var fallbackPillSize = CGSize(width: 132, height: 26)
    var fallbackTopGap: CGFloat = 8
    /// 面板体底部圆角
    var cornerRadius: CGFloat = 20

    var isFallback: Bool { !geometry.hasNotch }

    /// 顶部菜单栏带高度：有刘海时等于菜单栏高，无刘海时收起物本身就在下方
    var bandHeight: CGFloat { isFallback ? 0 : geometry.menuBarHeight }

    /// 黑耳在刘海左右的实际额外宽度：该侧有指示条时让出位置，否则用用户配置的岛颈宽度
    var leftEarWidth: CGFloat {
        leftIndicatorWidth > 0 ? max(tabFlank, leftIndicatorWidth + indicatorInset) : tabFlank
    }
    var rightEarWidth: CGFloat {
        rightIndicatorWidth > 0 ? max(tabFlank, rightIndicatorWidth + indicatorInset) : tabFlank
    }

    /// 收起态热区左右外扩量（必须 ≥ 耳宽，否则鼠标够不到指示条）
    var collapsedLeftExtent: CGFloat { max(collapsedFlank, leftEarWidth) }
    var collapsedRightExtent: CGFloat { max(collapsedFlank, rightEarWidth) }

    /// 收起态窗口 frame（全局坐标）
    var collapsedFrame: CGRect {
        if geometry.hasNotch {
            let notchWidth = geometry.notchRect?.width ?? 120
            let left = geometry.anchorX - notchWidth / 2 - collapsedLeftExtent
            let right = geometry.anchorX + notchWidth / 2 + collapsedRightExtent
            let height = geometry.menuBarHeight
            return CGRect(x: left, y: geometry.screenTop - height, width: right - left, height: height)
        }
        let size = fallbackPillSize
        let y = geometry.screenTop - geometry.menuBarHeight - fallbackTopGap - size.height
        return CGRect(x: geometry.anchorX - size.width / 2, y: y, width: size.width, height: size.height)
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
        let height = bodyHeight + bodyTopInset + bandHeight
        // 有刘海：窗口顶边贴屏幕顶部（含菜单栏带，用于画"岛颈"）
        // 无刘海：窗口顶边对齐收起胶囊顶边，面板挂在胶囊下方，完全不碰菜单栏
        let top = geometry.hasNotch ? geometry.screenTop : collapsed.maxY
        return CGRect(x: left, y: top - height, width: right - left, height: height)
    }

    /// 面板体相对窗口顶部的额外内缩。
    /// 有刘海：0（岛颈直接接面板体）；无刘海：让开收起胶囊本身的高度 + 一点缝隙
    var bodyTopInset: CGFloat {
        isFallback ? fallbackPillSize.height + fallbackTopGap : 0
    }

    /// SwiftUI 绘制用：窗口内左上原点坐标下的"岛颈"矩形（有刘海时才有意义）。
    /// 基于**展开**窗口坐标（SwiftUI 内容只在展开时构建，此时窗口 = 展开 frame）。
    var tabRect: CGRect {
        guard let notch = geometry.notchRect, !isFallback else { return .zero }
        let frame = expandedFrame
        let left = notch.minX - leftEarWidth - frame.minX
        let right = notch.maxX + rightEarWidth - frame.minX
        return CGRect(x: left, y: 0, width: max(0, right - left), height: bandHeight)
    }

    /// 物理刘海的底边比菜单栏底边高出的量（本机 39 - 38 = 1pt）。
    /// 收起态的黑耳要和物理刘海"无缝连成一体"，所以它的底边必须贴齐**刘海**底边，
    /// 而不是菜单栏底边；否则会多出一条 1pt 的错台。
    var notchBottomInset: CGFloat {
        guard let notch = geometry.notchRect, !isFallback else { return 0 }
        return max(0, bandHeight - notch.height)
    }

    /// 物理刘海底部圆角半径。系统没有 API 能读到，按机型取经验值 10pt。
    var notchCornerRadius: CGFloat { geometry.hasNotch ? 10 : 0 }

    /// SwiftUI 绘制用：展开窗口内（左上原点）的**物理刘海**矩形。
    /// 形变动画的起点就是它 —— progress = 0 时轮廓与物理刘海完全重合，所以"完全收入灵动岛"。
    var notchRect: CGRect {
        guard let notch = geometry.notchRect, !isFallback else { return .zero }
        return CGRect(x: notch.minX - expandedFrame.minX, y: 0,
                      width: notch.width, height: bandHeight)
    }

    /// AppKit 指示条绘制用：**收起态**窗口内（左下原点，与容器视图一致）的左右黑耳矩形
    var collapsedLeftEarRect: CGRect {
        guard let notch = geometry.notchRect, !isFallback else { return .zero }
        let frame = collapsedFrame
        let notchLeft = notch.minX - frame.minX
        return CGRect(x: 0, y: 0, width: max(0, notchLeft), height: frame.height)
    }

    var collapsedRightEarRect: CGRect {
        guard let notch = geometry.notchRect, !isFallback else { return .zero }
        let frame = collapsedFrame
        let notchRight = notch.maxX - frame.minX
        return CGRect(x: notchRight, y: 0, width: max(0, frame.width - notchRight), height: frame.height)
    }

    /// SwiftUI 绘制用：窗口内左上原点坐标下的面板体矩形。
    /// 窗口可能因为指示条而比面板宽，此时面板体仍然要**以刘海为居中**。
    var bodyRect: CGRect {
        let width = min(panelWidth, expandedFrame.width)
        let centerInWindow = geometry.anchorX - expandedFrame.minX
        return CGRect(x: centerInWindow - width / 2, y: bandHeight + bodyTopInset,
                      width: width, height: bodyHeight)
    }

    /// 窗口总尺寸（SwiftUI 根视图尺寸）
    var windowSize: CGSize {
        CGSize(width: expandedFrame.width, height: bodyHeight + bodyTopInset + bandHeight)
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
