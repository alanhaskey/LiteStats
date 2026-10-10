import LiteStatsCore
import SwiftUI

/// 历史统计窗口的内容。
///
/// 顶部是范围（今天 / 近 7 天 / 本月）+ **月历**：点日历里任意一天就切到那天的数据，
/// 日历格子按当前指标着色（越深越忙），可以直接看出哪几天用得多。
struct HistoryView: View {
    let store: HistoryStore

    @State private var selection: HistorySelection = .today
    @State private var displayMonth: Date = HistoryCalendar.startOfMonth(for: Date())
    @State private var chartMetric: HistoryMetric = .cpu
    @State private var appMetric: HistoryMetric = .network
    @State private var summary: UsageSummary?
    @State private var monthHeat: [Date: Double] = [:]
    @State private var showResetAlert = false
    @State private var resetNote = ""
    @State private var hoveredBucket: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            calendarCard
            summaryCards
            chartSection
            appSection
            footer
        }
        .padding(16)
        .frame(width: 640, height: 748, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: selection) { reloadSummary() }
        .task(id: HeatKey(month: displayMonth, metric: chartMetric)) { reloadMonthHeat() }
        .onAppear {
            reloadSummary()
            reloadMonthHeat()
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 12) {
            Text("历史统计")
                .font(.system(size: 15, weight: .semibold))
            if case .day(let date) = selection {
                Text(HistoryCalendar.dayTitle(date))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(chartMetric.color)
            }
            Spacer()
            Picker("", selection: $selection) {
                Text("今天").tag(HistorySelection.today)
                Text("近 7 天").tag(HistorySelection.last7Days)
                Text("本月").tag(HistorySelection.thisMonth)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
        }
    }

    // MARK: - 月历

    private var calendarCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    shiftMonth(-1)
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                Text(HistoryCalendar.monthTitle(displayMonth))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                Button {
                    shiftMonth(1)
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(HistoryCalendar.isCurrentMonth(displayMonth))
                Spacer()
                Text("格子深浅 = \(chartMetric.title)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.subtleLabel)
            }

            HStack(spacing: 0) {
                ForEach(HistoryCalendar.weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.subtleLabel)
                        .frame(maxWidth: .infinity)
                }
            }

            let weeks = HistoryCalendar.weeks(in: displayMonth)
            let peak = monthHeat.values.max() ?? 0
            VStack(spacing: 2) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 2) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            dayCell(day, peak: peak)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private func dayCell(_ day: Date?, peak: Double) -> some View {
        if let day {
            let heat = monthHeat[day] ?? 0
            let ratio = peak > 0 ? min(1, heat / peak) : 0
            let isSelected = selection == .day(day)
            let isToday = Calendar.current.isDateInToday(day)
            let isFuture = day > Date()

            Button {
                selection = .day(day)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(chartMetric.color.opacity(isFuture ? 0.02 : 0.06 + 0.55 * ratio))
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(isSelected ? chartMetric.color : Color.clear, lineWidth: 1.6)
                    Text("\(Calendar.current.component(.day, from: day))")
                        .font(.system(size: 10, weight: isToday ? .bold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isFuture ? Theme.subtleLabel : Color.primary)
                }
            }
            .buttonStyle(.plain)
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .help(heat > 0 ? "\(HistoryCalendar.dayTitle(day)) · \(chartMetric.format(heat))" : HistoryCalendar.dayTitle(day))
            .disabled(isFuture)
        } else {
            Color.clear.frame(height: 26).frame(maxWidth: .infinity)
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
        return String(format: "%.1f 核·时", s.cpuSeconds / 3600)
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
                Text(isSingleDay ? "各时段负载" : "每天负载")
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
            GeometryReader { geo in
                Canvas { context, size in
                    drawChart(context: context, size: size)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let inset: CGFloat = 14
                        let slot = max(1, (geo.size.width - inset * 2) / CGFloat(max(buckets.count, 1)))
                        let index = Int((point.x - inset) / slot)
                        hoveredBucket = (index >= 0 && index < buckets.count) ? index : nil
                    case .ended:
                        hoveredBucket = nil
                    }
                }
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
            if let peak = peakBucket {
                Text("峰值 \(peakLabel(peak)) · \(peak.rawText)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.subtleLabel)
            }
        }
    }

    private var isSingleDay: Bool {
        switch selection {
        case .today, .day: return true
        case .last7Days, .thisMonth: return false
        }
    }

    private struct Bucket {
        var label: String
        var date: Date
        var value: Double
        var rawText: String
        var isPeak: Bool
        var isEmpty: Bool = false
    }

    private var buckets: [Bucket] {
        guard let s = summary else { return [] }
        let calendar = Calendar.current

        if isSingleDay {
            // 单日固定 24 个时段（纯函数，便于单测）
            let slots = HistoryChartData.singleDaySlots(hourly: s.hourly, metric: chartMetric)
            var dayStart = calendar.startOfDay(for: Date())
            if let first = s.hourly.first {
                dayStart = calendar.startOfDay(for: first.hourStart)
            }
            return slots.map { slot in
                Bucket(label: String(format: "%02d", slot.hour),
                       date: calendar.date(byAdding: .hour, value: slot.hour, to: dayStart) ?? dayStart,
                       value: slot.normalized,
                       rawText: slot.text,
                       isPeak: slot.isPeak,
                       isEmpty: slot.isEmpty)
            }
        }

        // 多日：按天聚合
        var groups: [Date: (Double, String)] = [:]
        for hour in s.hourly {
            let key = calendar.startOfDay(for: hour.hourStart)
            let value = chartMetric.value(of: hour)
            groups[key] = ((groups[key]?.0 ?? 0) + value, chartMetric.formatBucket(value))
        }
        let sorted = groups.sorted { $0.key < $1.key }
        guard let maxValue = sorted.map(\.value.0).max(), maxValue > 0 else { return [] }
        let peakKey = sorted.max { $0.value.0 < $1.value.0 }?.key
        return sorted.map { key, pair in
            Bucket(label: "\(calendar.component(.day, from: key))",
                   date: key,
                   value: min(1, pair.0 / maxValue),
                   rawText: pair.1,
                   isPeak: key == peakKey)
        }
    }

    private var peakBucket: Bucket? { buckets.first { $0.isPeak } }

    private func hourLabel(_ label: String) -> String { "\(label):00" }

    private func peakLabel(_ bucket: Bucket) -> String {
        isSingleDay
            ? "\(bucket.label):00 时段"
            : "\(Calendar.current.component(.month, from: bucket.date)) 月 \(bucket.label) 日"
    }

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

        let hovered = hoveredBucket.flatMap { $0 < items.count ? $0 : nil }

        for (index, item) in items.enumerated() {
            let x = inset + slot * CGFloat(index) + (slot - barWidth) / 2
            let height = max(1.5, chartHeight * CGFloat(item.value))
            let rect = CGRect(x: x, y: size.height - inset - height, width: barWidth, height: height)
            let color: Color = item.isEmpty
                ? Color.primary.opacity(0.10)
                : (item.isPeak ? chartMetric.peakColor : chartMetric.color)
            context.fill(Path(roundedRect: rect, cornerRadius: min(3, barWidth / 2)), with: .color(color))

            // 悬停的时段：加一根竖向指示线，方便对准
            if index == hovered {
                var guide = Path()
                guide.move(to: CGPoint(x: x + barWidth / 2, y: inset * 0.6))
                guide.addLine(to: CGPoint(x: x + barWidth / 2, y: size.height - inset))
                context.stroke(guide, with: .color(chartMetric.color.opacity(0.5)), lineWidth: 1)
            }

            let showLabel = items.count <= 12 || index % 4 == 0 || item.isPeak
            if showLabel {
                let text = context.resolve(Text(item.label)
                    .font(.system(size: 8))
                    .foregroundStyle(item.isPeak ? Color.primary : Theme.subtleLabel))
                context.draw(text, at: CGPoint(x: x + barWidth / 2, y: size.height - inset + 6), anchor: .top)
            }
        }

        // 悬停气泡：显示"时刻 · 数值"
        if let hovered {
            let item = items[hovered]
            let centerX = inset + slot * CGFloat(hovered) + slot / 2
            let label = "\(hourLabel(item.label)) · \(item.rawText)"
            let text = context.resolve(Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white))
            let textSize = text.measure(in: CGSize(width: 300, height: 40))
            var bubbleX = centerX - textSize.width / 2 - 6
            bubbleX = min(max(2, bubbleX), max(2, size.width - textSize.width - 14))
            let bubble = CGRect(x: bubbleX, y: 2, width: textSize.width + 12, height: textSize.height + 8)
            context.fill(Path(roundedRect: bubble, cornerRadius: 6), with: .color(.black.opacity(0.78)))
            context.draw(text, at: CGPoint(x: bubble.midX, y: bubble.midY), anchor: .center)
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
                Text("这段时间还没有按应用的记录")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtleLabel)
                    .frame(height: 146, alignment: .top)
            } else {
                // 可滚动：应用多的时候不再溢出窗口
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 3) {
                        ForEach(apps) { app in
                            appRow(app)
                        }
                    }
                }
                .frame(height: 146)
            }
        }
    }

    private var rankedApps: [AppUsage] {
        guard let s = summary else { return [] }
        let sorted: [AppUsage]
        switch appMetric {
        case .cpu: sorted = s.apps.sorted { $0.cpuSeconds > $1.cpuSeconds }
        case .network: sorted = s.apps.sorted { $0.networkTotal > $1.networkTotal }
        case .memory: sorted = s.apps.sorted { $0.peakMemoryBytes > $1.peakMemoryBytes }
        }
        return Array(sorted.prefix(10))
    }

    private func appRow(_ app: AppUsage) -> some View {
        let value = appMetric.value(of: app)
        let maxValue = rankedApps.map { appMetric.value(of: $0) }.max() ?? 1
        let ratio = maxValue > 0 ? value / maxValue : 0
        return HStack(spacing: 8) {
            Text(app.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(appMetric.color)
                        .frame(width: max(2, geo.size.width * CGFloat(ratio)))
                }
            }
            .frame(height: 10)
            Text(appMetric.format(value))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(Theme.subtleLabel)
                .frame(width: 96, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Text("本地存储 \(Fmt.bytes(store.storageBytes))")
                .font(.system(size: 10))
                .foregroundStyle(Theme.subtleLabel)
                .lineLimit(1)
            Spacer()
            if !resetNote.isEmpty {
                Text(resetNote)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.subtleLabel)
            }
            Button("清空数据") { showResetAlert = true }
                .alert("确定清空全部历史统计？", isPresented: $showResetAlert) {
                    Button("清空", role: .destructive) { resetAll() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("会删除本地保存的网络流量、CPU/GPU/内存与应用占用记录，且无法恢复。")
                }
        }
    }

    private func resetAll() {
        do {
            try store.resetAll()
            resetNote = "已清空"
            reloadSummary()
            reloadMonthHeat()
        } catch {
            resetNote = "清空失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 数据

    private func shiftMonth(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: delta, to: displayMonth) else { return }
        displayMonth = HistoryCalendar.startOfMonth(for: next)
    }

    private func reloadSummary() {
        let now = Date()
        let calendar = Calendar.current
        switch selection {
        case .today:
            summary = store.today(now: now)
        case .last7Days:
            summary = store.lastDays(7, now: now)
        case .thisMonth:
            summary = store.summary(from: HistoryCalendar.startOfMonth(for: now), to: now)
        case .day(let date):
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            summary = store.summary(from: start, to: end)
        }
    }

    /// 日历热力：取当前显示月份的数据，按天聚合成一个数值
    private func reloadMonthHeat() {
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .month, value: 1, to: displayMonth) else { return }
        let monthSummary = store.summary(from: displayMonth, to: end)
        var heat: [Date: Double] = [:]
        for hour in monthSummary.hourly {
            let key = calendar.startOfDay(for: hour.hourStart)
            heat[key, default: 0] += chartMetric.value(of: hour)
        }
        monthHeat = heat
    }
}

