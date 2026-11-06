import SwiftUI

// === Aurora UI 按钮（iOS / SwiftUI）===
//
// 视觉规范（用户指定）：**所有按钮都是无色透明玻璃**。
//   · 底色：`GlassSurface`（材质 + 白高光 + 描边），不带任何品牌色
//   · 文字/图标：主色用 `Aurora.ink`，危险操作用 `Aurora.rose`，链接用 `Aurora.brand`
//   · 层级靠「文字颜色 + 尺寸」区分，不靠色块 —— 所以不要再往按钮里填实色
//
// 硬规则：按钮文字必须居中 —— 统一用 Button + 居中的 label，
// 不要自己拼 HStack 挤文案。

/// 按钮文字：图标 + 文案，整体水平垂直居中。
///
/// - `expands`: 是否撑满父容器宽度。
///   主按钮（底部操作条里成对出现的那种）用 `true`；
///   列表行里的小按钮用 `false`，否则会抢掉整行的空间。
struct AuroraButtonLabel: View {

    let text: String
    var systemIcon: String? = nil
    var height: CGFloat = AuroraMetrics.primaryButtonHeight
    var font: Font = AuroraFont.labelLarge
    var expands: Bool = true

    var body: some View {
        content
            .frame(maxWidth: expands ? .infinity : nil)
            .frame(height: height)
    }

    private var content: some View {
        HStack(spacing: 6) {
            if let systemIcon {
                Image(systemName: systemIcon)
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(text)
                .font(font)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .fixedSize(horizontal: !expands, vertical: false)
    }
}

/// 主按钮：玻璃底 + 深墨字。禁用时整体降透明度。
struct PrimaryButton: View {

    let text: String
    var systemIcon: String? = nil
    var enabled: Bool = true
    var expands: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AuroraButtonLabel(
                text: text,
                systemIcon: systemIcon,
                expands: expands
            )
            .foregroundStyle(Aurora.ink)
            .background(GlassSurface(shape: AuroraShape.button))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 次按钮：玻璃底 + 深墨字（和主按钮同底，只靠字重/图标区分层级）。
struct TonalButton: View {

    let text: String
    var systemIcon: String? = nil
    var enabled: Bool = true
    var expands: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AuroraButtonLabel(
                text: text,
                systemIcon: systemIcon,
                expands: expands
            )
            .foregroundStyle(Aurora.ink)
            .background(GlassSurface(shape: AuroraShape.button, shadowRadius: 8, highlight: 0.26))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 主 CTA：现在也是玻璃底（不再用品牌渐变）。
///
/// 保留这个类型名是为了不改调用点；视觉上它和 `PrimaryButton`
/// 的区别只剩「图标更大一点、字重更实」。
struct GradientButton: View {

    let text: String
    var systemIcon: String? = nil
    var enabled: Bool = true
    var expands: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AuroraButtonLabel(
                text: text,
                systemIcon: systemIcon,
                expands: expands
            )
            .foregroundStyle(Aurora.brand)
            .background(GlassSurface(shape: AuroraShape.button, highlight: 0.40))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// 小按钮（38pt 高，14pt 圆角），玻璃底。
struct SmallTonalButton: View {

    let text: String
    var systemIcon: String? = nil
    var enabled: Bool = true
    var expands: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AuroraButtonLabel(
                text: text,
                systemIcon: systemIcon,
                height: AuroraMetrics.smallButtonHeight,
                font: AuroraFont.labelMedium,
                expands: expands
            )
            .padding(.horizontal, expands ? 0 : 4)
            .foregroundStyle(Aurora.ink)
            .background(GlassSurface(shape: AuroraShape.control, shadowRadius: 6, highlight: 0.28))
        }
        .buttonStyle(PressScaleStyle(scale: 0.96))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 危险操作按钮：玻璃底 + 玫瑰色文字（只染字，不染底）。
struct DangerTonalButton: View {

    let text: String
    var systemIcon: String? = nil
    var enabled: Bool = true
    var expands: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AuroraButtonLabel(
                text: text,
                systemIcon: systemIcon,
                height: AuroraMetrics.smallButtonHeight,
                font: AuroraFont.labelMedium,
                expands: expands
            )
            .padding(.horizontal, expands ? 0 : 4)
            .foregroundStyle(Aurora.rose)
            .background(GlassSurface(shape: AuroraShape.control, shadowRadius: 6, highlight: 0.28))
        }
        .buttonStyle(PressScaleStyle(scale: 0.96))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 文字按钮（对应 Material 的 TextButton）：没有底色，只有文字。
struct TextLinkButton: View {

    let text: String
    var systemIcon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(text)
                    .font(AuroraFont.labelMedium)
                    .lineLimit(1)
            }
            .foregroundStyle(Aurora.brand)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 图标玻璃按钮：圆形玻璃 + 单色图标（替代以前「彩色圆底 + 图标」的写法）。
struct GlassIconButton: View {

    let systemIcon: String
    var tint: Color = Aurora.ink
    var diameter: CGFloat = 34
    var iconSize: CGFloat = 13
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemIcon)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: diameter, height: diameter)
                .background(GlassSurface(shape: Circle(), shadowRadius: 8, highlight: 0.32))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.94))
    }
}
