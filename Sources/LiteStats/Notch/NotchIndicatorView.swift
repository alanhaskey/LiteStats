import AppKit
import LiteStatsCore

/// 指示条配色（NSColor 版本，刻意不与 SwiftUI 的 Theme 共用，
/// 避免这个"常驻绘制"的文件把 SwiftUI 拖进来）。
enum IndicatorPalette {
    static let earFill = NSColor(red: 0.043, green: 0.043, blue: 0.051, alpha: 1.0)
    static let label = NSColor.white.withAlphaComponent(0.52)
    static let value = NSColor.white

    static func cpu(_ usage: Double) -> NSColor {
        switch usage {
        case ..<0.55: return NSColor(red: 0.29, green: 0.87, blue: 0.71, alpha: 1)
        case ..<0.85: return NSColor(red: 1.00, green: 0.72, blue: 0.30, alpha: 1)
        default: return NSColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1)
        }
    }

    static func memory(_ usage: Double) -> NSColor {
        usage < 0.85 ? NSColor(red: 0.42, green: 0.68, blue: 1.00, alpha: 1)
                     : NSColor(red: 1.00, green: 0.55, blue: 0.35, alpha: 1)
    }

    static func temperature(_ celsius: Double) -> NSColor {
        switch celsius {
        case ..<60: return NSColor(red: 0.42, green: 0.85, blue: 0.60, alpha: 1)
        case ..<80: return NSColor(red: 1.00, green: 0.75, blue: 0.35, alpha: 1)
        default: return NSColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1)
        }
    }

    static let gpu = NSColor(red: 0.72, green: 0.58, blue: 1.00, alpha: 1)
    static let down = NSColor(red: 0.38, green: 0.85, blue: 0.55, alpha: 1)
    static let up = NSColor(red: 1.00, green: 0.66, blue: 0.35, alpha: 1)
    static let disk = NSColor(red: 0.60, green: 0.78, blue: 0.98, alpha: 1)
    static let fan = NSColor(red: 0.66, green: 0.84, blue: 0.92, alpha: 1)
}

/// 收起态的常驻指示条：刘海左右各一块黑色"耳"，上面写一行指标。
///
/// 为什么用纯 AppKit 手绘：SwiftUI 只要渲染过一次就会初始化整条渲染管线，
/// 实测常驻物理占用会从 10 MB 涨到 100 MB。这里只有一个 NSView + NSAttributedString，
/// 1 Hz 重绘的开销可以忽略，也不会破坏"常驻 10 MB"这个指标。
final class NotchIndicatorView: NSView {
    private var leftMetric: IndicatorMetric = .none
    private var rightMetric: IndicatorMetric = .none
    private var leftEarWidth: CGFloat = 0
    private var rightEarWidth: CGFloat = 0
    private var snapshot: SystemSnapshot?

    /// 与外层容器一致：不翻转（原点左下）。绘制时按左下原点算。
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    /// 布局或配置变化时调用
    func configure(layout: PanelLayout, leftMetric: IndicatorMetric, rightMetric: IndicatorMetric) {
        self.leftMetric = layout.isFallback ? .none : leftMetric
        self.rightMetric = layout.isFallback ? .none : rightMetric
        // ⚠️ 只有真的选了指标才画黑耳。
        // 之前这里无条件用 collapsedLeftExtent（26pt），导致"没选任何指标"时刘海两边
        // 仍然各多出一块黑边、看起来像被撑宽了 —— 与"完全收入灵动岛"的预期不符。
        leftEarWidth = (layout.isFallback || self.leftMetric == .none) ? 0 : layout.collapsedLeftExtent
        rightEarWidth = (layout.isFallback || self.rightMetric == .none) ? 0 : layout.collapsedRightExtent
        needsDisplay = true
    }

    /// 新数据到达时调用（1 Hz 左右）
    func update(snapshot: SystemSnapshot?) {
        self.snapshot = snapshot
        if !isHidden { needsDisplay = true }
    }

