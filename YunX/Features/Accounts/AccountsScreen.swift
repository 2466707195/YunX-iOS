import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 目标

/// 账号页里「要操作哪个平台」。
enum AccountTarget: Identifiable, Equatable {

    case pan(SharePlatform)
    case video(VideoPlatform)

    var id: String {
        switch self {
        case .pan(let platform): return "pan-\(platform.rawValue)"
        case .video(let platform): return "video-\(platform.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .pan(let platform): return platform.displayName
        case .video(let platform): return platform.displayName
        }
    }

    var tint: Color {
        switch self {
        case .pan(let platform): return platform.tint
        case .video(let platform): return platform.tint
        }
    }

    var systemIcon: String {
        switch self {
        case .pan(let platform): return platform.systemIcon
        case .video(let platform): return platform.systemIcon
        }
    }

    /// 登录入口
    var loginURL: String? {
        switch self {
        case .pan(.quark): return "https://pan.quark.cn"
        case .pan(.uc): return "https://drive.uc.cn"
        case .video(.bilibili): return VideoPlatform.bilibili.loginUrl
        case .video(.xhs): return VideoPlatform.xhs.loginUrl
        default: return nil
        }
    }

    var cookieDomain: String {
        switch self {
        case .pan(.quark): return "quark.cn"
        case .pan(.uc): return "uc.cn"
        // 其余网盘还没有适配器，也就没有可提示的 Cookie 来源
        case .pan: return ""
        case .video(let platform): return platform.cookieDomain
        }
    }

    var viewportWidth: Int? {
        switch self {
        case .video(.xhs): return 1280
        default: return nil
        }
    }

    var benefit: String {
        switch self {
        case .pan(let platform):
            return "登录\(platform.displayName)后，解析私有分享、取链更稳定（公开分享不登录也能解析）"
        case .video(let platform):
            return platform.loginBenefit
        }
    }

    var isImplemented: Bool {
        switch self {
        case .pan(let platform): return platform.isImplemented
        case .video: return true
        }
    }

    var manualCookieOnly: Bool {
        switch self {
        case .video(let platform): return platform.manualCookieOnly
        case .pan: return false
        }
    }
}

// MARK: - 账号页

/// Tab 2：网盘账号 + 视频平台账号 + 认证备份。
struct AccountsScreen: View {

    @EnvironmentObject private var model: AppModel

    @State private var sheet: AccountTarget?
    @State private var showBackup = false

