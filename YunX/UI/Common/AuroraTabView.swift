import SwiftUI

// === Aurora UI · Tab 页容器（iOS / SwiftUI）===
//
// 提供两套实现，按系统版本自动选：
//   · iOS 18+   → 原生 `TabView` + `Tab`（iOS 26 上自动获得 Liquid Glass）
//   · iOS 16/17 → 自绘悬浮底栏（和 Android 版视觉一致）
//
// 为什么不只用原生 TabView：
//   原生 TabView 从 iOS 18 才有 `Tab` 这个可用 API；16.4 的部署目标下必须留一条自绘退路。
//   而且 Aurora UI 的底栏是「实白胶囊 + 选中项浅品牌底」，原生样式在低版本上对不上。
//
// 详见 references/ios-components.md

// MARK: - 共享 spec

/// Tab 项描述。`Value` 通常是业务枚举。
struct AuroraTabSpec<Value: Hashable>: Identifiable {

    let id: Value
    let title: String

    /// 未选中图标。**必须用 outline 变体** ——
    /// 原生 TabView 会自动把选中态换成 filled 变体，这里再给 filled 会导致常亮。
    let icon: String

    /// 选中图标（仅 iOS 16/17 的自绘底栏用，原生 TabView 忽略）
    let selectedIcon: String

    /// 角标文案。`nil` 或空串都不显示。
    let badge: String?

    init(
        id: Value,
        title: String,
        icon: String,
        selectedIcon: String? = nil,
        badge: String? = nil
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.selectedIcon = selectedIcon
            ?? (icon.hasSuffix(".fill") ? icon : icon + ".fill")
        self.badge = badge
    }
}

// MARK: - 原生实现（iOS 18+）

@available(iOS 18.0, *)
struct AuroraTabView<Value: Hashable, Content: View>: View {

    @Binding private var selection: Value
    private let items: [AuroraTabSpec<Value>]
    private let content: (Value) -> Content

    init(
        selection: Binding<Value>,
        items: [AuroraTabSpec<Value>],
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self._selection = selection
        self.items = items
        self.content = content
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(items) { item in
                Tab(value: item.id, role: nil) {
                    content(item.id)
                } label: {
                    // 用 Label 而不是 Tab("标题", systemImage:) ——
                    // 后者首参是字面量友好的签名，传 String 变量不稳
                    Label(item.title, systemImage: item.icon)
                }
            }
        }
        // 选中态染成品牌色；图标、文字都会跟着变
        .tint(Aurora.brand)
    }
}

// MARK: - 关于角标（badge）
//
// 原生 Tab 路径**不支持条件性角标**，两个原因：
//   1. `Tab` 不是 `View`（没有 `.modifier`），所以不能用 ViewModifier 包一层条件。
//   2. `TabContent.badge(_:)` 的返回类型是 `some TabContent<Self.TabValue>` —— 不透明类型。
//      写 `if hasBadge { tab.badge(x) } else { tab }` 时两个分支底层类型不同，
//      无法收敛到同一个 opaque type，编译器直接报错。
//
// 变通办法：
//   · 要角标就在 TabView 那里直接 `.badge("3")` 写死（无条件的）
//   · 或者走 iOS 16/17 的自绘底栏 `AuroraLegacyTabBar` —— 它是普通 HStack，
//     角标想怎么画怎么画（`AuroraTabSpec.badge` 就是给它用的）
//   · 或者自己维护一个 UITabBarController 包在 UIViewControllerRepresentable 里，
//     用 `tabBarItem.badgeValue` 完全控制

// MARK: - 玻璃胶囊底栏（可左右拖动）

/// 测量胶囊内容区宽度，用来自算每一项的等分宽度。
private struct AuroraTabBarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 透明玻璃胶囊底栏 —— 取代早期的「实白圆角条 + 圆形选中底」。
///
/// 视觉：
///   · 外层是一枚悬浮的**无色玻璃**胶囊，背景极光直接透上来，没有实底
///   · 选中的那一项由一块稍亮的玻璃块承托（不是色块），颜色只出现在图标和文字上
///
/// 交互：
///   · **点按**某项 → 切换；玻璃块以 spring 滑到目标位置
///   · **在胶囊上左右拖** → 玻璃块实时跟手平移，松手按「实际位移 + 速度预测」吸附到最近的项
///   · 拖到两端有硬边界，不会越出胶囊
///
/// 这里没有用 `Button` 承载每一项：胶囊整体挂了一个 `DragGesture(minimumDistance: 0)`，
/// 点击与拖动由同一个手势分流（位移 ≤ 5pt 视为点击）。嵌套 Button 在拖动手势下
/// 会同时触发 tap，导致「拖到第 3 项松手却又跳回被点的那项」。
struct AuroraGlassTabBar<Value: Hashable, Content: View>: View {