/// 图表的纯计算部分（可单测）
enum HistoryChartData {
    struct HourSlot: Equatable {
        let hour: Int
        let rawValue: Double
        let text: String
        let normalized: Double       // 0...1，相对当天最大值
        let isPeak: Bool
        let isEmpty: Bool
    }

    /// 单日：**恒定返回 24 个槽位**（00…23）。没有记录的小时也占位（isEmpty = true），
    /// 这样柱子位置稳定、可以直接对着钟点看。
    static func singleDaySlots(hourly: [HourlyBucket], metric: HistoryMetric) -> [HourSlot] {
        let calendar = Calendar.current
        var byHour: [Int: Double] = [:]
        for bucket in hourly {
            let hour = calendar.component(.hour, from: bucket.hourStart)
            byHour[hour, default: 0] += metric.value(of: bucket)
        }
        let maxValue = byHour.values.max() ?? 0
        let peakHour = byHour.max { $0.value < $1.value }?.key
        return (0..<24).map { hour in
            let value = byHour[hour]
            return HourSlot(hour: hour,
                            rawValue: value ?? 0,
                            text: value.map { metric.formatBucket($0) } ?? "无记录",
                            normalized: (value != nil && maxValue > 0) ? min(1, (value ?? 0) / maxValue) : 0,
                            isPeak: value != nil && hour == peakHour && maxValue > 0,
                            isEmpty: value == nil)
        }
    }
}