    private var panPlatforms: [SharePlatform] {
        SharePlatform.allCases.filter { $0 != .github }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppTopBar(title: "账号", subtitle: "登录后可解析更多内容，凭证加密保存在本机") {
                GlassIconButton(systemIcon: "lock.shield", tint: Aurora.inkSoft, diameter: 32, iconSize: 12) {
                    showBackup = true
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: AuroraMetrics.cardSpacing) {
                    SectionHeader(title: "网盘账号", hint: "公开分享无需登录")
                    ForEach(panPlatforms) { platform in
                        panRow(platform)
                    }

                    SectionHeader(title: "视频平台")
                    ForEach(VideoPlatform.allCases) { platform in
                        videoRow(platform)
                    }

                    backupCard
                    disclaimer
                }
                .padding(.horizontal, AuroraMetrics.pagePadding)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(item: $sheet) { target in
            AccountFlowSheet(target: target)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showBackup) {
            BackupSheet()
                .presentationDetents([.large])
        }
    }

    // MARK: 网盘行

    private func panRow(_ platform: SharePlatform) -> some View {
        let account = model.accounts.primaryPanAccount(platform)
        return SectionCard {
            HStack(spacing: 10) {
                PlatformIcon(systemIcon: platform.systemIcon, tint: platform.tint, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(platform.displayName)
                            .font(AuroraFont.labelLarge)
                            .foregroundStyle(Aurora.ink)
                        if !platform.isImplemented {
                            TinyChip(text: "适配中", tint: Aurora.muted)
                        }
                    }
                    Text(account?.subtitle ?? "未登录")
                        .font(.system(size: 11))
                        .foregroundStyle(account == nil ? Aurora.muted : Aurora.inkSoft)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if platform.isImplemented {
                    if account == nil {
                        SmallTonalButton(text: "登录", systemIcon: "person.badge.key") {
                            sheet = .pan(platform)
                        }
                    } else {
                        Button {
                            sheet = .pan(platform)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Aurora.inkSoft)
                                .frame(width: 34, height: 34)
                                .background(GlassSurface(shape: Circle(), shadowRadius: 6, highlight: 0.3))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("暂不支持")
                        .font(.system(size: 11))
                        .foregroundStyle(Aurora.muted)
                }
            }
        }
    }

    // MARK: 视频行

    private func videoRow(_ platform: VideoPlatform) -> some View {
        let account = model.accounts.primaryVideoAccount(platform)
        return SectionCard {
            HStack(spacing: 10) {
                PlatformIcon(systemIcon: platform.systemIcon, tint: platform.tint, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(platform.displayName)
                            .font(AuroraFont.labelLarge)
                            .foregroundStyle(Aurora.ink)
                        if !platform.needsLogin {
                            TinyChip(text: "匿名可用", tint: Aurora.success)
                        } else if account != nil {
                            TinyChip(text: "已登录", tint: Aurora.success)
                        } else {
                            TinyChip(text: "需登录", tint: Aurora.warning)
                        }
                    }
                    Text(account?.subtitle ?? platform.loginBenefit)
                        .font(.system(size: 11))
                        .foregroundStyle(Aurora.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if platform.needsLogin {
                    if account == nil {
                        SmallTonalButton(text: "设置", systemIcon: "person.badge.key") {
                            sheet = .video(platform)
                        }
                    } else {
                        Button {
                            sheet = .video(platform)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Aurora.inkSoft)
                                .frame(width: 34, height: 34)
                                .background(GlassSurface(shape: Circle(), shadowRadius: 6, highlight: 0.3))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: 备份

    private var backupCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    PlatformIcon(systemIcon: "lock.shield", tint: Aurora.teal, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("认证备份")
                            .font(AuroraFont.labelLarge)
                            .foregroundStyle(Aurora.ink)
                        Text("用口令派生密钥，AES-GCM 加密导出 Cookie")
                            .font(.system(size: 11))
                            .foregroundStyle(Aurora.muted)
                    }
                    Spacer(minLength: 0)
                    SmallTonalButton(text: "管理", systemIcon: "arrow.left.arrow.right") {
                        showBackup = true
                    }
                }
                Text("备份文件里是**明文凭证**的密文副本：口令丢了就解不开，官方也帮不了你。")
                    .font(.system(size: 11))
                    .foregroundStyle(Aurora.muted)
            }
        }
    }

    private var disclaimer: some View {
        Text("凭证只保存在本机（钥匙串密钥 + AES-GCM），不会上传到任何服务器。退出登录会立即删除对应记录。")
            .font(.system(size: 11))
            .foregroundStyle(Aurora.muted)
            .padding(.horizontal, 6)
            .padding(.top, 8)
    }
}

// MARK: - 账号流程（一个 sheet 走完）

/// 一个 sheet 内部切换三步：选方式 → 网页登录 / 手动 Cookie。
/// 这样避免「sheet 里再弹 sheet」在 iOS 16 上的层级问题。
struct AccountFlowSheet: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let target: AccountTarget

    private enum Step {
        case method
        case web
        case manual
    }

    @State private var step: Step = .method
    @State private var cookieInput: String = ""
    @State private var nicknameInput: String = ""
    @State private var working = false

    private var existingAccount: Account? {
        switch target {
        case .pan(let platform): return model.accounts.primaryPanAccount(platform)
        case .video(let platform): return model.accounts.primaryVideoAccount(platform)
        }
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()
            switch step {
            case .method:
                methodList
            case .web:
                webLogin
            case .manual:
                manualForm
            }
            if working {
                BlockingLoading(text: "校验登录态…")
            }
        }
    }

    // MARK: 方式选择

    private var methodList: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                PlatformIcon(systemIcon: target.systemIcon, tint: target.tint, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.title)
                        .font(AuroraFont.titleLarge)
                        .foregroundStyle(Aurora.ink)
                    Text(target.benefit)
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                GlassIconButton(systemIcon: "xmark", tint: Aurora.inkSoft, diameter: 30, iconSize: 12) {
                    dismiss()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: AuroraMetrics.cardSpacing) {
                    if target.loginURL != nil && !target.manualCookieOnly {
                        methodRow(
                            icon: "safari",
                            title: "网页登录",
                            subtitle: "在内置浏览器里登录，自动抓取 Cookie"
                        ) {
                            step = .web
                        }
                    }
                    methodRow(
                        icon: "doc.on.clipboard",
                        title: "手动粘贴 Cookie",
                        subtitle: target.manualCookieOnly
                            ? "该平台不支持内置网页登录，请从浏览器复制 Cookie"
                            : "已经能拿到 Cookie 的话，直接粘贴更快"
                    ) {
                        step = .manual
                    }
                    if existingAccount != nil {
                        methodRow(
                            icon: "rectangle.portrait.and.arrow.right",
                            title: "退出登录",
                            subtitle: "删除这条账号记录（不影响其他平台）",
                            danger: true
                        ) {
                            if let account = existingAccount {
                                model.accounts.remove(account)
                                // 网盘页可能正停在这个平台的目录里，账号没了必须让它重来
                                model.drive.invalidate()
                                model.show("已退出 \(target.title)", .info)
                            }
                            dismiss()
                        }
                    }
                    noteCard
                }
                .padding(.horizontal, AuroraMetrics.pagePadding)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func methodRow(
        icon: String,
        title: String,
        subtitle: String,
        danger: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                PlatformIcon(systemIcon: icon, tint: danger ? Aurora.rose : target.tint, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AuroraFont.labelLarge)
                        .foregroundStyle(danger ? Aurora.rose : Aurora.ink)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Aurora.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Aurora.outline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(AuroraShape.control.fill(Color.white))
            .overlay(AuroraShape.control.stroke(Aurora.line.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle(scale: 0.99))
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("关于凭证安全")
                .font(AuroraFont.labelMedium)
                .foregroundStyle(Aurora.inkSoft)
            Text("Cookie 只会用于向对应平台发起请求；存储时用钥匙串里的设备密钥做 AES-GCM 加密，App 卸载即失效。")
                .font(.system(size: 11))
                .foregroundStyle(Aurora.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }

    // MARK: 网页登录

    @ViewBuilder
    private var webLogin: some View {
        if let url = target.loginURL {
            WebLoginScreen(
                title: "登录 " + target.title,
                urlString: url,
                cookieDomain: target.cookieDomain,
                viewportWidth: target.viewportWidth
            ) { cookie, nickname in
                save(cookie: cookie, nickname: nickname, method: .webLogin)
            }
        } else {
            manualForm
        }
    }

    // MARK: 手动 Cookie

    private var manualForm: some View {
        VStack(spacing: 0) {
            HStack {
                Text("粘贴 Cookie")
                    .font(AuroraFont.titleLarge)
                    .foregroundStyle(Aurora.ink)
                Spacer()
                TextLinkButton(text: "返回") { step = .method }
                GlassIconButton(systemIcon: "xmark", tint: Aurora.inkSoft, diameter: 30, iconSize: 12) {
                    dismiss()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: AuroraMetrics.cardSpacing) {
                    SectionCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("在电脑浏览器登录 \(target.title)，打开开发者工具 → Network → 任意请求 → 复制 Request Headers 里的 Cookie 整行。")
                                .font(AuroraFont.bodySmall)
                                .foregroundStyle(Aurora.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                            MultiLineInput(
                                text: $cookieInput,
                                placeholder: "name1=value1; name2=value2; …",
                                minHeight: 110
                            )
                            AuroraTextField(
                                placeholder: "昵称（可选，便于区分多账号）",
                                text: $nicknameInput,
                                systemIcon: "person"
                            )
                        }
                    }

                    GradientButton(text: "保存并校验", systemIcon: "checkmark.shield", enabled: !cookieInput.isEmpty) {
                        save(cookie: cookieInput, nickname: nicknameInput, method: .manualCookie)
                    }

                    Text("校验会向平台问一次「我是谁」：Cookie 无效时不会保存，避免留下一条永远解析失败的账号。")
                        .font(.system(size: 11))
                        .foregroundStyle(Aurora.muted)
                        .padding(.horizontal, 6)
                }
                .padding(.horizontal, AuroraMetrics.pagePadding)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: 保存

    private func save(cookie: String, nickname: String, method: AccountMethod) {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        working = true
        Task {
            defer { working = false }
            switch target {
            case .pan(let platform):
                model.accounts.savePanAccount(
                    platform: platform,
                    credential: trimmed,
                    nickname: nickname.isEmpty ? "网页登录" : nickname,
                    method: method
                )
                // 新登录的网盘要能被网盘页立刻用上
                model.drive.invalidate()
                model.show("已保存 \(platform.displayName) 账号", .success)
                dismiss()
            case .video(let platform):
                let resolvedName = await VideoResolveService.validateCookie(trimmed, for: platform)
                guard let resolvedName else {
                    model.show("Cookie 校验失败：可能没登录成功或已过期", .error)
                    return
                }
                model.accounts.saveVideoAccount(
                    platform: platform,
                    cookie: trimmed,
                    nickname: resolvedName.isEmpty ? (nickname.isEmpty ? "已登录" : nickname) : resolvedName,
                    method: method
                )
                model.show("已保存 \(platform.displayName) 账号", .success)
                dismiss()
            }
        }
    }
}

// MARK: - 备份

struct BackupSheet: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var passphrase = ""
    @State private var showImporter = false
    @State private var showShare = false
    @State private var exportedURL: URL?
    @State private var working = false
    @State private var message: String?

    var body: some View {
        SheetScaffold(title: "认证备份", subtitle: "AES-GCM 加密，口令丢了无法恢复") {
            SectionCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("设置一个口令（至少 6 位）")
                        .font(AuroraFont.labelLarge)
                        .foregroundStyle(Aurora.ink)
                    AuroraTextField(
                        placeholder: "备份口令",
                        text: $passphrase,
                        systemIcon: "key.fill",
                        isSecure: true
                    )
                    Text("导出文件格式：YNXBK1 + salt + AES-GCM 密文；导入时可跨设备恢复全部账号。")
                        .font(.system(size: 11))
                        .foregroundStyle(Aurora.muted)
                }
            }

            HStack(spacing: 10) {
                SmallTonalButton(text: "导出备份", systemIcon: "square.and.arrow.up", enabled: passphrase.count >= 6) {
                    exportBackup()
                }
                SmallTonalButton(text: "导入备份", systemIcon: "square.and.arrow.down", enabled: passphrase.count >= 6) {
                    showImporter = true
                }
            }

            if let message {
                Text(message)
                    .font(AuroraFont.bodySmall)
                    .foregroundStyle(Aurora.inkSoft)
                    .padding(.horizontal, 6)
            }

            Text("已保存 \(model.accounts.accounts.count) 个账号")
                .font(.system(size: 11))
                .foregroundStyle(Aurora.muted)
                .padding(.horizontal, 6)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            importBackup(result)
        }
        .sheet(isPresented: $showShare) {
            if let exportedURL {
                ActivityView(items: [exportedURL])
            }
        }
    }

    private func exportBackup() {
        working = true
        do {
            let url = try model.accounts.exportBackup(passphrase: passphrase)
            exportedURL = url
            message = "已导出：\(url.lastPathComponent)"
            showShare = true
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
        working = false
    }

    private func importBackup(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let count = try model.accounts.importBackup(from: url, passphrase: passphrase)
            message = "已导入 \(count) 个账号"
            model.show("导入完成", .success)
        } catch {
            message = "导入失败：\(error.localizedDescription)"
            model.show("导入失败", .error)
        }
    }
}
