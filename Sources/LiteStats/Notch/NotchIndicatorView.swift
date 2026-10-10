import AppKit
import LiteStatsCore

/// 指示条配色（NSColor 版本，刻意不与 SwiftUI 的 Theme 共用，
/// 避免这个"常驻绘制"的文件把 SwiftUI 拖进来）。
enum IndicatorPalette {
    /// 必须**纯黑**：物理刘海在屏幕上是纯黑（没有像素），
    /// 之前用近黑 RGB(11,11,13)，并排放在浅色壁纸上一眼就能看出色差 —— 那才是"指示条和灵动岛分离"的主因。
    static let earFill = NSColor.black
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
    /// 配置的耳朵长度（未乘进度）
    private var configuredLeftEarWidth: CGFloat = 0
    private var configuredRightEarWidth: CGFloat = 0

    /// 耳朵伸出程度：1 = 完全伸出（收起态），0 = 完全收进物理刘海（展开态）。
    /// 由 `animator()` 在 NSAnimationContext 里逐帧插值，和 SwiftUI 的水滴形变同步。
    @objc dynamic var earProgress: CGFloat = 1 {
        didSet { if earProgress != oldValue { needsDisplay = true } }
    }

    /// 当前实际耳宽（已乘进度）
    var leftEarWidth: CGFloat { configuredLeftEarWidth * earProgress }
    var rightEarWidth: CGFloat { configuredRightEarWidth * earProgress }

