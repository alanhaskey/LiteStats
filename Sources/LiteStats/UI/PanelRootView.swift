import LiteStatsCore
import SwiftUI

/// 灵动岛的轮廓：顶部"岛颈"（贴着物理刘海，左右露出一小段黑耳）+ 下方面板体。
///
/// 两段路径用 nonZero 填充规则合并成并集，避免出现接缝。
struct IslandShape: Shape {
    var tab: CGRect
    var body: CGRect
    var bodyRadius: CGFloat
    var tabRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // 面板体：四个角都圆角
        path.addRoundedRect(in: body, cornerSize: CGSize(width: bodyRadius, height: bodyRadius))
        if tab.width > 1, tab.height > 1 {
            // 岛颈：顶边贴屏幕顶部（直角），仅底边圆角，和物理刘海的轮廓保持一致
            var tabPath = Path()
            tabPath.move(to: CGPoint(x: tab.minX, y: tab.minY))
            tabPath.addLine(to: CGPoint(x: tab.maxX, y: tab.minY))
            tabPath.addLine(to: CGPoint(x: tab.maxX, y: tab.maxY - tabRadius))
            tabPath.addQuadCurve(to: CGPoint(x: tab.maxX - tabRadius, y: tab.maxY),
                                 control: CGPoint(x: tab.maxX, y: tab.maxY))
            tabPath.addLine(to: CGPoint(x: tab.minX + tabRadius, y: tab.maxY))
            tabPath.addQuadCurve(to: CGPoint(x: tab.minX, y: tab.maxY - tabRadius),
                                 control: CGPoint(x: tab.minX, y: tab.maxY))
            tabPath.closeSubpath()
            path.addPath(tabPath)
        }
        return path
    }
}

/// 面板根视图。
///
/// 尺寸约定：根视图永远是 `layout.windowSize`（固定），窗口在收起态比它小，
/// 此时所有内容透明度为 0，所以裁切不可见。
struct PanelRootView: View {
    let service: MonitorService
    let presentation: PanelPresentation

    var body: some View {
        let layout = presentation.layout
        let expanded = presentation.isExpanded

        ZStack(alignment: .topLeading) {
            if layout.isFallback, !expanded {
                // 无刘海屏：收起时是一个可见的小胶囊（否则完全没有可发现性）。
                // 用 GeometryReader 贴住窗口实际尺寸 —— 收起态窗口只有胶囊那么大，
                // 而根视图是按展开尺寸算的，直接摆会被居中、画到窗口外面去。
                GeometryReader { geo in
                    fallbackPill(layout: layout)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }

            // 关键：收起时**不构建**视图树（而不是把它设成 opacity 0）。
            // 实测：只要内容存在，SwiftUI 就会初始化渲染管线，物理占用从 ~19 MB 涨到 ~100 MB。
            // 收起时不构建，常驻开销就回到二十几 MB 量级。
            if expanded {
                expandedIsland(layout: layout)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)),
                        removal: .opacity))
            }
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func expandedIsland(layout: PanelLayout) -> some View {
        let shape = IslandShape(tab: layout.tabRect,
                                body: layout.bodyRect,
                                bodyRadius: Theme.cornerRadius,
                                tabRadius: Theme.tabCornerRadius)
        ZStack(alignment: .topLeading) {
            // 刻意不用 `.ultraThinMaterial`：毛玻璃会创建一个 NSVisualEffectView 背景滤镜，
            // 实测让面板展开时的物理占用从 ~12 MB 涨到 ~100 MB（不透明纯色只要一点点）。
            // 灵动岛本来就是纯黑，这里用接近黑的实色反而更还原。
            shape
                .fill(Theme.panelFill)
                .overlay {
                    shape.stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.42), radius: 10, y: 4)

            MetricsContent(service: service)
                .offset(y: layout.bodyRect.minY)
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func fallbackPill(layout: PanelLayout) -> some View {
        let cpu = service.snapshot?.cpu.total ?? 0
        HStack(spacing: 5) {
            Circle().fill(Theme.cpu(cpu)).frame(width: 6, height: 6)
            Text("CPU \(Fmt.percent(cpu, decimals: 0))")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(width: layout.fallbackPillSize.width, height: layout.fallbackPillSize.height)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
    }
}
