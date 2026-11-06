import SwiftUI

/// 页面骨架：顶栏 + 滚动内容 + 底部操作条。
///
/// - `topBar`：自绘顶栏（`AppTopBar`）
/// - `content`：滚动内容
/// - `bar`：底部操作条（`GlassBar`）
///
/// **底部条用 `safeAreaInset` 而不是 ZStack 浮层**：
/// 浮层会把最后一行内容压在玻璃条下面（用户明确反馈过这个遮挡问题）。
/// 走 safeAreaInset 后，滚动视图的 contentInset 会自动让出这部分高度，
/// 滑到底也能完整看到最后一张卡片。
struct AuroraScreen<Top: View, Content: View, Bar: View>: View {

    /// 关掉底部操作条。
    /// 用在「外层已经有 Tab 底栏」的页面上——两层玻璃条叠在一起，中间那条缝会漏出滚动内容。
    var showsBar: Bool = true

    @ViewBuilder var topBar: () -> Top
    @ViewBuilder var content: () -> Content
    @ViewBuilder var bar: () -> Bar

    var body: some View {
        if showsBar {
            VStack(spacing: 0) {
                topBar()
                content()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bar()
                    .padding(.horizontal, AuroraMetrics.pagePadding)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
        } else {
            VStack(spacing: 0) {
                topBar()
                content()
            }
        }
    }
}

/// 通用滚动内容容器：统一左右边距、卡片间距、底部留白。
///
/// `bottomInset` 现在只需要给「非底部条」的额外留白（比如悬浮传输胶囊）。
/// 底部操作条占的位置由 `AuroraScreen` 的 `safeAreaInset` 负责，别再重复加 150+。
struct AuroraScrollView<Content: View>: View {

    var bottomInset: CGFloat = AuroraMetrics.listBottomInset
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AuroraMetrics.cardSpacing) {
                content()
            }
            .padding(.horizontal, AuroraMetrics.pagePadding)
            .padding(.top, 4)
            .padding(.bottom, bottomInset)
        }
        .scrollIndicators(.hidden)
    }
}