    @Binding var selection: Value
    let items: [AuroraTabSpec<Value>]
    let content: (Value) -> Content

    /// 拖动时的实时位移（相对当前选中项的左边缘）
    @State private var dragTranslation: CGFloat = 0
    /// 是否已越过点击阈值：决定松手时按「点击」还是「拖动吸附」处理
    @State private var isDragging = false
    /// 按下但还没开始拖的那一项，用于轻微缩放反馈
    @State private var pressedIndex: Int?
    /// 胶囊内容区（不含内边距）的宽度
    @State private var contentWidth: CGFloat = 0

    /// 胶囊高度（含上下内边距）
    private let barHeight: CGFloat = 62
    /// 内容区与胶囊边缘的间距
    private let barInset: CGFloat = 7
    /// 单项高度
    private let itemHeight: CGFloat = 48
    /// 拖动判定阈值
    private let dragThreshold: CGFloat = 5

    private var snap: Animation { .spring(response: 0.34, dampingFraction: 0.82) }

    init(
        selection: Binding<Value>,
        items: [AuroraTabSpec<Value>],
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self._selection = selection
        self.items = items
        self.content = content
    }

    var body: some View {
        content(selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 页面本身瞬时切换：这里只让玻璃块做位移动画，
            // 否则整页会跟着 withAnimation 淡入淡出，切 Tab 会有拖影感。
            .transition(.identity)
            // 底栏用 safeAreaInset 交给系统处理：内容会自动让出高度，
            // 滑到底不会被玻璃条盖住（这是 ZStack 浮层做不到的）。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bar
            }
            .preferredColorScheme(.light)
    }

    // MARK: 布局

    private var currentIndex: Int {
        items.firstIndex(where: { $0.id == selection }) ?? 0
    }

    /// 单项等分宽度
    private var itemWidth: CGFloat {
        guard !items.isEmpty, contentWidth > 0 else { return 0 }
        return contentWidth / CGFloat(items.count)
    }

    /// 玻璃块宽度（项宽两侧各留 4pt 呼吸）
    private var indicatorWidth: CGFloat {
        max(0, itemWidth - 8)
    }

    /// 玻璃块的横向位置：当前项基准位 + 拖动位移，并夹在首尾之间
    private var indicatorX: CGFloat {
        guard itemWidth > 0, !items.isEmpty else { return 0 }
        let sideGap = (itemWidth - indicatorWidth) / 2
        let raw = CGFloat(currentIndex) * itemWidth + dragTranslation + sideGap
        let lastGap = CGFloat(max(0, items.count - 1)) * itemWidth
        return min(max(raw, sideGap), lastGap + sideGap)
    }

