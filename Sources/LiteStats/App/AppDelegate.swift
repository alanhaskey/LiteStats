import AppKit
import LiteStatsCore

/// 应用装配。注意：本 App 无主窗口、无 Dock 图标（`.accessory` + `LSUIElement`）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var prefs: Preferences?
    private var service: MonitorService?
    private var panelController: NotchPanelController?
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var historyWindow: HistoryWindowController?
    private var historyStore: HistoryStore?
    private var historyRecorder: HistoryRecorder?

    /// 默认布局（尺寸取自 Theme，保证窗口 frame 与 SwiftUI 内容一致）
    static func standardLayout(geometry: ScreenGeometry,
                               preferences: Preferences? = nil) -> PanelLayout {
        var layout = PanelLayout(geometry: geometry)
        layout.panelWidth = Theme.panelWidth
        layout.bodyHeight = Theme.bodyHeight
        layout.cornerRadius = Theme.cornerRadius
        if let preferences {
            layout.earWidth = CGFloat(preferences.earWidth)
            layout.leftEarActive = preferences.leftIndicator.needsEar
            layout.rightEarActive = preferences.rightIndicator.needsEar
        }
        return layout
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Trace.enableIfRequested()

        guard let geometry = ScreenGeometry.resolve() else {
            FileHandle.standardError.write(Data("LiteStats: 找不到可用屏幕，退出\n".utf8))
            NSApp.terminate(nil)
            return
        }

        let prefs = Preferences()
        self.prefs = prefs

        let service = MonitorService()
        applySamplingIntervals(prefs: prefs, service: service)
        self.service = service

        let controller = NotchPanelController(
            layout: Self.standardLayout(geometry: geometry, preferences: prefs), service: service)
        controller.onStateChanged = { [weak service] state in
            service?.isPanelExpanded = (state == .expanded)
            service?.thermalIsVisible = Self.thermalIsVisible(state: state, prefs: prefs)
        }
        controller.applyIndicators(left: prefs.leftIndicator, right: prefs.rightIndicator)
        self.panelController = controller

        // 历史统计（本地存储；目录不可写时静默降级，不影响监控本身）
        startHistory()


        // 常驻指示条走回调（纯 AppKit 绘制），不经过 SwiftUI 的 @Observable 刷新
        service.onSnapshot = { [weak controller, weak self] snapshot in
            controller?.updateIndicator(snapshot)
            self?.historyRecorder?.record(snapshot: snapshot, interval: service.interval)
        }
        // 初始：没人看温度就先按低频刷新
        service.thermalIsVisible = Self.thermalIsVisible(state: .collapsed, prefs: prefs)
        // 设置界面里改任何一项都即时生效
        prefs.onChange = { [weak self] in self?.applyPreferences() }

        controller.start()
        service.start()

        if prefs.showMenuBarItem {
            statusItem = StatusItemController(service: service, prefs: prefs,
                                              panelController: controller,
                                              onOpenSettings: { [weak self] in self?.showSettings() },
                                              onOpenHistory: { [weak self] in self?.showHistory() })
        }

        NSLog("LiteStats 已启动：刘海=%@ 屏幕=%@ 指示条(左=%@ 右=%@) 耳长=%.0fpt",
              NSStringFromRect(geometry.notchRect ?? .zero), NSStringFromRect(geometry.screenFrame),
              prefs.leftIndicator.rawValue, prefs.rightIndicator.rawValue, prefs.earWidth)

        if Trace.isEnabled {
            // 给端到端测试用的 CG 坐标（左上原点）：刘海中心
            let appKitY = geometry.screenTop - geometry.menuBarHeight / 2
            Trace.log(String(format: "notchCenterCG %.1f %.1f", geometry.anchorX,
                             geometry.screenFrame.maxY - appKitY))
        }

        if let seconds = SelfBenchmark.requestedSeconds() {
            SelfBenchmark.run(totalSeconds: seconds, service: service, controller: controller)
        }
    }

    /// 只有在"面板展开"或"指示条真的显示温度/风扇"时才按高频刷新温度
    /// （Apple Silicon 读温度是 ~0.75ms/传感器的同步 IPC，很贵）
    private static func thermalIsVisible(state: NotchPanelController.State, prefs: Preferences) -> Bool {
        if state == .expanded { return true }
        return prefs.leftIndicator == .temperature || prefs.leftIndicator == .fan
            || prefs.rightIndicator == .temperature || prefs.rightIndicator == .fan
    }

    /// 设置项变化：重算布局 + 采样间隔 + 菜单栏图标
    private func applyPreferences() {
        guard let prefs, let service, let controller = panelController else { return }
        var layout = controller.layout
        layout.earWidth = CGFloat(prefs.earWidth)
        layout.leftEarActive = prefs.leftIndicator.needsEar
        layout.rightEarActive = prefs.rightIndicator.needsEar
        controller.applyLayout(layout)
        controller.applyIndicators(left: prefs.leftIndicator, right: prefs.rightIndicator)
        applySamplingIntervals(prefs: prefs, service: service)
        service.thermalIsVisible = Self.thermalIsVisible(state: controller.state, prefs: prefs)
        updateStatusItemVisibility()
    }

    /// 收起态如果有人看指示条，刷新就得跟手一点（默认 2s → 1s）
    private func applySamplingIntervals(prefs: Preferences, service: MonitorService) {
        let collapsed = prefs.hasIndicators ? min(prefs.collapsedInterval, 1.0) : prefs.collapsedInterval
        service.setIntervals(expanded: prefs.expandedInterval, collapsed: collapsed)
    }

    private func updateStatusItemVisibility() {
        guard let prefs, let service, let controller = panelController else { return }
        if prefs.showMenuBarItem, statusItem == nil {
            statusItem = StatusItemController(service: service, prefs: prefs,
                                              panelController: controller,
                                              onOpenSettings: { [weak self] in self?.showSettings() },
                                              onOpenHistory: { [weak self] in self?.showHistory() })
        } else if !prefs.showMenuBarItem {
            statusItem?.remove()
            statusItem = nil
        }
    }

    private func showSettings() {
        guard let prefs, let service else { return }
        if let existing = settingsWindow {
            existing.present()
            return
        }
        let controller = SettingsWindowController(preferences: prefs, service: service,
                                                  onOpenHistory: { [weak self] in self?.showHistory() })
        controller.onClose = { [weak self] in
            // 关闭即释放 SwiftUI 图，回到低常驻内存
            self?.settingsWindow = nil
        }
        settingsWindow = controller
        controller.present()
    }

    // MARK: - 历史统计

    private func startHistory() {
        do {
            // 允许用环境变量指定存储目录（测试/沙箱环境用；正常运行时走默认的
            // ~/Library/Application Support/LiteStats）
            let override = ProcessInfo.processInfo.environment["LITESTATS_HISTORY_DIR"]
                .map { URL(fileURLWithPath: $0) }
            let store = try HistoryStore(directory: override)
            let recorder = HistoryRecorder(store: store)
            recorder.start()
            historyStore = store
            historyRecorder = recorder
            NSLog("LiteStats 历史统计已启用：%@", store.storagePath)
        } catch {
            NSLog("LiteStats 历史统计不可用（不影响监控）：%@", String(describing: error))
        }
    }

    private func showHistory() {
        guard let store = historyStore else {
            let alert = NSAlert()
            alert.messageText = "历史统计不可用"
            alert.informativeText = "无法创建本地存储目录。"
            alert.runModal()
            return
        }
        if let existing = historyWindow {
            existing.present()
            return
        }
        let controller = HistoryWindowController(store: store)
        controller.onClose = { [weak self] in self?.historyWindow = nil }
        historyWindow = controller
        controller.present()
    }

    func applicationWillTerminate(_ notification: Notification) {
        historyRecorder?.stop()
        service?.stop()
        panelController?.stop()
    }
}
