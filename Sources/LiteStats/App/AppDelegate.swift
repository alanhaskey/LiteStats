import AppKit
import LiteStatsCore

/// 应用装配。注意：本 App 无主窗口、无 Dock 图标（`.accessory` + `LSUIElement`）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var prefs: Preferences?
    private var service: MonitorService?
    /// 每块被选中的屏幕一个面板（多屏可"全部显示"）
    private var panels: [UInt32: NotchPanelController] = [:]
    /// 当前处于展开状态的面板所在屏幕（用来决定采样频率）
    private var expandedDisplays: Set<UInt32> = []
    private var screenObserver: NSObjectProtocol?
    /// 历史统计初始化失败的原因（点"历史统计"时展示真实原因，而不是笼统说目录不行）
    private var historyError: Error?
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

        guard let primary = ScreenGeometry.resolve() else {
            FileHandle.standardError.write(Data("LiteStats: 找不到可用屏幕，退出\n".utf8))
            NSApp.terminate(nil)
            return
        }

        let prefs = Preferences()
        self.prefs = prefs

        let service = MonitorService()
        applySamplingIntervals(prefs: prefs, service: service)
        self.service = service

        rebuildPanels()

        // 常驻指示条走回调（纯 AppKit 绘制），不经过 SwiftUI 的 @Observable 刷新
        service.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            for panel in self.panels.values { panel.updateIndicator(snapshot) }
            self.historyRecorder?.record(snapshot: snapshot, interval: service.interval)
        }
        // 设置界面里改任何一项都即时生效
        prefs.onChange = { [weak self] in self?.applyPreferences() }
        // 屏幕增删/换位置：重建全部面板
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuildPanels() }
            }

        service.start()

        // 历史统计（本地存储；目录不可写时降级，不影响监控本身）
        // ⚠️ 这行曾在多屏重构时被误删，导致"历史统计不可用"——e2e 现在会断言 trace 里有 history 行
        startHistory()

        if prefs.showMenuBarItem {
            statusItem = StatusItemController(service: service, prefs: prefs,
                                              onOpenSettings: { [weak self] in self?.showSettings() },
                                              onOpenHistory: { [weak self] in self?.showHistory() })
        }

        NSLog("LiteStats 已启动：面板数=%d 显示模式=%@ 缺口=%@（%@）指示条(左=%@ 右=%@)",
              panels.count, prefs.displayMode.rawValue,
              NSStringFromRect(primary.notchRect),
              primary.hasPhysicalNotch ? "物理刘海" : "合成缺口",
              prefs.leftIndicator.rawValue, prefs.rightIndicator.rawValue)

        if Trace.isEnabled {
            // 给端到端测试用的 CG 坐标（左上原点）：刘海中心
            // 每块面板各一行，方便端到端脚本驱动任意一块屏
            for panel in panels.values {
                let geometry = panel.layout.geometry
                let appKitY = geometry.screenTop - geometry.menuBarHeight / 2
                Trace.log(String(format: "notchCenterCG %.1f %.1f display=%u %@",
                                 geometry.anchorX, geometry.screenFrame.maxY - appKitY,
                                 geometry.displayID,
                                 geometry.hasPhysicalNotch ? "physical" : "synthetic"))
            }
        }

        if let seconds = SelfBenchmark.requestedSeconds(), let first = panels.values.first {
            SelfBenchmark.run(totalSeconds: seconds, service: service, controller: first)
        }
    }

    /// 只有在"面板展开"或"指示条真的显示温度/风扇"时才按高频刷新温度
    /// （Apple Silicon 读温度是 ~0.75ms/传感器的同步 IPC，很贵）
    private static func thermalIsVisible(state: NotchPanelController.State, prefs: Preferences) -> Bool {
        if state == .expanded { return true }
        return prefs.leftIndicator == .temperature || prefs.leftIndicator == .fan
            || prefs.rightIndicator == .temperature || prefs.rightIndicator == .fan
    }

    /// 设置项变化：重算布局 + 采样间隔 + 菜单栏图标 + 显隐目标屏幕
    private func applyPreferences() {
        guard let prefs, let service else { return }
        rebuildPanels()
        applySamplingIntervals(prefs: prefs, service: service)
        updateServiceFlags()
        updateStatusItemVisibility()
    }

    // MARK: - 面板与屏幕

    /// 按设置决定面板挂在哪块（或哪些）屏幕上，并同步已有面板。
    private func rebuildPanels() {
        guard let prefs, let service else { return }
        let geometries = targetGeometries(prefs: prefs)
        let wanted = Set(geometries.map(\.displayID))

        for (id, panel) in panels where !wanted.contains(id) {
            panel.stop()
            panels.removeValue(forKey: id)
            expandedDisplays.remove(id)
        }

        for geometry in geometries {
            let layout = Self.standardLayout(geometry: geometry, preferences: prefs)
            if let existing = panels[geometry.displayID] {
                existing.applyLayout(layout)
                existing.applyIndicators(left: prefs.leftIndicator, right: prefs.rightIndicator)
            } else {
                let panel = NotchPanelController(layout: layout, service: service)
                let displayID = geometry.displayID
                panel.onStateChanged = { [weak self] state in
                    MainActor.assumeIsolated { self?.panelStateChanged(displayID: displayID, state: state) }
                }
                panel.applyIndicators(left: prefs.leftIndicator, right: prefs.rightIndicator)
                panel.start()
                panel.updateIndicator(service.snapshot)
                panels[displayID] = panel
            }
        }
        updateServiceFlags()
    }

    private func panelStateChanged(displayID: UInt32, state: NotchPanelController.State) {
        if state == .expanded {
            expandedDisplays.insert(displayID)
        } else {
            expandedDisplays.remove(displayID)
        }
        updateServiceFlags()
    }

    /// 展开态 / 是否有人看温度，决定采样频率与温度刷新频率（任一面板展开即算）
    private func updateServiceFlags() {
        guard let service, let prefs else { return }
        let anyExpanded = !expandedDisplays.isEmpty
        service.isPanelExpanded = anyExpanded
        service.thermalIsVisible = anyExpanded || Self.thermalIsVisible(state: .collapsed, prefs: prefs)
    }

    /// 按设置挑出要挂面板的屏幕
    private func targetGeometries(prefs: Preferences) -> [ScreenGeometry] {
        let screens = NSScreen.screens
        let previous = panels.mapValues { $0.layout.geometry }
        func pick(_ screen: NSScreen) -> ScreenGeometry {
            ScreenGeometry.geometry(for: screen, previous: previous[ScreenGeometry.displayID(of: screen)])
        }

        switch prefs.displayMode {
        case .all:
            return ScreenGeometry.all(screens: screens, previous: previous)
        case .main:
            guard let main = NSScreen.main else { return [] }
            return [pick(main)]
        case .specific:
            let byID = screens.first { ScreenGeometry.displayID(of: $0) == prefs.specificDisplayID }
            let byName = prefs.specificDisplayName.isEmpty ? nil
                : screens.first { $0.localizedName == prefs.specificDisplayName }
            if let target = byID ?? byName { return [pick(target)] }
            // 指定的屏幕不在了：退回自动
            return ScreenGeometry.resolve(screens: screens, main: NSScreen.main,
                                          previous: panels.values.first?.layout.geometry).map { [$0] } ?? []
        case .automatic:
            return ScreenGeometry.resolve(screens: screens, main: NSScreen.main,
                                          previous: panels.values.first?.layout.geometry).map { [$0] } ?? []
        }
    }

    /// 收起态如果有人看指示条，刷新就得跟手一点（默认 2s → 1s）
    private func applySamplingIntervals(prefs: Preferences, service: MonitorService) {
        let collapsed = prefs.hasIndicators ? min(prefs.collapsedInterval, 1.0) : prefs.collapsedInterval
        service.setIntervals(expanded: prefs.expandedInterval, collapsed: collapsed)
    }

    private func updateStatusItemVisibility() {
        guard let prefs, let service else { return }
        if prefs.showMenuBarItem, statusItem == nil {
            statusItem = StatusItemController(service: service, prefs: prefs,
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
            historyError = nil
            NSLog("LiteStats 历史统计已启用：%@", store.storagePath)
            Trace.log("history enabled \(store.storagePath)")
        } catch {
            historyError = error
            NSLog("LiteStats 历史统计不可用（不影响监控）：%@", String(describing: error))
            Trace.log("history unavailable \(error)")
        }
    }

    private func showHistory() {
        // 没初始化成功就先再试一次（比如刚才目录暂时不可写）
        if historyStore == nil { startHistory() }

        guard let store = historyStore else {
            let alert = NSAlert()
            alert.messageText = "历史统计不可用"
            if let error = historyError {
                alert.informativeText = """
                创建本地存储目录失败：

                \(error.localizedDescription)

                路径：\(HistoryStore.defaultStoragePath)
                """
            } else {
                alert.informativeText = "本地存储尚未初始化。"
            }
            alert.addButton(withTitle: "重试")
            alert.addButton(withTitle: "关闭")
            if alert.runModal() == .alertFirstButtonReturn {
                showHistory()          // 重试一次（用户手动触发，不会自动循环）
            }
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
        for panel in panels.values { panel.stop() }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}
