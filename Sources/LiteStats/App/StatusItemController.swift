import AppKit
import LiteStatsCore

/// 菜单栏图标的占位实现：只负责"能退出、能改刷新率、能看到自身开销"，
/// 不显示任何指标文本（用户要的是极简，指标都在灵动岛里）。
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let service: MonitorService
    private let prefs: Preferences

    private let onOpenSettings: () -> Void
    private let onOpenHistory: () -> Void

    init(service: MonitorService, prefs: Preferences,
         onOpenSettings: @escaping () -> Void, onOpenHistory: @escaping () -> Void) {
        self.service = service
        self.prefs = prefs
        self.onOpenSettings = onOpenSettings
        self.onOpenHistory = onOpenHistory
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                   accessibilityDescription: "LiteStats")
            button.image?.isTemplate = true
            button.toolTip = "LiteStats — 悬浮刘海查看系统状态"
        }

        let menu = NSMenu()
        statusItem.menu = menu
        buildMenu(menu)
    }

    /// 设置里关掉"菜单栏图标"时调用
    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func buildMenu(_ menu: NSMenu) {
        // 菜单保持极简：历史统计 / 设置 / 退出，其余都收在设置界面里。
        let history = NSMenuItem(title: "历史统计", action: #selector(openHistory), keyEquivalent: "h")
        history.target = self
        menu.addItem(history)

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 LiteStats",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func openHistory() {
        onOpenHistory()
    }

    private static func intervalTitle(_ value: Double) -> String {
        value < 1 ? String(format: "%.1f 秒", value) : "\(Int(value)) 秒"
    }

    // MARK: - Actions

}
