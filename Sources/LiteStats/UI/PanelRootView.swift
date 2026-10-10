import LiteStatsCore
import SwiftUI

/// 灵动岛的轮廓：顶部"岛颈"（贴着物理刘海，左右露出一小段黑耳）+ 下方面板体。
///
/// 关键是它是 **Animatable** 的：`progress` 从 0（只剩物理刘海那么大、完全隐形）到 1（完整面板），
/// 由弹簧动画驱动，形成"水滴坠下来再摊开"的形变（见下面各分量的差速缓动）。
struct IslandShape: Shape, Animatable {
    /// 0 = 收起（轮廓与物理刘海完全重合），1 = 完全展开
    var progress: CGFloat
    /// 无刘海屏：收起态是这颗常驻圆槽（胶囊），展开时从它长出面板
    var usesSlot: Bool = false
    var slot: CGRect = .zero
    /// 物理刘海矩形（窗口内坐标，左上原点）
    var notch: CGRect
    /// 目标岛颈矩形（展开态，窗口内坐标）
    var tab: CGRect
    /// 目标面板体矩形（展开态，窗口内坐标）
    var body: CGRect
    var bodyRadius: CGFloat
    var tabRadius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = min(max(progress, 0), 1)
        var path = Path()

        if usesSlot { return slotPath(p) }

        guard notch.width > 1 else { return path }

        // 差速缓动制造"液体"错位感：岛颈先横向长出来，面板体随后才坠下
        let neckT = pow(p, 0.5)          // 快：横向先铺开
        let bodyT = pow(p, 1.35)         // 慢：纵向后跟上

        // ── 岛颈：宽度从"物理刘海宽度"长到目标值，纵向始终是菜单栏带高度
        let neckWidth = notch.width + (tab.width - notch.width) * neckT
        let neckRect = CGRect(x: notch.midX - neckWidth / 2,
                              y: tab.minY,
                              width: neckWidth,
                              height: tab.height)

        // ── 面板体：宽度从"略窄于刘海"长到满宽，高度从 0 长到满高
        let bodyWidth = max(notch.width * 0.62, body.width * (0.62 + 0.38 * bodyT))
        let bodyHeight = body.height * bodyT
        let bodyRect = CGRect(x: body.midX - bodyWidth / 2,
                              y: body.minY,
                              width: bodyWidth,
                              height: bodyHeight)

        // 底部圆角：起始接近半圆（水滴），随进度摊平成面板圆角
        let bottomRadius = min(bodyRect.height / 2,
                               bodyRadius + (bodyWidth * 0.45 - bodyRadius) * (1 - pow(p, 0.7)))
        let topRadius = min(bodyRadius, max(bodyRect.height / 2, 0))

        if bodyRect.height > 0.5 {
            path.addPath(Self.roundedRect(bodyRect,
                                          topLeft: topRadius, topRight: topRadius,
                                          bottomRight: max(0, bottomRadius), bottomLeft: max(0, bottomRadius)))
        }

        if neckRect.width > 1, neckRect.height > 1 {
            // 岛颈：顶边贴屏幕顶部（直角），仅底边圆角，和物理刘海的轮廓保持一致
            path.addPath(Self.roundedRect(neckRect,
                                          topLeft: 0, topRight: 0,
                                          bottomRight: min(tabRadius, neckRect.height / 2),
                                          bottomLeft: min(tabRadius, neckRect.height / 2)))
        }

        // 两段路径用 nonZero 填充规则取并集（上层调用方不要改成 evenOdd）
        return path
    }

    /// 无刘海屏的形变：圆槽（胶囊）不动，面板体从它下方长出来并摊开。
    /// progress = 0 时只剩胶囊 —— 与 AppKit 画的收起态圆槽完全重合，所以过场无缝。
    private func slotPath(_ p: CGFloat) -> Path {
        var path = Path()
        guard slot.width > 1 else { return path }

        let bodyT = pow(p, 1.35)
        let width = max(slot.width * 0.92, body.width * (0.38 + 0.62 * pow(p, 0.8)))
        let top = slot.maxY - 5                     // 与胶囊轻微重叠，避免中间出现一道缝
        let height = (body.maxY - top) * bodyT
        if height > 1 {
            let rect = CGRect(x: body.midX - width / 2, y: top, width: width, height: height)
            let bottomRadius = min(rect.height / 2,
                                   bodyRadius + (width * 0.45 - bodyRadius) * (1 - pow(p, 0.7)))
            path.addPath(Self.roundedRect(rect,
                                          topLeft: bodyRadius, topRight: bodyRadius,
                                          bottomRight: max(0, bottomRadius),
                                          bottomLeft: max(0, bottomRadius)))
        }

        let radius = slot.height / 2
        path.addPath(Self.roundedRect(slot, topLeft: radius, topRight: radius,
                                      bottomRight: radius, bottomLeft: radius))
        return path
    }

    /// 四个角可以给不同半径的圆角矩形（`addRoundedRect` 不支持）
    static func roundedRect(_ rect: CGRect, topLeft: CGFloat, topRight: CGFloat,
                            bottomRight: CGFloat, bottomLeft: CGFloat) -> Path {
        var path = Path()
        let maxRadius = min(rect.width, rect.height) / 2
        let tl = min(max(topLeft, 0), maxRadius)
        let tr = min(max(topRight, 0), maxRadius)
        let br = min(max(bottomRight, 0), maxRadius)
        let bl = min(max(bottomLeft, 0), maxRadius)

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br)
        }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl)
        }
        path.closeSubpath()
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
        // 用 isContentMounted 而不是 isExpanded：收起时视图要活到形变退回刘海之后再卸掉，
        // 这样两个方向都有"水滴"形变；卸载后回到低常驻内存。
        let expanded = presentation.isContentMounted

        ZStack(alignment: .topLeading) {
            // 关键：收起时**不构建**视图树（而不是把它设成 opacity 0）。
            // 实测：只要内容存在，SwiftUI 就会初始化渲染管线，物理占用从 ~19 MB 涨到 ~100 MB。
            if expanded {
                expandedIsland(layout: layout)
                    .transition(.opacity)
            }
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    private var islandShape: IslandShape {
        let layout = presentation.layout
        return IslandShape(progress: presentation.islandProgress,
                           usesSlot: layout.usesSlot,
                           slot: layout.slotRectInExpandedWindow,
                           notch: layout.notchRect,
                           tab: layout.tabRect,
                           body: layout.bodyRect,
                           bodyRadius: Theme.cornerRadius,
                           tabRadius: Theme.tabCornerRadius)
    }

    @ViewBuilder
    private func expandedIsland(layout: PanelLayout) -> some View {
        let shape = islandShape
        let size = layout.windowSize
        // 内容比形变晚一点露出来：形变初期只看到"水滴"，铺开过程中文字才浮现
        let contentOpacity = min(max((presentation.islandProgress - 0.30) / 0.55, 0), 1)

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

            // 内容：随轮廓逐渐"被挤出来"。裁切要在一个撑满窗口坐标空间的容器上做，
            // 否则 Shape 里的绝对坐标（窗口内）会和内容自身的坐标系对不上。
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: size.width, height: size.height)
                MetricsContent(service: service)
                    .offset(x: layout.bodyRect.minX, y: layout.bodyRect.minY)
                    .opacity(contentOpacity)
            }
            .clipShape(shape)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
