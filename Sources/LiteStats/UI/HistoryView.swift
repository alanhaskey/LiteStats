import LiteStatsCore
import SwiftUI

/// 历史统计窗口的内容。
///
/// 数据来自 `HistoryStore`（本地文件），范围由顶部选择器决定。
/// 图表用单个 `Canvas` 画完，避免大量视图带来的重绘开销。
struct HistoryView: View {
    let store: HistoryStore

    @State private var range: HistoryRange = .today
    @State private var chartMetric: HistoryMetric = .cpu
    @State private var appMetric: HistoryMetric = .network
    @State private var summary: UsageSummary?
    @State private var showResetConfirm = false
    @State private var resetNote: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            summaryCards
            chartSection
            appSection
            footer
        }
        .padding(18)
        .frame(width: 560, height: 640, alignment: .topLeading)
        // 显式底色：`.secondary` 这类语义色要靠背景做 vibrancy 混合，
        // 没有底色时（包括离屏渲染）会直接画不出来。
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: range) { reload() }
        .onAppear { reload() }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack {
            Text("历史统计")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Picker("", selection: $range) {
                ForEach(HistoryRange.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
        }
    }

    // MARK: - 汇总卡片

    private var summaryCards: some View {
        let s = summary
        return HStack(spacing: 10) {
            card("网络下载", Fmt.bytes(s?.networkIn ?? 0), .blue)
            card("网络上行", Fmt.bytes(s?.networkOut ?? 0), .orange)
            card("CPU 累计", cpuText(s), .green)
            card("内存均值", memText(s), .purple)
        }
    }

    private func cpuText(_ s: UsageSummary?) -> String {
        guard let s, s.cpuSeconds > 0 else { return "—" }
        let hours = s.cpuSeconds / 3600
        return String(format: "%.1f 核·时", hours)
    }

    private func memText(_ s: UsageSummary?) -> String {
        guard let s, s.memoryBytesAverage > 0 else { return "—" }
        return Fmt.bytes(s.memoryBytesAverage)
    }

    private func card(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.subtleLabel)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    // MARK: - 时段图

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(range == .today || range == .yesterday ? "各时段负载" : "每天负载")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("", selection: $chartMetric) {
                    ForEach(HistoryMetric.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            Canvas { context, size in
                drawChart(context: context, size: size)
            }
            .frame(height: 128)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
            if let peak = peakBucket {
                Text("峰值：\(peakLabel(peak)) · \(peakValueText(peak))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.subtleLabel)
            }
        }
    }

    private struct Bucket {
        var label: String
        var date: Date
        var value: Double      // 0...1 归一化后用于画图
        var rawText: String
        var isPeak: Bool
    }

    private var buckets: [Bucket] {
        guard let s = summary else { return [] }
        let byHour = range == .today || range == .yesterday
        var groups: [Date: (Double, String)] = [:]
        let calendar = Calendar.current
        for hour in s.hourly {
            let key: Date = byHour
                ? calendar.date(bySettingHour: calendar.component(.hour, from: hour.hourStart),
                                minute: 0, second: 0, of: hour.hourStart) ?? hour.hourStart
                : calendar.startOfDay(for: hour.hourStart)
            var value: Double
            var text: String
            switch chartMetric {
            case .cpu:
                value = hour.cpuPercentOfHour
                text = Fmt.percent(hour.cpuPercentOfHour, decimals: 0)
            case .network:
                value = Double(hour.networkIn + hour.networkOut)
                text = Fmt.bytes(hour.networkIn + hour.networkOut)
            case .memory:
                value = hour.memoryBytesAverage
                text = Fmt.bytes(hour.memoryBytesAverage)
            }
            let existing = groups[key]
            groups[key] = ((existing?.0 ?? 0) + value, text)
        }
        let sorted = groups.sorted { $0.key < $1.key }
        guard let maxValue = sorted.map(\.value.0).max(), maxValue > 0 else { return [] }
        let peakKey = sorted.max { $0.value.0 < $1.value.0 }?.key
        return sorted.map { key, pair in
            Bucket(label: byHour
                   ? String(format: "%02d", calendar.component(.hour, from: key))
                   : "\(calendar.component(.day, from: key))",
                   date: key,
                   value: min(1, pair.0 / maxValue),
                   rawText: pair.1,
                   isPeak: key == peakKey)
        }
    }

    private var peakBucket: Bucket? { buckets.first { $0.isPeak } }

    private func peakLabel(_ bucket: Bucket) -> String {
        if range == .today || range == .yesterday {
            return "\(bucket.label):00 时段"
        }
        return "\(Calendar.current.component(.month, from: bucket.date))月\(bucket.label)日"
    }

    private func peakValueText(_ bucket: Bucket) -> String { bucket.rawText }

    private func drawChart(context: GraphicsContext, size: CGSize) {
        let items = buckets
        guard !items.isEmpty, size.width > 10 else {
            context.draw(Text("这段时间还没有记录").font(.system(size: 11)).foregroundStyle(Theme.subtleLabel),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let inset: CGFloat = 14
        let chartHeight = size.height - inset * 2
        let slot = (size.width - inset * 2) / CGFloat(items.count)
        let barWidth = max(2, slot * 0.62)

        for (index, item) in items.enumerated() {
            let x = inset + slot * CGFloat(index) + (slot - barWidth) / 2
            let height = max(1, chartHeight * CGFloat(item.value))
            let rect = CGRect(x: x, y: size.height - inset - height, width: barWidth, height: height)
            let color: Color = item.isPeak ? chartMetric.peakColor : chartMetric.color
            context.fill(Path(roundedRect: rect, cornerRadius: min(3, barWidth / 2)), with: .color(color))

            // 只给部分刻度标时间，避免拥挤
            let showLabel = items.count <= 12 || index % 4 == 0 || item.isPeak
            if showLabel {
                let text = context.resolve(Text(item.label)
                    .font(.system(size: 8))
                    .foregroundStyle(item.isPeak ? Color.primary : Color.secondary))
                context.draw(text, at: CGPoint(x: x + barWidth / 2, y: size.height - inset + 6), anchor: .top)
            }
        }
    }

    // MARK: - 应用排行

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("应用排行")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("", selection: $appMetric) {
                    ForEach(HistoryMetric.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            let apps = rankedApps
            if apps.isEmpty {
                Text("这段时间还没有按应用的记录（需要保持 App 运行一段时间）")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtleLabel)
                    .frame(height: 150, alignment: .top)
            } else {
                VStack(spacing: 3) {
                    ForEach(apps) { app in
                        appRow(app)
                    }
                }
                .frame(height: 150, alignment: .top)
            }
        }
    }

    private var rankedApps: [AppUsage] {
        guard let s = summary else { return [] }
        let sorted: [AppUsage]
        switch appMetric {
        case .cpu: sorted = s.apps.sorted { $0.cpuSeconds > $1.cpuSeconds }
        case .network: sorted = s.apps.sorted { ($0.networkIn + $0.networkOut) > ($1.networkIn + $1.networkOut) }
        case .memory: sorted = s.apps.sorted { $0.peakMemoryBytes > $1.peakMemoryBytes }
        }
        return Array(sorted.prefix(8))
    }

    private func appRow(_ app: AppUsage) -> some View {
        let value = appMetric.value(for: app)
        let maxValue = rankedApps.map { appMetric.value(for: $0) }.max() ?? 1
        let ratio = maxValue > 0 ? value / maxValue : 0
        return HStack(spacing: 8) {
            Text(app.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(appMetric.color)
                        .frame(width: max(2, geo.size.width * CGFloat(ratio)))
                }
            }
            .frame(height: 10)
            Text(appMetric.text(for: app))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(Theme.subtleLabel)
                .frame(width: 90, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("本地存储：\(store.storagePath)")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.subtleLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("占用 \(Fmt.bytes(store.storageBytes)) · 分钟明细保留 7 天，小时 180 天，天级永久")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.subtleLabel)
            }
            Spacer()
            if !resetNote.isEmpty {
                Text(resetNote)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.subtleLabel)
            }
            Button("清空数据") { showResetConfirm = true }
                .confirmationDialog("确定清空全部历史统计？", isPresented: $showResetConfirm) {
                    Button("清空", role: .destructive) {
                        do {
                            try store.resetAll()
                            resetNote = "已清空"
                            reload()
                        } catch {
                            resetNote = "清空失败：\(error.localizedDescription)"
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("会删除本地保存的网络流量、CPU/GPU/内存与应用占用记录，且无法恢复。")
                }
        }
    }

    // MARK: - 数据

    private func reload() {
        let now = Date()
        switch range {
        case .today: summary = store.today(now: now)
        case .yesterday:
            let start = Calendar.current.startOfDay(for: now.addingTimeInterval(-86400))
            let end = Calendar.current.startOfDay(for: now)
            summary = store.summary(from: start, to: end)
        case .week: summary = store.lastDays(7, now: now)
        case .month:
            let start = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now)) ?? now
            summary = store.summary(from: start, to: now)
        }
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case today, yesterday, week, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .week: return "近 7 天"
        case .month: return "本月"
        }
    }
}

enum HistoryMetric: String, CaseIterable, Identifiable {
    case cpu, network, memory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .network: return "网络"
        case .memory: return "内存"
        }
    }
    var color: Color {
        switch self {
        case .cpu: return Color(red: 0.29, green: 0.87, blue: 0.71)
        case .network: return Color(red: 0.38, green: 0.72, blue: 1.00)
        case .memory: return Color(red: 0.72, green: 0.58, blue: 1.00)
        }
    }
    var peakColor: Color { Color(red: 1.00, green: 0.62, blue: 0.30) }

    func value(for app: AppUsage) -> Double {
        switch self {
        case .cpu: return app.cpuSeconds
        case .network: return Double(app.networkIn + app.networkOut)
        case .memory: return Double(app.peakMemoryBytes)
        }
    }

    func text(for app: AppUsage) -> String {
        switch self {
        case .cpu: return String(format: "%.1f 核·秒", app.cpuSeconds)
        case .network: return Fmt.bytes(app.networkIn + app.networkOut)
        case .memory: return Fmt.bytes(app.peakMemoryBytes)
        }
    }
}