    private var bar: some View {
        ZStack(alignment: .leading) {
            indicator

            HStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    tabItem(items[index], index: index)
                }
            }
            .frame(height: itemHeight)
            .contentShape(Rectangle())
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: AuroraTabBarWidthKey.self,
                        value: proxy.size.width
                    )
                }
            )
            .gesture(dragGesture)
        }
        .padding(.horizontal, barInset)
        .padding(.vertical, barInset)
        .frame(height: barHeight)
        .background(
            // 无色玻璃：材质 + 极淡白色高光，不掺品牌色
            GlassSurface(shape: Capsule(style: .continuous), shadowRadius: 22, highlight: 0.20)
        )
        .contentShape(Capsule(style: .continuous))
        .onPreferenceChange(AuroraTabBarWidthKey.self) { width in
            if abs(width - contentWidth) > 0.5 { contentWidth = width }
        }
        .padding(.horizontal, AuroraMetrics.pagePadding)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// 承托选中项的玻璃块
    ///
    /// 拆成几个小属性而不是一条长链：SwiftUI 的类型检查器对「多层 overlay + 内联渐变」
    /// 的表达式很容易超时（`unable to type-check in reasonable time`）。
    private var indicator: some View {
        Capsule(style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(Capsule(style: .continuous).fill(indicatorFill))
            .overlay(Capsule(style: .continuous).strokeBorder(indicatorStroke, lineWidth: 1))
            .shadow(
                color: Color.black.opacity(isDragging ? 0.11 : 0.07),
                radius: isDragging ? 11 : 7,
                x: 0,
                y: 2
            )
            .frame(width: indicatorWidth, height: itemHeight - 6)
            .offset(x: indicatorX, y: 3)
            .opacity(itemWidth > 0 ? 1 : 0)
    }

    private var indicatorFill: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(isDragging ? 0.72 : 0.58),
                Color.white.opacity(0.30)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var indicatorStroke: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.95),
                Color.white.opacity(0.35)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private func tabItem(_ item: AuroraTabSpec<Value>, index: Int) -> some View {
        let active = index == currentIndex
        let pressed = pressedIndex == index

        VStack(spacing: 2) {
            Image(systemName: active ? item.selectedIcon : item.icon)
                .font(.system(size: 17, weight: active ? .semibold : .regular))
                .frame(height: 21)
            Text(item.title)
                .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                .lineLimit(1)
        }
        // 选中只染字色，不填色块 —— 保持「无色玻璃」的统一观感
        .foregroundStyle(active ? Aurora.brand : Aurora.inkSoft.opacity(0.9))
        .frame(maxWidth: .infinity)
        .frame(height: itemHeight)
        .scaleEffect(pressed ? 0.90 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressed)
        .overlay(alignment: .top) {
            if let badge = item.badge, !badge.isEmpty {
                Text(badge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1)
                    .background(Capsule(style: .continuous).fill(Aurora.rose))
                    .offset(x: 15, y: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(active ? .isSelected : AccessibilityTraits())
        .accessibilityAction { select(index: index) }
    }

    // MARK: 手势

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // 还没越过阈值：当作「按下」，只做缩放反馈
                if !isDragging, abs(value.translation.width) <= dragThreshold {
                    let hit = index(at: value.startLocation.x)
                    if pressedIndex != hit { pressedIndex = hit }
                    return
                }
                if !isDragging {
                    isDragging = true
                    pressedIndex = nil
                }
                dragTranslation = value.translation.width
            }
            .onEnded { value in
                guard !items.isEmpty else {
                    isDragging = false
                    return
                }
                let from = currentIndex
                pressedIndex = nil

                guard isDragging else {
                    // 位移没过阈值 → 点击：落在哪一项就切到哪一项
                    let target = index(at: value.location.x)
                    isDragging = false
                    select(index: target)
                    return
                }

                // 实际位移 + 甩动速度的预测段（predicted - translation 就是速度带来的增量），
                // 取一半作为吸附倾向，避免快速轻扫一下跳过两格。
                let fling = value.predictedEndTranslation.width - value.translation.width
                let base = itemWidth * CGFloat(from)
                let projected = base + value.translation.width + fling * 0.5
                let raw = itemWidth > 0 ? projected / itemWidth : CGFloat(from)
                let target = min(max(Int(raw.rounded()), 0), items.count - 1)

                isDragging = false
                animate {
                    self.dragTranslation = 0
                    if target != from { self.selection = self.items[target].id }
                }
            }
    }

    /// 手势横坐标 → 项下标
    private func index(at x: CGFloat) -> Int {
        guard itemWidth > 0, !items.isEmpty else { return 0 }
        let raw = Int((x / itemWidth).rounded(.down))
        return min(max(raw, 0), items.count - 1)
    }

    private func select(index: Int) {
        guard items.indices.contains(index) else { return }
        pressedIndex = nil
        let id = items[index].id
        guard id != selection else { return }
        animate { selection = id }
    }

    private func animate(_ body: () -> Void) {
        withAnimation(snap) { body() }
    }
}

/// 旧名兼容：早期只有「实白胶囊」版本时叫 `AuroraLegacyTabBar`。
typealias AuroraLegacyTabBar<Value: Hashable, Content: View> = AuroraGlassTabBar<Value, Content>

// MARK: - 统一入口

/// Tab 页宿主：按系统版本自动选原生 TabView 或自绘底栏。
///
/// ```swift
/// AuroraTabHost(selection: $tab, items: [
///     AuroraTabSpec(id: AppTab.home, title: "首页", icon: "house"),
///     AuroraTabSpec(id: AppTab.drive, title: "网盘", icon: "cloud"),
/// ]) { tab in
///     switch tab { ... }
/// }
/// ```
struct AuroraTabHost<Value: Hashable, Content: View>: View {

    @Binding private var selection: Value
    private let items: [AuroraTabSpec<Value>]
    private let content: (Value) -> Content

    init(
        selection: Binding<Value>,
        items: [AuroraTabSpec<Value>],
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self._selection = selection
        self.items = items
        self.content = content
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            AuroraTabView(selection: $selection, items: items, content: content)
        } else {
            AuroraLegacyTabBar(selection: $selection, items: items, content: content)
        }
    }
}
