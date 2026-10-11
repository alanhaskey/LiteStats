import AppKit
import LiteStatsCore
import SwiftUI

/// 历史统计窗口。和设置窗口一样：只在打开时存在，关闭即释放 SwiftUI 图。
@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(store: HistoryStore, initialSelection: HistorySelection = .today) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 748),
            styleMask: [.titled, .closable, .miniaturizable],   // 固定尺寸，不允许拖拽调整
            backing: .buffered,
            defer: false)
        window.title = "LiteStats 历史统计"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        window.delegate = self
        let host = NSHostingView(rootView: HistoryView(store: store, initialSelection: initialSelection))
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
