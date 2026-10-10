import AppKit
import LiteStatsCore

/// 菜单栏图标的占位实现：只负责"能退出、能改刷新率、能看到自身开销"，
/// 不显示任何指标文本（用户要的是极简，指标都在灵动岛里）。
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let service: MonitorService
    private let prefs: Preferences
    private weak var panelController: NotchPanelController?

    private let onOpenSettings: () -> Void

    init(service: MonitorService, prefs: Preferences, panelController: NotchPanelController,
         onOpenSettings: @escaping () -> Void) {
        self.service = service
        self.prefs = prefs
        self.panelController = panelController
        self.onOpenSettings = onOpenSettings
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
        // 只保留「设置」与「退出」——其余（展开/收起、采样间隔、自身开销）都在设置界面里，
        // 菜单越短越不打扰。
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

    private static func intervalTitle(_ value: Double) -> String {
        value < 1 ? String(format: "%.1f 秒", value) : "\(Int(value)) 秒"
    }

    // MARK: - Actions

}
