import SwiftUI

/// 迷你折线图。用 `Canvas` 直接绘制，避免每帧创建视图层级。
/// 支持第二条对比曲线（网络上下行共用一张图）。
struct Sparkline: View {
    let values: [Double]
    /// 纵轴上限；传 nil 时按数据自身最大值自适应（下限 1 避免除零）
    let maxValue: Double?
    let color: Color
    /// 第二条曲线（画在主线之上，不填充）
    var secondaryValues: [Double] = []
    var secondaryColor: Color = .clear
    var lineWidth: CGFloat = 1.5
    var filled: Bool = true

    private var secondaryEmpty: Bool { secondaryValues.count < 2 }

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2, size.width > 1, size.height > 1 else { return }
            let upper: Double = {
                if let maxValue { return max(maxValue, 1e-9) }
                let all = values + (secondaryEmpty ? [] : secondaryValues)
                return max(all.max() ?? 1, 1e-9)
            }()
            let stepX = size.width / CGFloat(max(values.count - 1, 1))
            let usable = size.height - lineWidth

            func point(_ index: Int, _ raw: Double, _ count: Int) -> CGPoint {
                let norm = min(max(raw / upper, 0), 1)
                let x = count == values.count
                    ? CGFloat(index) * stepX
                    : CGFloat(index) * (size.width / CGFloat(max(count - 1, 1)))
                return CGPoint(x: x, y: usable - CGFloat(norm) * usable + lineWidth / 2)
            }

            var line = Path()
            for (i, raw) in values.enumerated() {
                let p = point(i, raw, values.count)
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }

            if filled {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.34), color.opacity(0.02)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)))
            }

            if !secondaryEmpty {
                var second = Path()
                for (i, raw) in secondaryValues.enumerated() {
                    let p = point(i, raw, secondaryValues.count)
                    if i == 0 { second.move(to: p) } else { second.addLine(to: p) }
                }
                ctx.stroke(second, with: .color(secondaryColor),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }

            ctx.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

/// 折线图的量程：低负载时若固定用 0...1，曲线会一直贴着底边看不出形态。
enum SparkRange {
    static func adaptive(_ values: [Double], floor: Double) -> Double {
        let peak = values.max() ?? 0
        return min(1, max(floor, peak * 1.15))
    }

    /// 网络量程：至少 64 KB/s，否则空闲时的噪声会被放大成大起大落
    static func network(_ values: [Double]...) -> Double {
        let peak = values.flatMap { $0 }.max() ?? 0
        return max(64 * 1024, peak * 1.15)
    }
}