    var isActive: Bool { leftEarWidth > 0 || rightEarWidth > 0 }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        if leftEarWidth > 0 {
            let rect = CGRect(x: 0, y: 0, width: leftEarWidth, height: bounds.height)
            drawEar(rect, roundedCorner: .bottomLeft)
            drawMetric(leftMetric, in: rect, alignment: .right)
        }
        if rightEarWidth > 0 {
            let rect = CGRect(x: bounds.width - rightEarWidth, y: 0, width: rightEarWidth, height: bounds.height)
            drawEar(rect, roundedCorner: .bottomRight)
            drawMetric(rightMetric, in: rect, alignment: .left)
        }
    }

    private enum RoundedCorner { case bottomLeft, bottomRight }

    /// 画一块黑耳：外侧下角圆角、内侧贴齐物理刘海（保持刘海本身的轮廓）
    private func drawEar(_ rect: CGRect, roundedCorner: RoundedCorner) {
        let radius: CGFloat = 10
        let path = NSBezierPath()
        switch roundedCorner {
        case .bottomLeft:
            path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
            path.line(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.line(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.appendArc(withCenter: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
                           radius: radius, startAngle: 180, endAngle: 270)
        case .bottomRight:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.line(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.appendArc(withCenter: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
                           radius: radius, startAngle: 270, endAngle: 360)
            path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.close()
        IndicatorPalette.earFill.setFill()
        path.fill()
    }

    private enum Alignment { case left, right }

    private func drawMetric(_ metric: IndicatorMetric, in rect: CGRect, alignment: Alignment) {
        guard metric != .none,
              let text = attributedString(for: metric),
              text.length > 0 else { return }

        // 文本放不下就整体缩小字号（最多缩到 8pt）
        var size = text.size()
        var drawable = text
        let available = rect.width - 12
        if size.width > available, available > 10 {
            let scale = max(0.78, available / size.width)
            drawable = scaled(text, factor: scale)
            size = drawable.size()
        }

        let x = alignment == .right ? rect.maxX - 6 - size.width : rect.minX + 6
        let y = rect.midY - size.height / 2
        drawable.draw(at: CGPoint(x: x, y: y))
    }

    private func scaled(_ text: NSAttributedString, factor: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            result.addAttribute(.font, value: NSFont.systemFont(ofSize: font.pointSize * factor, weight: .medium),
                                range: range)
        }
        return result
    }

    // MARK: - 内容

    private func attributedString(for metric: IndicatorMetric) -> NSAttributedString? {
        let label = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let value = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let out = NSMutableAttributedString()

        func append(_ text: String, font: NSFont, color: NSColor) {
            out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }

        guard let snap = snapshot else {
            append(abbreviation(for: metric), font: label, color: IndicatorPalette.label)
            append(" —", font: value, color: IndicatorPalette.label)
            return out
        }

        switch metric {
        case .none:
            return nil

        case .cpu:
            append("CPU", font: label, color: IndicatorPalette.label)
            append(" \(Fmt.percentInt(snap.cpu.total))%", font: value,
                   color: IndicatorPalette.cpu(snap.cpu.total))

        case .memory:
            append("MEM", font: label, color: IndicatorPalette.label)
            append(" \(Fmt.percentInt(snap.memory.usage))%", font: value,
                   color: IndicatorPalette.memory(snap.memory.usage))

        case .gpu:
            append("GPU", font: label, color: IndicatorPalette.label)
            if let utilization = snap.gpu.utilization {
                append(" \(Fmt.percentInt(utilization))%", font: value, color: IndicatorPalette.gpu)
            } else {
                append(" —", font: value, color: IndicatorPalette.label)
            }

        case .disk:
            append("DSK", font: label, color: IndicatorPalette.label)
            if let disk = snap.disk {
                append(" \(Fmt.percentInt(disk.usage))%", font: value, color: IndicatorPalette.disk)
            } else {
                append(" —", font: value, color: IndicatorPalette.label)
            }

        case .temperature:
            append("℃", font: label, color: IndicatorPalette.label)
            if let celsius = snap.thermal.cpuTemperature {
                append(" \(Int(celsius.rounded()))°", font: value,
                       color: IndicatorPalette.temperature(celsius))
            } else {
                append(" —", font: value, color: IndicatorPalette.label)
            }

        case .fan:
            append("FAN", font: label, color: IndicatorPalette.label)
            if let rpm = snap.thermal.fans.compactMap(\.rpm).max() {
                append(" \(Int(rpm.rounded()))", font: value, color: IndicatorPalette.fan)
            } else {
                append(" —", font: value, color: IndicatorPalette.label)
            }

        case .network:
            append("↓", font: label, color: IndicatorPalette.down)
            append(Fmt.compactRate(snap.network.download), font: value, color: IndicatorPalette.down)
            append(" ↑", font: label, color: IndicatorPalette.up)
            append(Fmt.compactRate(snap.network.upload), font: value, color: IndicatorPalette.up)
        }
        return out
    }

    private func abbreviation(for metric: IndicatorMetric) -> String {
        switch metric {
        case .none: return ""
        case .cpu: return "CPU"
        case .memory: return "MEM"
        case .gpu: return "GPU"
        case .disk: return "DSK"
        case .temperature: return "℃"
        case .fan: return "FAN"
        case .network: return "↓↑"
        }
    }
}