    /// 带动画地伸出 / 收回耳朵。
    ///
    /// 不用 `animator()`：实测对自定义属性它会在中途停住（87 → 70 就不动了），
    /// 原因是自定义 KVC 属性靠 AppKit 的通用动画机制，插值不可靠。
    /// 这里直接用 60Hz 定时器 + easeOut 插值，行为确定、可被自检断言，单次动画只有 ~20 帧。
    func setEarProgress(_ value: CGFloat, animated: Bool, duration: TimeInterval) {
        let clamped = min(max(value, 0), 1)
        animationTimer?.invalidate()
        animationTimer = nil
        guard animated, duration > 0.01, abs(clamped - earProgress) > 0.001 else {
            earProgress = clamped
            return
        }
        animationFrom = earProgress
        animationTo = clamped
        animationDuration = duration
        animationStart = Date()

        // 注意：Timer 的 block 是 @Sendable，闭包里不要再捕获/传递 Timer 本身
        // （Swift 6 会报 "sending 'timer' risks causing data races"）。
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = min(1, Date().timeIntervalSince(self.animationStart) / self.animationDuration)
                let eased = 1 - pow(1 - t, 3)          // easeOut
                self.earProgress = self.animationFrom + (self.animationTo - self.animationFrom) * eased
                if t >= 1 {
                    self.animationTimer?.invalidate()
                    self.animationTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private var animationTimer: Timer?
    private var animationStart = Date()
    private var animationFrom: CGFloat = 1
    private var animationTo: CGFloat = 0
    private var animationDuration: TimeInterval = 0.3
    /// 刘海底边相对菜单栏底边的抬高量（黑耳底边要贴齐刘海底边，否则出现 1pt 错台）
    private var notchBottomInset: CGFloat = 0
    /// 物理刘海的底部圆角半径，黑耳内侧要沿同一个弧走，才能"连成一体"
    private var notchCornerRadius: CGFloat = 10
    /// 物理刘海在屏幕上的**全局**矩形。黑耳要锚在刘海的边缘上：
    /// 内边缘钉死、外边缘往里收，才是"被刘海吸进去"；
    /// 若按窗口边缘起画，收缩时内边缘会往屏幕外跑，看起来就是方向反了。
    private var notchGlobalRect: CGRect = .zero
    /// 无刘海屏：收起态画一颗常驻胶囊（圆槽），而不是左右两只黑耳
    private var usesSlot = false
    private var slotGlobalRect: CGRect = .zero
    /// 菜单栏带高度：耳朵必须按这个算高度，**不能用 bounds.height**
    /// —— 窗口展开后 bounds 会变成 294pt，耳朵会被拉成一根长条。
    private var bandHeight: CGFloat = 39
    private var snapshot: SystemSnapshot?

    /// 与外层容器一致：不翻转（原点左下）。绘制时按左下原点算。
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    /// 布局或配置变化时调用
    func configure(layout: PanelLayout, leftMetric: IndicatorMetric, rightMetric: IndicatorMetric) {
        self.leftMetric = leftMetric
        self.rightMetric = rightMetric
        // ⚠️ 只有真的选了指标才画黑耳。
        // 之前这里无条件用 collapsedLeftExtent（26pt），导致"没选任何指标"时刘海两边
        // 仍然各多出一块黑边、看起来像被撑宽了 —— 与"完全收入灵动岛"的预期不符。
        configuredLeftEarWidth = self.leftMetric == .none ? 0 : layout.collapsedLeftExtent
        configuredRightEarWidth = self.rightMetric == .none ? 0 : layout.collapsedRightExtent
        notchBottomInset = layout.notchBottomInset
        notchCornerRadius = layout.notchCornerRadius
        bandHeight = layout.bandHeight
        notchGlobalRect = layout.geometry.notchRect
        usesSlot = layout.usesSlot
        slotGlobalRect = layout.usesSlot ? layout.slotRect : .zero
        needsDisplay = true
    }

    /// 新数据到达时调用（1 Hz 左右）
    func update(snapshot: SystemSnapshot?) {
        self.snapshot = snapshot
        if !isHidden { needsDisplay = true }
    }

    var isActive: Bool { configuredLeftEarWidth > 0 || configuredRightEarWidth > 0 }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        // 黑耳的底边贴齐物理刘海底边（不是菜单栏底边），高度就与刘海一致。
        // 菜单栏带始终贴在窗口顶部，所以用 bounds.maxY 往上推。
        let earHeight = max(1, bandHeight - notchBottomInset)
        let earY = bounds.height - bandHeight + notchBottomInset

        // 文字比黑耳更早淡出：黑耳收到一半时文字就没了，不会出现"半个字贴在刘海边上"
        let textAlpha = min(max((earProgress - 0.45) / 0.55, 0), 1)

        if usesSlot {
            drawSlot(textAlpha: textAlpha)
            return
        }

        // 用**当前窗口 frame** 把刘海的全局坐标换算成窗口内坐标：
        // 展开动画一开始窗口就已经是展开尺寸了，不能拿"收起窗口"的坐标去摆。
        let frame = window?.frame ?? .zero
        let notchLeft = notchGlobalRect.minX - frame.minX
        let notchRight = notchGlobalRect.maxX - frame.minX

        if leftEarWidth > 0.5 {
            // 内边缘固定在刘海左边缘，外边缘随进度往里收
            let rect = CGRect(x: notchLeft - leftEarWidth, y: earY,
                              width: leftEarWidth, height: earHeight)
            drawEar(rect, side: .left)
            drawMetric(leftMetric, in: rect, alpha: textAlpha)
        }
        if rightEarWidth > 0.5 {
            // 同理：内边缘固定在刘海右边缘
            let rect = CGRect(x: notchRight, y: earY,
                              width: rightEarWidth, height: earHeight)
            drawEar(rect, side: .right)
            drawMetric(rightMetric, in: rect, alpha: textAlpha)
        }
    }

    /// 无刘海屏的常驻圆槽：一颗胶囊，里面是 [左侧指标] 表情 + CPU% [右侧指标]。
    ///
    /// 它**一直可见**（不像物理刘海屏那样靠刘海本身当视觉锚点），
    /// 悬浮就长成面板；展开过程中内容先淡出，胶囊由 SwiftUI 的岛形接管。
    private func drawSlot(textAlpha: CGFloat) {
        let frame = window?.frame ?? .zero
        var rect = slotGlobalRect
        rect.origin.x -= frame.minX
        rect.origin.y -= frame.minY
        guard rect.width > 4 else { return }

        let radius = rect.height / 2
        let capsule = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        IndicatorPalette.earFill.setFill()
        capsule.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()

        guard textAlpha > 0.02 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect.insetBy(dx: 3, dy: 0)).addClip()

        // 三块内容按顺序横排并整体居中
        var parts: [NSAttributedString] = []
        if let left = attributedString(for: leftMetric) { parts.append(left) }
        parts.append(slotCenterText())
        if let right = attributedString(for: rightMetric) { parts.append(right) }

        let gap = NSAttributedString(string: "  ", attributes: [.font: NSFont.systemFont(ofSize: 10)])
        let joined = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 { joined.append(gap) }
            joined.append(part)
        }
        let alphaApplied = fading(joined, alpha: textAlpha)
        let size = alphaApplied.size()
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        alphaApplied.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 圆槽中间那块：随负载变脸的表情（+ CPU 百分比，但左右已经显示了 CPU 就不重复）
    private func slotCenterText() -> NSAttributedString {
        let usage = snapshot?.cpu.total ?? 0
        let face: String
        switch usage {
        case ..<0.15: face = "😴"
        case ..<0.45: face = "🙂"
        case ..<0.75: face = "😅"
        default: face = "🔥"
        }
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: face, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
        ]))
        let cpuAlreadyShown = leftMetric == .cpu || rightMetric == .cpu
        if !cpuAlreadyShown, snapshot != nil {
            text.append(NSAttributedString(string: " " + Fmt.percentInt(usage) + "%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: IndicatorPalette.cpu(usage),
            ]))
        }
        return text
    }

    /// 按段各自乘上淡出系数（保留原配色）
    private func fading(_ text: NSAttributedString, alpha: CGFloat) -> NSAttributedString {
        let faded = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: faded.length)
        var alphas: [(NSRange, NSColor)] = []
        faded.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if let color = value as? NSColor { alphas.append((range, color)) }
        }
        for (range, color) in alphas {
            faded.addAttribute(.foregroundColor,
                               value: color.withAlphaComponent(color.alphaComponent * alpha), range: range)
        }
        // 表情没有显式前景色，补一个整体透明度
        let wrapper = NSMutableAttributedString(attributedString: faded)
        wrapper.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let font = value as? NSFont, font.pointSize >= 13 else { return }
            wrapper.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(alpha), range: range)
        }
        return wrapper
    }

    private enum EarSide { case left, right }

    /// 画一块黑耳。
    ///
    /// 关键：内侧不能简单地切成直角，否则会和物理刘海的底部圆角之间漏出一道壁纸缝
    /// （看起来"指示条和灵动岛是分离的"）。这里让内侧沿着**刘海同一个圆角弧**走，
    /// 并且把底边多画过去一个圆角半径，正好补上刘海圆角外侧那块楔形区域 ——
    /// 视觉上就是刘海本身变宽了。
    private func drawEar(_ rect: CGRect, side: EarSide) {
        // 外侧下角用视觉圆角；内侧要贴物理刘海的圆角，**故意比它大 2pt**：
        // 系统没有任何 API 能读到刘海真实的圆角半径，宁可用"多覆盖 2pt"也不要因为估小而留出一道缝。
        let radius = min(notchCornerRadius, rect.width, rect.height / 2)
        let innerRadius = min(radius + 2, rect.width, rect.height / 2)
        guard radius > 0.5 else {
            IndicatorPalette.earFill.setFill()
            NSBezierPath(rect: rect).fill()
            return
        }
        let bottom = rect.minY
        let top = rect.maxY
        let path = NSBezierPath()

        switch side {
        case .left:
            let outer = rect.minX
            let inner = rect.maxX
            path.move(to: CGPoint(x: outer, y: top))
            path.line(to: CGPoint(x: outer, y: bottom + radius))
            path.appendArc(withCenter: CGPoint(x: outer + radius, y: bottom + radius),
                           radius: radius, startAngle: 180, endAngle: 270)
            path.line(to: CGPoint(x: inner + innerRadius, y: bottom))
            path.appendArc(withCenter: CGPoint(x: inner + innerRadius, y: bottom + innerRadius),
                           radius: innerRadius, startAngle: 270, endAngle: 180, clockwise: true)
            path.line(to: CGPoint(x: inner, y: top))
        case .right:
            let outer = rect.maxX
            let inner = rect.minX
            path.move(to: CGPoint(x: outer, y: top))
            path.line(to: CGPoint(x: outer, y: bottom + radius))
            path.appendArc(withCenter: CGPoint(x: outer - radius, y: bottom + radius),
                           radius: radius, startAngle: 0, endAngle: 270, clockwise: true)
            path.line(to: CGPoint(x: inner - innerRadius, y: bottom))
            path.appendArc(withCenter: CGPoint(x: inner - innerRadius, y: bottom + innerRadius),
                           radius: innerRadius, startAngle: 270, endAngle: 360)
            path.line(to: CGPoint(x: inner, y: top))
        }
        path.close()
        IndicatorPalette.earFill.setFill()
        path.fill()
    }

    private func drawMetric(_ metric: IndicatorMetric, in rect: CGRect, alpha: CGFloat) {
        guard metric != .none, alpha > 0.02,
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

        // 内容水平居中：两侧耳长统一，居中后不管放什么指标看起来都是稳的
        let x = rect.midX - size.width / 2
        let y = rect.midY - size.height / 2

        // 裁到黑耳范围内：耳朵正在收回时不会画到刘海上面去
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect.insetBy(dx: 2, dy: 0)).addClip()
        // 按段（标签暗 / 数值亮）各自乘上淡出系数，保留原来的配色
        let faded = NSMutableAttributedString(attributedString: drawable)
        let full = NSRange(location: 0, length: faded.length)
        var alphas: [(NSRange, NSColor)] = []
        faded.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if let color = value as? NSColor { alphas.append((range, color)) }
        }
        for (range, color) in alphas {
            faded.addAttribute(.foregroundColor,
                               value: color.withAlphaComponent(color.alphaComponent * alpha), range: range)
        }
        faded.draw(at: CGPoint(x: x, y: y))
        NSGraphicsContext.restoreGraphicsState()
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
            // 只写 "52°C"：单位已经说明一切，再加 "CPU"/"℃" 都是废话
            if let celsius = snap.thermal.cpuTemperature {
                append("\(Int(celsius.rounded()))", font: value,
                       color: IndicatorPalette.temperature(celsius))
                append("°C", font: label, color: IndicatorPalette.temperature(celsius))
            } else {
                append("—", font: value, color: IndicatorPalette.label)
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
