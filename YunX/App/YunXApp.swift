import SwiftUI

@main
struct YunXApp: App {

    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.light)
        }
    }
}

// MARK: - Tab

enum AppTab: Hashable {
    case resolve
    case accounts
    case download
    case settings
}

// MARK: - 根视图

struct RootView: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: AppTab = .resolve

    private var tabItems: [AuroraTabSpec<AppTab>] {
        [
            AuroraTabSpec(id: .resolve, title: "解析", icon: "link"),
            AuroraTabSpec(id: .accounts, title: "账号", icon: "person.crop.circle"),
            AuroraTabSpec(id: .download, title: "下载", icon: "arrow.down.circle"),
            AuroraTabSpec(id: .settings, title: "设置", icon: "gearshape")
        ]
    }

    var body: some View {
        ZStack(alignment: .top) {
            AuroraBackdrop()

            AuroraLegacyTabBar(selection: $tab, items: tabItems) { current in
                Group {
                    switch current {
                    case .resolve:
                        ResolveScreen()
                    case .accounts:
                        AccountsScreen()
                    case .download:
                        DownloadScreen()
                    case .settings:
                        SettingsScreen()
                    }
                }
            }

            ToastOverlay()
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear {
            model.checkClipboard()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                model.checkClipboard()
            }
        }
    }
}

// MARK: - 全局提示

struct ToastOverlay: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack {
            if let toast = model.toast {
                HStack(spacing: 7) {
                    Image(systemName: icon(for: toast.kind))
                        .font(.system(size: 12, weight: .bold))
                    Text(toast.text)
                        .font(AuroraFont.labelMedium)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(tint(for: toast.kind))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(GlassSurface(shape: Capsule(), highlight: 0.34))
                .padding(.horizontal, 28)
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(nanoseconds: 2_800_000_000)
                    withAnimation(.easeOut(duration: 0.2)) {
                        if model.toast?.id == toast.id { model.toast = nil }
                    }
                }
            }
            Spacer()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.toast?.id)
    }

    private func icon(for kind: Toast.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func tint(for kind: Toast.Kind) -> Color {
        switch kind {
        case .info: return Aurora.info
        case .success: return Aurora.success
        case .warning: return Aurora.warning
        case .error: return Aurora.danger
        }
    }
}
