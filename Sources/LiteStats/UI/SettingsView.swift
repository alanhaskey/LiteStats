import AppKit
import LiteStatsCore
import SwiftUI

/// 设置界面。只在窗口打开时存在，关闭即释放（不影响常驻开销）。
struct SettingsView: View {
    @Bindable var preferences: Preferences
    let service: MonitorService
    /// 打开历史统计窗口（由 AppDelegate 提供）
    let onOpenHistory: () -> Void

    @State private var launchNote: String = ""
    @State private var costText: String = "测量中…"
    @State private var lastCPU: Double = 0
    @State private var lastSampleTime = Date()

    private let costTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let expandedChoices: [Double] = [0.5, 1, 2, 5]
    private let collapsedChoices: [Double] = [1, 2, 5, 10]

    var body: some View {
        Form {
            indicatorSection
            samplingSection
            historySection
            generalSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        .onAppear {
            lastCPU = SelfBenchmark.cpuSecondsAndRSS().cpu
            lastSampleTime = Date()
            launchNote = LaunchAtLogin.isEnabled ? "当前已启用" : "当前未启用"
        }
        .onReceive(costTimer) { _ in updateCost() }
    }

    // MARK: - 常驻指示条

    private var indicatorSection: some View {
        Section("刘海常驻指示条") {
            Picker("左侧显示", selection: $preferences.leftIndicator) {
                ForEach(IndicatorMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            Picker("右侧显示", selection: $preferences.rightIndicator) {
                ForEach(IndicatorMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            HStack {
                Text("黑耳长度")
                Slider(value: $preferences.earWidth, in: 56...160, step: 4)
                Text("\(Int(preferences.earWidth)) pt")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
            Text("黑耳是刘海左右延伸出来的黑色区域。**两侧长度始终一致、与你选了什么指标无关**，"
                 + "指标数值在黑耳里居中显示 —— 换指标不会让耳朵忽长忽短。"
                 + "没选指标的那一侧完全不画黑耳（折叠、展开都不会多出耳朵）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("预览")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NotchPreview(left: preferences.leftIndicator,
                             right: preferences.rightIndicator,
                             earWidth: CGFloat(preferences.earWidth))
                    .frame(height: 30)
                Text("指示条画在刘海两侧的黑色区域里，不占用菜单栏；鼠标悬浮这一带同样会展开面板，"
                     + "每秒刷新（收起态采样间隔会自动收紧到 1s）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 采样

    private var samplingSection: some View {
        Section("采样") {
            Picker("展开时刷新", selection: $preferences.expandedInterval) {
                ForEach(expandedChoices, id: \.self) { value in
                    Text(intervalTitle(value)).tag(value)
                }
            }
            Picker("收起时刷新", selection: $preferences.collapsedInterval) {
                ForEach(collapsedChoices, id: \.self) { value in
                    Text(intervalTitle(value)).tag(value)
                }
            }
            Text("收起态刷新越慢越省电；CPU 占用大致等于「调用次数 × 单次采样 0.3–1 ms」。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func intervalTitle(_ value: Double) -> String {
        value < 1 ? String(format: "%.1f 秒", value) : "\(Int(value)) 秒"
    }

    // MARK: - 通用

    private var generalSection: some View {
        Section("通用") {
            Toggle("在菜单栏显示图标", isOn: $preferences.showMenuBarItem)
            Toggle("开机自动启动", isOn: $preferences.launchAtLogin)
                .onChange(of: preferences.launchAtLogin) { _, newValue in
                    launchNote = LaunchAtLogin.set(enabled: newValue)
                }
            if !launchNote.isEmpty {
                Text(launchNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("隐藏菜单栏图标后，只能从「活动监视器」或终端 pkill -f LiteStats 退出。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 历史统计

    private var historySection: some View {
        Section("历史统计") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("记录网络流量、CPU/GPU/内存与应用占用")
                        .font(.system(size: 12))
                    Text("本地保存（分钟明细 7 天、小时 180 天、天级永久），可随时清空。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("打开历史统计…") { onOpenHistory() }
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: Self.version)
            LabeledContent("本 App 开销", value: costText)
            LabeledContent("刘海几何", value: geometryDescription)
            HStack {
                Button("退出 LiteStats") { NSApp.terminate(nil) }
                Spacer()
            }
        }
    }

    private static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        return "LiteStats \(short)"
    }

    private var geometryDescription: String {
        guard let geometry = ScreenGeometry.resolve() else { return "未知" }
        if let notch = geometry.notchRect {
            return String(format: "刘海 %.0f×%.0f pt，菜单栏 %.0f pt", notch.width, notch.height, geometry.menuBarHeight)
        }
        return String(format: "无刘海（回退模式），菜单栏 %.0f pt", geometry.menuBarHeight)
    }

    private func updateCost() {
        let usage = SelfBenchmark.cpuSecondsAndRSS()
        let now = Date()
        let wall = now.timeIntervalSince(lastSampleTime)
        let cpuDelta = max(0, usage.cpu - lastCPU)
        lastCPU = usage.cpu
        lastSampleTime = now
        let percent = wall > 0 ? cpuDelta / wall * 100 : 0
        costText = String(format: "%.2f%% CPU · %.1f MB 物理占用",
                          percent, Double(SelfBenchmark.physicalFootprint()) / 1_048_576)
    }
}

/// 刘海两侧指示条的示意图（用真实刘海宽度按比例画，两侧黑耳等长、内容居中）
private struct NotchPreview: View {
    let left: IndicatorMetric
    let right: IndicatorMetric
    let earWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let notchWidth = ScreenGeometry.resolve()?.notchRect?.width ?? 220
            let leftEar: CGFloat = left.needsEar ? earWidth : 0
            let rightEar: CGFloat = right.needsEar ? earWidth : 0
            let total = notchWidth + leftEar + rightEar
            let scale = min(1, geo.size.width / max(total, 1))

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                HStack(spacing: 0) {
                    earView(metric: left, width: leftEar * scale, isLeft: true)
                    Rectangle()
                        .fill(.black)
                        .frame(width: notchWidth * scale)
                    earView(metric: right, width: rightEar * scale, isLeft: false)
                }
            }
        }
    }

    @ViewBuilder
    private func earView(metric: IndicatorMetric, width: CGFloat, isLeft: Bool) -> some View {
        ZStack {
            UnevenRoundedRectangle(
                bottomLeadingRadius: isLeft ? 5 : 0,
                bottomTrailingRadius: isLeft ? 0 : 5,
                style: .continuous)
                .fill(.black)
            if width > 20 {
                Text(shortLabel(metric))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(width: max(0, width))
    }

    private func shortLabel(_ metric: IndicatorMetric) -> String {
        switch metric {
        case .none: return ""
        case .cpu: return "CPU"
        case .memory: return "MEM"
        case .gpu: return "GPU"
        case .network: return "↓↑"
        case .disk: return "DSK"
        case .temperature: return "℃"
        case .fan: return "FAN"
        }
    }
}