/// `.task(id:)` 需要一个 Hashable 组合键
private struct HeatKey: Hashable {
    let month: Date
    let metric: HistoryMetric
}

enum HistorySelection: Hashable {
    case today
    case last7Days
    case thisMonth
    case day(Date)
}

/// 日历的纯计算部分（周一起始的 6×7 月网格）
enum HistoryCalendar {
    /// 周一为一周起点。用只读常量而不是 var：Swift 6 下可变全局状态不可并发安全。
    static let calendar: Calendar = {
        var c = Calendar.current
        c.firstWeekday = 2      // 周一
        return c
    }()

    static let weekdaySymbols = ["一", "二", "三", "四", "五", "六", "日"]

    static func startOfMonth(for date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    static func isCurrentMonth(_ month: Date) -> Bool {
        calendar.isDate(month, equalTo: Date(), toGranularity: .month)
    }

    static func monthTitle(_ month: Date) -> String {
        let parts = calendar.dateComponents([.year, .month], from: month)
        return "\(parts.year ?? 0) 年 \(parts.month ?? 0) 月"
    }

    static func dayTitle(_ date: Date) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0) 月 \(parts.day ?? 0) 日"
    }

    /// 返回 6 周 × 7 天，不属于本月的格子为 nil
    static func weeks(in month: Date) -> [[Date?]] {
        let start = startOfMonth(for: month)
        guard let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: start)
        // weekday: 周日=1 … 周六=7；网格从周一开始
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7

        var slots: [Date?] = Array(repeating: nil, count: leading)
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: start) {
                slots.append(date)
            }
        }
        while slots.count % 7 != 0 { slots.append(nil) }
        while slots.count < 42 { slots.append(nil) }

        return stride(from: 0, to: 42, by: 7).map { Array(slots[$0..<($0 + 7)]) }
    }
}

enum HistoryMetric: String, CaseIterable, Identifiable, Hashable {
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

    func value(of hour: HourlyBucket) -> Double {
        switch self {
        case .cpu: return hour.cpuSeconds
        case .network: return Double(hour.networkTotal)
        case .memory: return hour.memoryBytesAverage
        }
    }

    func value(of app: AppUsage) -> Double {
        switch self {
        case .cpu: return app.cpuSeconds
        case .network: return Double(app.networkTotal)
        case .memory: return Double(app.peakMemoryBytes)
        }
    }

    /// 应用维度的数值（量级较小，用秒）
    func format(_ value: Double) -> String {
        switch self {
        case .cpu: return String(format: "%.1f 核·秒", value)
        case .network, .memory: return Fmt.bytes(value)
        }
    }

    /// 时段维度的数值：一小时可能累计到几千核·秒，换算成核·分/核·时更好读
    func formatBucket(_ value: Double) -> String {
        switch self {
        case .cpu:
            if value >= 3600 { return String(format: "%.1f 核·时", value / 3600) }
            if value >= 60 { return String(format: "%.0f 核·分", value / 60) }
            return String(format: "%.1f 核·秒", value)
        case .network, .memory: return Fmt.bytes(value)
        }
    }
}
