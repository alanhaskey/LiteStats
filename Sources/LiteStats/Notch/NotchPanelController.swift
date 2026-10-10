import AppKit
import SwiftUI

/// SwiftUI 侧观察的呈现状态（窗口 frame 由 AppKit 控制，这里只管绘制与动画）。
@MainActor
@Observable
final class PanelPresentation {
    var isExpanded: Bool = false
    var isPinned: Bool = false
    var layout: PanelLayout

    init(layout: PanelLayout) {
        self.layout = layout
    }
}

/// 灵动岛面板控制器：负责窗口生命周期、悬浮状态机、屏幕变化重算。
///
/// 悬浮检测**只用轮询**（0.1 s 一次 `NSEvent.mouseLocation` 命中判定），不用 NSTrackingArea：
/// - 轮询是确定性的：状态 = f(鼠标位置)，不存在"鼠标已停在窗口内但没收到 enter 事件"的漏判；
/// - 窗口在收起/展开之间改尺寸时，tracking area 的 enter/exit 顺序很容易错乱导致抖动；
/// - 代价极低（一次 CGRect 判定，实测 <0.05% CPU）。
@MainActor
final class NotchPanelController {
    enum State: Equatable { case collapsed, expanded }

    private(set) var state: State = .collapsed
    private(set) var layout: PanelLayout
    let presentation: PanelPresentation

    /// 展开/收起回调（用于切换采样频率）
    var onStateChanged: ((State) -> Void)?

    private let panel: NotchPanel
    private let hosting: NSHostingView<PanelRootView>
    private let container = PanelContainerView(frame: .zero)

    private var pollTimer: Timer?
    private var pendingExpand: DispatchWorkItem?
    private var pendingCollapse: DispatchWorkItem?
    private var clickMonitor: Any?
    /// 关闭后不再响应真实鼠标位置（`--selftest` 用，保证测试可复现，不受物理鼠标位置影响）
    var hoverEnabled = true
    /// 展开后需要等待内容动画播完再改窗口尺寸，用代号避免快速切换时错序
    private var transitionGeneration = 0

    // 时序参数
    private let pollInterval: TimeInterval = 0.1
    private let expandDelay: TimeInterval = 0.10
    private let collapseDelay: TimeInterval = 0.35
    private let expandAnimation: TimeInterval = 0.26
    private let collapseAnimation: TimeInterval = 0.18

    init(layout: PanelLayout, service: MonitorService) {
        self.layout = layout
        self.presentation = PanelPresentation(layout: layout)
        self.panel = NotchPanel(frame: layout.collapsedFrame)
        self.hosting = NSHostingView(rootView: PanelRootView(service: service, presentation: presentation))

        container.frame = CGRect(origin: .zero, size: layout.collapsedFrame.size)
        container.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        // 由我们显式控制尺寸（窗口 frame 与 SwiftUI 内容尺寸严格对应），
        // 不让 hosting view 按内容固有尺寸反向撑大自己
        hosting.sizingOptions = []
        container.addSubview(hosting)
        panel.contentView = container

        installClickMonitor()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - 生命周期

    func start() {
        panel.setFrame(layout.collapsedFrame, display: true)
        panel.orderFrontRegardless()
        startPolling()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        panel.orderOut(nil)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // 用 .common 模式，菜单栏/滚动跟踪期间也要继续跑
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - 状态机

    private func poll() {
        guard hoverEnabled else { return }
        let mouse = NSEvent.mouseLocation
        if state == .collapsed {
            if layout.shouldExpand(point: mouse) {
                scheduleExpand()
            } else {
                cancelPendingExpand()
            }
        } else {
            if presentation.isPinned || layout.keepsExpanded(point: mouse) {
                cancelPendingCollapse()
            } else {
                scheduleCollapse()
            }
        }
    }

    private func scheduleExpand() {
        guard pendingExpand == nil, state == .collapsed else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingExpand = nil
                // 延迟期间鼠标可能已经离开；只有仍在热区内才展开
                guard self.layout.shouldExpand(point: NSEvent.mouseLocation) else { return }
                self.apply(state: .expanded, animated: true)
            }
        }
        pendingExpand = work
        DispatchQueue.main.asyncAfter(deadline: .now() + expandDelay, execute: work)
    }

    private func cancelPendingExpand() {
        pendingExpand?.cancel()
        pendingExpand = nil
    }

