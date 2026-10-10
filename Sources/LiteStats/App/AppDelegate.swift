import AppKit
import LiteStatsCore

/// 应用装配。注意：本 App 无主窗口、无 Dock 图标（`.accessory` + `LSUIElement`）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var prefs: Preferences?
    private var service: MonitorService?
    private var panelController: NotchPanelController?
    private var statusItem: StatusItemController?

    /// 默认布局（尺寸取自 Theme，保证窗口 frame 与 SwiftUI 内容一致）
    static func standardLayout(geometry: ScreenGeometry) -> PanelLayout {
        var layout = PanelLayout(geometry: geometry)
        layout.panelWidth = Theme.panelWidth
        layout.bodyHeight = Theme.bodyHeight
        layout.cornerRadius = Theme.cornerRadius
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
        service.setIntervals(expanded: prefs.expandedInterval, collapsed: prefs.collapsedInterval)
        self.service = service

        let controller = NotchPanelController(layout: Self.standardLayout(geometry: geometry), service: service)
        controller.onStateChanged = { [weak service] state in
            service?.isPanelExpanded = (state == .expanded)
        }
        self.panelController = controller
        controller.start()
        service.start()

        if prefs.showMenuBarItem {
            statusItem = StatusItemController(service: service, prefs: prefs, panelController: controller)
        }

        NSLog("LiteStats 已启动：刘海=%@ 屏幕=%@", NSStringFromRect(geometry.notchRect ?? .zero),
              NSStringFromRect(geometry.screenFrame))

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

    func applicationWillTerminate(_ notification: Notification) {
        service?.stop()
        panelController?.stop()
    }
}
