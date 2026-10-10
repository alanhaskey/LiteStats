import LiteStatsCore
import SwiftUI

/// 每核心柱状图的几何（纯函数，便于按不同核心数单测）。
///
/// 面板宽度是固定的（`Theme.panelWidth`），所以适配不同机型时**只改柱宽、不改窗口宽度**。
enum CoreGridLayout {
    /// 每根柱子的高度（画百分比数字时）
    static let barHeight: CGFloat = 22
    /// 数字需要的列宽：font 8 的等宽数字，3 位数（"100"）约 15pt
    static let labelMinColumnWidth: CGFloat = 15.5

    /// 核数多时把间距收紧一点，给柱子多留点宽度
    static func spacing(coreCount: Int) -> CGFloat {
        coreCount >= 20 ? 2 : 3
    }

    static func columnWidth(coreCount: Int, width: CGFloat, spacing: CGFloat? = nil) -> CGFloat {
        let count = max(coreCount, 1)
        let gap = spacing ?? self.spacing(coreCount: count)
        return max(1, (width - gap * CGFloat(count - 1)) / CGFloat(count))
    }

    static func showsLabels(columnWidth: CGFloat) -> Bool {
        columnWidth >= labelMinColumnWidth
    }
}

/// 面板正文：CPU 概览 + 每核心占用 + GPU/内存/网络 + 温度/风扇 + 磁盘/开机时长页脚。
///
/// 高度是硬约束（`Theme.bodyHeight`），所有区块都给固定高度，
/// 这样窗口 frame 与内容尺寸永远一致，不会出现裁切。
struct MetricsContent: View {
    let service: MonitorService

    private var snap: SystemSnapshot? { service.snapshot }

    var body: some View {
        VStack(spacing: Theme.sectionSpacing) {
            cpuHeader.frame(height: 58)
            Hairline()
            coreGrid.frame(height: 36)
            Hairline()
            bottomCells.frame(height: 56)
            Hairline()
            thermalRow.frame(height: 14)
            Hairline()
            footer.frame(height: 13)
        }
        .padding(Theme.padding)
        .frame(width: Theme.panelWidth, height: Theme.bodyHeight, alignment: .top)
    }

    // MARK: - 温度 / 风扇

