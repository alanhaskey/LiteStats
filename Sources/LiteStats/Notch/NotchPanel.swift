import AppKit

/// 承载灵动岛内容的浮层窗口。
///
/// 关键点：
/// 1. `level = .statusBar(25)` 高于菜单栏（`.mainMenu = 24`），否则窗口会被菜单栏挡住、悬浮事件也收不到；
///    但仍低于 `.popUpMenu(101)` 与屏保，不会挡住系统弹窗。
/// 2. `constrainFrameRect` 必须重写：AppKit 默认会把窗口往下压、避免遮挡菜单栏，
///    会让"贴着屏幕顶部"的岛颈错位。
/// 3. `.nonactivatingPanel` 保证鼠标悬浮/点击不会抢走当前 App 的焦点。
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        // 必须接收鼠标事件，否则无法做悬浮检测
        ignoresMouseEvents = false
        // 不出现在窗口菜单 / 不参与截图以外的特殊处理
        isExcludedFromWindowsMenu = true
    }

    /// 允许窗口贴合/越出菜单栏区域
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// 容器视图：纯透明层，只把 SwiftUI 内容铺满。
final class PanelContainerView: NSView {
    // 面板没有可编辑控件，允许"第一次点击"直接生效（即使 App 未激活）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
