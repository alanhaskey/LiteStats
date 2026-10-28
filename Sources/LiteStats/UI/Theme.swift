import SwiftUI

/// 配色与尺寸常量。集中管理，方便以后做主题。
enum Theme {
    // 面板
    static let panelWidth: CGFloat = 400
    /// 正文高度：与 `MetricsContent` 内各区块高度之和严格一致，避免裁切
    /// 58 + 1 + 36 + 1 + 56 + 1 + 14 + 1 + 13 + 7×6(间距) + 16×2(内边距) = 255
    static let bodyHeight: CGFloat = 273   // 新增网络信息行（12pt + 间距 6）
    static let cornerRadius: CGFloat = 20
    static let tabCornerRadius: CGFloat = 10
    static let padding: CGFloat = 16
    static let sectionSpacing: CGFloat = 6

    // 文字
    static let label = Color.white.opacity(0.55)
    static let value = Color.white
    static let subtle = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.10)

    /// 普通窗口里的次要文字色。不用 `.secondary`：语义色依赖背景 vibrancy，
    /// 在没有底色的视图里（或离屏渲染时）会整段画不出来。
    static let subtleLabel = Color.primary.opacity(0.55)

    /// 面板底色：**纯黑**。物理刘海在屏幕上是纯黑，只有用纯黑，展开时的岛颈/黑耳
    /// 才能和它无缝连成一体；略微偏灰的一点点色差都会让两者看起来是分开的两块。
    /// 面板体靠 1px 高光和阴影保持"卡片感"。不用毛玻璃材质——省 ~90 MB 物理占用。
    static let panelFill = Color.black

    // 指标色（按负载变色）
    static func cpu(_ usage: Double) -> Color {
        switch usage {
        case ..<0.55: return Color(red: 0.29, green: 0.87, blue: 0.71)   // 青绿
        case ..<0.85: return Color(red: 1.00, green: 0.72, blue: 0.30)   // 琥珀
        default: return Color(red: 1.00, green: 0.42, blue: 0.42)        // 红
        }
    }

    static func memory(_ usage: Double) -> Color {
        usage < 0.85 ? Color(red: 0.42, green: 0.68, blue: 1.00)
                     : Color(red: 1.00, green: 0.55, blue: 0.35)
    }

    static let gpu = Color(red: 0.72, green: 0.58, blue: 1.00)
    static let down = Color(red: 0.38, green: 0.85, blue: 0.55)
    static let up = Color(red: 1.00, green: 0.66, blue: 0.35)

    /// 面板背景：毛玻璃 + 一层压暗，保证在浅色壁纸下文字也清晰
    static func background() -> some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Color.black.opacity(0.55))
        }
    }
}

/// 指标行的小标题
struct MetricLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.label)
            .textCase(.uppercase)
            .kerning(0.4)
    }
}

/// 细横线
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
    }
}

/// 细进度条
struct MiniBar: View {
    let value: Double
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}
