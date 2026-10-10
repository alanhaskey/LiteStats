import AppKit
import SwiftUI

/// 设置窗口。SwiftUI 只在这个窗口存在时才有渲染开销，
/// 关闭时把 hosting view 一起释放掉，回到"常驻 10 MB"的状态。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let preferences: Preferences
    private let service: MonitorService

    /// 关闭时回调（AppDelegate 用它把引用置空，释放 SwiftUI 图）
    var onClose: (() -> Void)?

    init(preferences: Preferences, service: MonitorService, onOpenHistory: @escaping () -> Void) {
        self.preferences = preferences
        self.service = service

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "LiteStats 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        window.delegate = self
        let host = NSHostingView(rootView: SettingsView(preferences: preferences,
                                                        service: service,
                                                        onOpenHistory: onOpenHistory))
        host.sizingOptions = []
        host.frame = window.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持 nib") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
