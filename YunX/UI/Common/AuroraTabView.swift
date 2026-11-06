import SwiftUI

// === Tab 页容器（Aurora UI · 原生实现）===
//
// **底栏不自绘，交给系统。**
//   · iOS 18+   → 原生 `TabView` + `Tab`
//   · iOS 26+   → 同一份代码，系统自动给 Liquid Glass（悬浮胶囊、折射、边缘高光、滚动联动）
//   · iOS 16/17 → 同一个 `TabView`，标签用 `.tabItem`（系统经典底栏）
//
// 这一版把之前的自绘玻璃胶囊（`AuroraGlassTabBar`）整段删掉了，原因：
//   1. Liquid Glass 是系统级材质，`.ultraThinMaterial` 仿不出来（白底上就是一片发灰的磨砂），
//      而且不跟随深色模式、放大字号、「降低透明度」辅助功能。
//   2. 系统的 `tabBarMinimizeBehavior` / `tabViewBottomAccessory` / 用户自定义排序，
//      全挂在系统控件上，自绘一个都拿不到。
//   3. 自绘要自己处理安全区、键盘、点击穿透、拖动与点按手势分流，每个大版本都要重调
//      （之前那个「拖过去又被点回去」就是这个坑）。
//
// 唯一代价：`Tab` 不是 `View`，条件性角标做不到；真要动态角标就换 UIKit `UITabBarController`。

// MARK: - 共享 spec

/// Tab 项描述。`Value` 通常是业务枚举。
struct AuroraTabSpec<Value: Hashable>: Identifiable {

    let id: Value
    let title: String

    /// 图标。**必须 outline 变体**（`folder` 而不是 `folder.fill`），
    /// 系统会自动把选中态换成 filled。
    let icon: String

    init(id: Value, title: String, icon: String) {
        self.id = id
        self.title = title
        self.icon = icon
    }
}

// MARK: - Tab 页宿主

/// Tab 页宿主：内部就是一块原生 `TabView`，iOS 26 上自动获得 Liquid Glass。
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
            modernTabView
        } else {
            legacyTabView
        }
    }

    // MARK: iOS 18+ / 26：原生 Tab

    @available(iOS 18.0, *)
    private var modernTabView: some View {
        TabView(selection: $selection) {
            ForEach(items) { item in
                Tab(value: item.id, role: nil) {
                    content(item.id)
                } label: {
                    Label(item.title, systemImage: item.icon)
                }
            }
        }
        // 只染选中色；玻璃底色由系统决定，不要再设背景
        .tint(Aurora.brand)
    }

    // MARK: iOS 16/17：同一个 TabView，用 .tabItem

    private var legacyTabView: some View {
        TabView(selection: $selection) {
            ForEach(items) { item in
                content(item.id)
                    .tabItem { Label(item.title, systemImage: item.icon) }
                    .tag(item.id)
            }
        }
        .tint(Aurora.brand)
    }
}
