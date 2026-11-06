import SwiftUI

// === Aurora UI 按钮（iOS / SwiftUI）===
//
// 视觉规范（用户指定）：
//   · **所有按钮都是无色透明玻璃**。底色统一 `GlassSurface`（材质 + 白高光 + 描边），
//     不填品牌色；层级靠「文字颜色 + 尺寸」区分。
//   · 文字/图标：常规用 `Aurora.ink`，危险操作用 `Aurora.rose`，纯链接用 `Aurora.brand`。
//   · **同一条操作条里的按钮必须同高同款**（不许 50pt 主按钮挨着 38pt 小按钮），
//     统一用 `SmallTonalButton`；整行 CTA 才用 `PrimaryButton` / `GradientButton`。
//
// 尺寸规范（用户要求「文字跟按钮边距要合理」）：
//   · 小胶囊按钮：高 38、左右内边距 16、图标 14、图标与文字间距 7、文字 13 semibold
//   · 整行按钮：  高 50、左右不留额外内边距（撑满父容器）、图标 15、间距 7、文字 14 semibold
//
// 硬规则：按钮文字必须居中 —— 统一用 Button + 居中的 label，
// 不要自己拼 HStack 挤文案。

/// 按钮文字：图标 + 文案，整体水平垂直居中。
///
/// - `expands`: 是否撑满父容器宽度。
///   整行 CTA 用 `true`；列表行/操作条里的小按钮用 `false`。
/// - `horizontalPadding`: 不撑满时才生效的左右内边距，
///   保证文字不会贴到胶囊边缘（`AuroraMetrics.controlButtonHPadding`）。
struct AuroraButtonLabel: View {

    let text: String
    var systemIcon: String? = nil
    var height: CGFloat = AuroraMetrics.primaryButtonHeight
    var font: Font = AuroraFont.labelLarge
    var iconSize: CGFloat = 15
    var iconSpacing: CGFloat = 7
    var expands: Bool = true
    var horizontalPadding: CGFloat = 0

    var body: some View {
        HStack(spacing: iconSpacing) {
            if let systemIcon {
                Image(systemName: systemIcon)
                    .font(.system(size: iconSize, weight: .semibold))
            }
            Text(text)
                .font(font)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: expands ? .infinity : nil)
        .frame(height: height)
        .padding(.horizontal, expands ? 0 : horizontalPadding)
        .contentShape(Rectangle())
    }
}

/// 主按钮：玻璃底 + 深墨字，撑满一行。禁用时整体降透明度。
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
                expands: expands,
                horizontalPadding: AuroraMetrics.controlButtonHPadding
            )
            .foregroundStyle(Aurora.ink)
            .background(GlassSurface(shape: AuroraShape.button, highlight: 0.32))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 次按钮：和主按钮同底（只靠字重/图标区分层级），用于并排的整行按钮。
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
                expands: expands,
                horizontalPadding: AuroraMetrics.controlButtonHPadding
            )
            .foregroundStyle(Aurora.ink)
            .background(GlassSurface(shape: AuroraShape.button, shadowRadius: 8, highlight: 0.26))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 主 CTA：玻璃底 + 深墨字（不再用品牌色文字，也不再是渐变）。
///
/// 保留类型名是为了不改历史调用点；视觉上等同于 `PrimaryButton`，
/// 只把高光调亮一点，让它在弹窗里仍然是"最上面那一层"。
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
                expands: expands,
                horizontalPadding: AuroraMetrics.controlButtonHPadding
            )
            .foregroundStyle(Aurora.ink)
            .background(GlassSurface(shape: AuroraShape.button, highlight: 0.36))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 操作条里的小胶囊按钮（38pt 高，14pt 圆角）：**同一行按钮的默认款式**。
///
/// 左右各留 16pt 内边距，图标 14、图标与文字 7 —— 文字不会贴边，也不会显得空。
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
                height: AuroraMetrics.controlButtonHeight,
                font: AuroraFont.controlLabel,
                iconSize: AuroraMetrics.controlButtonIconSize,
                iconSpacing: AuroraMetrics.controlButtonIconSpacing,
                expands: expands,
                horizontalPadding: AuroraMetrics.controlButtonHPadding
            )
            .foregroundStyle(Aurora.ink)
            .background(GlassSurface(shape: AuroraShape.control, shadowRadius: 6, highlight: 0.28))
        }
        .buttonStyle(PressScaleStyle(scale: 0.96))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 危险操作按钮：和小胶囊同款，只把字染成玫瑰色（不染底）。
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
                height: AuroraMetrics.controlButtonHeight,
                font: AuroraFont.controlLabel,
                iconSize: AuroraMetrics.controlButtonIconSize,
                iconSpacing: AuroraMetrics.controlButtonIconSpacing,
                expands: expands,
                horizontalPadding: AuroraMetrics.controlButtonHPadding
            )
            .foregroundStyle(Aurora.rose)
            .background(GlassSurface(shape: AuroraShape.control, shadowRadius: 6, highlight: 0.28))
        }
        .buttonStyle(PressScaleStyle(scale: 0.96))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 文字按钮（对应 Material 的 TextButton）：没有底色，只有文字。
///
/// 只用于「忽略 / 关掉 / 展开」这类真正的弱操作，别拿它当次要按钮用 ——
/// 次要按钮一律 `SmallTonalButton`。
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
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
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