    private func scheduleCollapse() {
        guard pendingCollapse == nil, state == .expanded else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingCollapse = nil
                guard !self.presentation.isPinned,
                      !self.layout.keepsExpanded(point: NSEvent.mouseLocation) else { return }
                self.apply(state: .collapsed, animated: true)
            }
        }
        pendingCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: work)
    }

    private func cancelPendingCollapse() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
    }

    /// 唯一改状态的地方。窗口尺寸变化与内容动画的顺序在这里保证：
    /// - 展开：先把窗口撑大（此时内容还是透明的），再动画把内容淡入；
    /// - 收起：先动画淡出，动画结束后再把窗口缩回去（否则内容会被瞬间裁掉，出现闪断）。
    private func apply(state newState: State, animated: Bool) {
        transitionGeneration += 1
        let generation = transitionGeneration
        cancelPendingExpand()
        cancelPendingCollapse()
        guard newState != state else { return }
        state = newState
        Trace.log("state=\(newState) mouse=\(NSEvent.mouseLocation) frame=\(NSStringFromRect(panel.frame))")
        onStateChanged?(newState)

        switch newState {
        case .expanded:
            panel.setFrame(layout.expandedFrame, display: true)
            container.frame = CGRect(origin: .zero, size: layout.expandedFrame.size)
            hosting.frame = container.bounds
            if animated {
                withAnimation(.snappy(duration: expandAnimation, extraBounce: 0.06)) {
                    presentation.isExpanded = true
                }
            } else {
                presentation.isExpanded = true
            }
        case .collapsed:
            if animated {
                withAnimation(.easeIn(duration: collapseAnimation)) {
                    presentation.isExpanded = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + collapseAnimation) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.transitionGeneration == generation, self.state == .collapsed else { return }
                        self.panel.setFrame(self.layout.collapsedFrame, display: true)
                        self.container.frame = CGRect(origin: .zero, size: self.layout.collapsedFrame.size)
                        self.hosting.frame = self.container.bounds
                    }
                }
            } else {
                presentation.isExpanded = false
                panel.setFrame(layout.collapsedFrame, display: true)
                container.frame = CGRect(origin: .zero, size: layout.collapsedFrame.size)
                hosting.frame = container.bounds
            }
        }
    }

    // MARK: - 交互

    /// 点击灵动岛：未展开→展开并固定；已展开→切换固定状态。
    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            self.handleClick()
            return nil // 自己消化掉，不再往下传
        }
    }

    private func handleClick() {
        Trace.log("click mouse=\(NSEvent.mouseLocation) state=\(state) pinned=\(presentation.isPinned)")
        if state == .collapsed {
            presentation.isPinned = true
            apply(state: .expanded, animated: true)
        } else {
            presentation.isPinned.toggle()
            if !presentation.isPinned, !layout.keepsExpanded(point: NSEvent.mouseLocation) {
                scheduleCollapse()
            }
        }
    }

    /// 关闭轮询定时器本身（不只是跳过判定），用于开销归因
    func setPollingEnabled(_ enabled: Bool) {
        hoverEnabled = enabled
        if enabled {
            startPolling()
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
            cancelPendingExpand()
            cancelPendingCollapse()
        }
    }

    /// 面板按钮用：立刻收起（忽略固定状态）
    func collapseNow() {
        presentation.isPinned = false
        apply(state: .collapsed, animated: true)
    }

    /// 从菜单栏触发的展开：固定住，否则鼠标不在刘海上会立刻又收起
    func expandPinned() {
        presentation.isPinned = true
        apply(state: .expanded, animated: true)
    }

    // MARK: - 屏幕变化

    @objc private func screenParametersChanged() {
        rebuildLayout()
    }

    /// 重新计算屏幕几何并应用当前状态的 frame。
    func rebuildLayout() {
        guard let geometry = ScreenGeometry.resolve(previous: layout.geometry) else { return }
        var newLayout = layout
        newLayout.geometry = geometry
        layout = newLayout
        presentation.layout = newLayout
        switch state {
        case .collapsed:
            panel.setFrame(newLayout.collapsedFrame, display: true)
            container.frame = CGRect(origin: .zero, size: newLayout.collapsedFrame.size)
        case .expanded:
            panel.setFrame(newLayout.expandedFrame, display: true)
            container.frame = CGRect(origin: .zero, size: newLayout.expandedFrame.size)
        }
        hosting.frame = container.bounds
    }

    /// 供 `--selftest` 使用：不依赖鼠标即可驱动状态机
    func forceState(_ newState: State, animated: Bool) {
        apply(state: newState, animated: animated)
    }

    var windowFrame: CGRect { panel.frame }
    var windowLevel: Int { panel.level.rawValue }
    var isWindowVisible: Bool { panel.isVisible }

    /// 把面板内容离屏渲染成位图。用于 `--selftest` 做真实绘制验证
    /// （不需要屏幕录制权限，因为是进程内把视图层级画进位图）。
    func renderContentBitmap() -> NSBitmapImageRep? {
        let bounds = container.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = container.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        container.cacheDisplay(in: bounds, to: rep)
        return rep
    }
}
