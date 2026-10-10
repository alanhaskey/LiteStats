import AppKit
import LiteStatsCore

/// 菜单栏图标的占位实现：只负责"能退出、能改刷新率、能看到自身开销"，
/// 不显示任何指标文本（用户要的是极简，指标都在灵动岛里）。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let service: MonitorService
    private let prefs: Preferences
    private weak var panelController: NotchPanelController?

    private let toggleItem = NSMenuItem(title: "展开面板", action: nil, keyEquivalent: "")
    private let statsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let intervalItems: [NSMenuItem]
    private let onOpenSettings: () -> Void

    private static let intervalChoices: [Double] = [0.5, 1, 2, 5]

    init(service: MonitorService, prefs: Preferences, panelController: NotchPanelController,
         onOpenSettings: @escaping () -> Void) {
        self.service = service
        self.prefs = prefs
        self.panelController = panelController
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.intervalItems = Self.intervalChoices.map { value in
            NSMenuItem(title: Self.intervalTitle(value), action: nil, keyEquivalent: "")
        }
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                   accessibilityDescription: "LiteStats")
            button.image?.isTemplate = true
            button.toolTip = "LiteStats — 悬浮刘海查看系统状态"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        buildMenu(menu)
    }

    /// 设置里关掉"菜单栏图标"时调用
    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func buildMenu(_ menu: NSMenu) {
        toggleItem.target = self
        toggleItem.action = #selector(togglePanel)
        menu.addItem(toggleItem)

        statsItem.isEnabled = false
        menu.addItem(statsItem)

        menu.addItem(.separator())

        let intervalMenu = NSMenu()
        for (index, item) in intervalItems.enumerated() {
            item.target = self
            item.action = #selector(changeInterval(_:))
            item.tag = index
            intervalMenu.addItem(item)
        }
        let intervalRoot = NSMenuItem(title: "采样间隔", action: nil, keyEquivalent: "")
        intervalRoot.submenu = intervalMenu
        menu.addItem(intervalRoot)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "退出 LiteStats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    private static func intervalTitle(_ value: Double) -> String {
        value < 1 ? String(format: "%.1f 秒", value) : "\(Int(value)) 秒"
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        let expanded = panelController?.state == .expanded
        toggleItem.title = expanded ? "收起面板" : "展开面板"
        statsItem.title = String(format: "采样耗时 %.2f ms · 已采样 %d 次",
                                 service.lastSampleMillis, service.sampleCount)
        for (index, item) in intervalItems.enumerated() {
            let selected = abs(Self.intervalChoices[index] - prefs.expandedInterval) < 0.001
            item.state = selected ? .on : .off
        }
    }

    // MARK: - Actions

    @objc private func togglePanel() {
        guard let controller = panelController else { return }
        if controller.state == .expanded {
            controller.collapseNow()
        } else {
            controller.expandPinned()
        }
    }

    @objc private func changeInterval(_ sender: NSMenuItem) {
        let value = Self.intervalChoices[max(0, min(sender.tag, Self.intervalChoices.count - 1))]
        prefs.expandedInterval = value
        // 收起态跟着放慢一档，保持"越安静越省电"
        prefs.collapsedInterval = max(value, min(value * 2, 10))
        service.setIntervals(expanded: prefs.expandedInterval, collapsed: prefs.collapsedInterval)
    }
}