    private var thermalRow: some View {
        let thermal = snap?.thermal
        return HStack(spacing: 16) {
            HStack(spacing: 4) {
                Text("温度")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.subtle)
                Text(thermal?.cpuTemperature.map { String(format: "%.0f°C", $0) } ?? "—")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(temperatureColor(thermal?.cpuTemperature))
            }
            if let gpuTemperature = thermal?.gpuTemperature {
                HStack(spacing: 4) {
                    Text("GPU")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.subtle)
                    Text(String(format: "%.0f°C", gpuTemperature))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(temperatureColor(gpuTemperature))
                }
            }
            HStack(spacing: 4) {
                Text("风扇")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.subtle)
                Text(fanText(thermal))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.value)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private func fanText(_ thermal: ThermalStats?) -> String {
        guard let fans = thermal?.fans, !fans.isEmpty else { return "—" }
        let rpms = fans.compactMap { $0.rpm }.map { String(Int($0.rounded())) }
        guard !rpms.isEmpty else { return "—" }
        return rpms.joined(separator: " · ") + " rpm"
    }

    private func temperatureColor(_ celsius: Double?) -> Color {
        guard let celsius else { return Theme.subtle }
        switch celsius {
        case ..<60: return Color(red: 0.42, green: 0.85, blue: 0.60)
        case ..<80: return Color(red: 1.00, green: 0.75, blue: 0.35)
        default: return Color(red: 1.00, green: 0.42, blue: 0.42)
        }
    }

    // MARK: - CPU 概览

    private var cpuHeader: some View {
        let cpu = snap?.cpu
        let usage = cpu?.total ?? 0
        let color = Theme.cpu(usage)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    MetricLabel(text: "CPU")
                    Text("\(cpu?.coreCount ?? service.coreCount) 核")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.subtle)
                }
                Text(Fmt.percent(usage))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    // 刻意不用 .contentTransition(.numericText())：数字滚动动画会让展开态 CPU 从 ~0.2% 升到 ~1%（每秒都在重排文字）
                Text("用户 \(Fmt.percent(cpu?.user ?? 0, decimals: 0)) · 系统 \(Fmt.percent(cpu?.system ?? 0, decimals: 0)) · 空闲 \(Fmt.percent(cpu?.idle ?? 1, decimals: 0))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Sparkline(values: service.cpuHistory.values,
                          maxValue: SparkRange.adaptive(service.cpuHistory.values, floor: 0.15),
                          color: color)
                    .frame(width: 148, height: 34)
                Text("负载 \(loadText)")
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(Theme.subtle)
                    .lineLimit(1)
            }
        }
    }

    private var loadText: String {
        guard let cpu = snap?.cpu else { return "—" }
        return String(format: "%.2f %.2f %.2f", cpu.load1, cpu.load5, cpu.load15)
    }

    // MARK: - 每核心

    private var coreUsages: [Double] {
        let cores = snap?.cpu.perCore ?? []
        if cores.isEmpty {
            return Array(repeating: 0, count: max(service.coreCount, 1))
        }
        return cores
    }

    /// 每核心占用条。
    ///
    /// 刻意用**单个 Canvas** 画完 15 根条 + 15 个数字，而不是 15 组 VStack/Shape/Text（≈45 个视图）：
    /// 实测展开态的每秒重绘成本与视图数量强相关，视图化版本一次数据更新要 ~30ms，
    /// 集中到一个 Canvas 后只走一次绘制。
    private var coreGrid: some View {
        let usages = coreUsages
        return Canvas { context, size in
            let count = max(usages.count, 1)
            // 面板宽度固定 400pt，核心数变化只影响**每根柱子的宽度**（见 CoreGridLayout）。
            // 8 核时一根 45pt，15 核 22.8pt，32 核 9.1pt —— 窗口宽度始终不变。
            let spacing = CoreGridLayout.spacing(coreCount: count)
            let columnWidth = CoreGridLayout.columnWidth(coreCount: count, width: size.width,
                                                          spacing: spacing)
            // 列宽不够就**不画百分比数字**：24/32 核的机型上两位数会挤成一团，
            // 此时把数字让出来的高度给柱子，信息反而更清楚。
            let showsLabels = CoreGridLayout.showsLabels(columnWidth: columnWidth)
            let barHeight = showsLabels ? CoreGridLayout.barHeight : size.height - 1

            for (index, usage) in usages.enumerated() {
                let clamped = min(max(usage, 0), 1)
                let x = CGFloat(index) * (columnWidth + spacing)

                let track = CGRect(x: x, y: 0, width: columnWidth, height: barHeight)
                context.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(.white.opacity(0.10)))

                let filled = max(2, barHeight * clamped)
                let bar = CGRect(x: x, y: barHeight - filled, width: columnWidth, height: filled)
                context.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(Theme.cpu(clamped)))

                guard showsLabels else { continue }
                let label = context.resolve(
                    Text(Fmt.percentInt(clamped))
                        .font(.system(size: 8, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.label))
                context.draw(label, at: CGPoint(x: x + columnWidth / 2, y: barHeight + 1), anchor: .top)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - GPU / 内存 / 网络

    private var bottomCells: some View {
        HStack(alignment: .top, spacing: 14) {
            gpuCell
            memoryCell
            networkCell
        }
    }

    private var gpuCell: some View {
        let gpu = snap?.gpu
        let util = gpu?.utilization
        return VStack(alignment: .leading, spacing: 3) {
            MetricLabel(text: "GPU")
            Text(util.map { Fmt.percent($0, decimals: 0) } ?? "—")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.gpu)
            MiniBar(value: util ?? 0, color: Theme.gpu)
            Text(gpu?.inUseMemory.map { "显存 " + Fmt.bytes($0) } ?? "不可用")
                .font(.system(size: 9))
                .foregroundStyle(Theme.subtle)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var memoryCell: some View {
        let mem = snap?.memory
        let usage = mem?.usage ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            MetricLabel(text: "内存")
            Text(Fmt.percent(usage, decimals: 0))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.memory(usage))
            MiniBar(value: usage, color: Theme.memory(usage))
            Text(memSubtitle)
                .font(.system(size: 9))
                .foregroundStyle(Theme.subtle)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var memSubtitle: String {
        guard let mem = snap?.memory else { return "—" }
        var text = "\(Fmt.bytes(mem.used)) / \(Fmt.bytes(mem.total))"
        if mem.swapUsed > 0 {
            text += " · 交换 \(Fmt.bytes(mem.swapUsed))"
        } else if mem.cached > 0 {
            text += " · 缓存 \(Fmt.bytes(mem.cached))"
        }
        return text
    }

    private var networkCell: some View {
        let net = snap?.network
        let down = service.downHistory.values
        let up = service.upHistory.values
        return VStack(alignment: .leading, spacing: 2) {
            MetricLabel(text: "网络")
            Sparkline(values: down,
                      maxValue: SparkRange.network(down, up),
                      color: Theme.down,
                      secondaryValues: up,
                      secondaryColor: Theme.up,
                      lineWidth: 1.2,
                      filled: false)
                .frame(height: 20)
            HStack(spacing: 4) {
                Text("↓").font(.system(size: 9)).foregroundStyle(Theme.down)
                Text(Fmt.rate(net?.download ?? 0))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.value)
                Text("↑").font(.system(size: 9)).foregroundStyle(Theme.up)
                Text(Fmt.rate(net?.upload ?? 0))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.value)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 页脚

    private var footer: some View {
        HStack(spacing: 0) {
            Text(diskText)
            Spacer(minLength: 6)
            Text("已开机 \(snap.map { Fmt.uptime($0.uptime) } ?? "—")")
        }
        .font(.system(size: 9))
        .foregroundStyle(Theme.subtle)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var diskText: String {
        guard let disk = snap?.disk else { return "磁盘 —" }
        var text = "磁盘 \(Fmt.percent(disk.usage, decimals: 0)) 已用 · 可用 \(Fmt.bytes(disk.free))"
        if let iface = snap?.network.interfaceName {
            text += " · \(iface)"
        }
        return text
    }
}
