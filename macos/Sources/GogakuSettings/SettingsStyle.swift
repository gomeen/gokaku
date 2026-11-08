import SwiftUI
import GogakuKit

/// 设置页共用样式（2026-11-03 定稿，逐项对应 prototypes/settings-final.html 已选视觉）：
/// 青绿主题浅／深双套 CSS 变量（--win-bg、--side-bg、--panel、--border、--hairline、
/// --fg／--fg-2／--fg-3、--accent 系、--danger、--ok 等）逐一落为动态颜色；
/// 平面卡片分组（panel：radius 9、标题 12.5/600、内边距 14）、左标签右控件行
/// （行高 44、垂直内边距 9、hairline 分隔）、快捷键键帽（kcap）与固定底部状态栏。
/// 不嵌入 HTML；系统控件（开关、分段、按钮）尺寸随系统，残余差异见验收说明。
private enum Appearance {
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// 按 HTML `html[data-theme="brand"]` 的浅／深两套变量生成的动态颜色。
private func paletteColor(light: (Double, Double, Double, Double),
                          dark: (Double, Double, Double, Double)) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: value.0 / 255.0, green: value.1 / 255.0, blue: value.2 / 255.0,
                       alpha: value.3)
    })
}

// MARK: - 设计 token（settings-final.html brand 主题）

enum SettingsPalette {
    /// --win-bg：窗口内容区与状态栏底色。
    static let windowBackground = paletteColor(
        light: (245, 248, 246, 1), dark: (24, 33, 28, 1))
    /// --side-bg：侧栏底色（与内容区有层次差）。
    static let sidebarBackground = paletteColor(
        light: (237, 243, 239, 1), dark: (20, 28, 23, 1))
    /// --panel：卡片背景。
    static let cardBackground = paletteColor(
        light: (255, 255, 255, 1), dark: (31, 42, 36, 1))
    /// --border：卡片描边。
    static let border = paletteColor(
        light: (216, 227, 220, 1), dark: (46, 61, 53, 1))
    /// --border-strong：输入控件描边。
    static let borderStrong = paletteColor(
        light: (194, 210, 201, 1), dark: (60, 79, 69, 1))
    /// --hairline：行分隔线。
    static let hairline = paletteColor(
        light: (232, 240, 234, 1), dark: (38, 49, 41, 1))
    /// --fg：正文。
    static let primaryText = paletteColor(
        light: (28, 43, 37, 1), dark: (237, 244, 240, 1))
    /// --fg-2：次级文字。
    static let secondaryText = paletteColor(
        light: (91, 111, 102, 1), dark: (167, 184, 175, 1))
    /// --fg-3：第三级文字。
    static let tertiaryText = paletteColor(
        light: (125, 143, 134, 1), dark: (127, 145, 136, 1))

    /// --accent。
    static let accent = paletteColor(
        light: (18, 153, 106, 1), dark: (52, 196, 140, 1))
    /// --accent-fg：强调色上的文字。
    static let accentForeground = paletteColor(
        light: (255, 255, 255, 1), dark: (8, 21, 15, 1))
    /// --accent-text：强调语境文字（选中导航、可点刻度）。
    static let accentText = paletteColor(
        light: (13, 122, 83, 1), dark: (90, 217, 164, 1))
    /// --accent-soft：选中态背景。
    static let accentSoft = paletteColor(
        light: (18, 153, 106, 0.12), dark: (52, 196, 140, 0.16))
    /// --accent-ring：焦点环。
    static let accentRing = paletteColor(
        light: (18, 153, 106, 0.25), dark: (52, 196, 140, 0.28))
    /// --tag-bg：键帽（kbd）与提示条底色。
    static let tagBackground = paletteColor(
        light: (237, 244, 240, 1), dark: (34, 48, 42, 1))
    /// --btn-hover：次级按钮悬停底色。
    static let buttonHover = paletteColor(
        light: (238, 245, 241, 1), dark: (38, 51, 44, 1))
    /// --danger。
    static let danger = paletteColor(
        light: (179, 38, 30, 1), dark: (255, 107, 94, 1))
    /// --danger-soft。
    static let dangerSoft = paletteColor(
        light: (179, 38, 30, 0.08), dark: (255, 107, 94, 0.12))
    /// --ok：状态栏「已保存」圆点。
    static let ok = paletteColor(
        light: (31, 138, 76, 1), dark: (76, 196, 127, 1))

    /// 卡片圆角（--panel radius 9）。
    static let cardCornerRadius: CGFloat = 9
    /// 快捷键表格键帽列宽（.kskb width 210px）。
    static let keyColumnWidth: CGFloat = 210
    /// 快捷键表格来源列宽（.kssrc width 90px）。
    static let sourceColumnWidth: CGFloat = 90
    /// 快捷键表格操作列宽（.ksact width 104px）。
    static let actionColumnWidth: CGFloat = 104
}

// MARK: - 分组 section（内容区平铺：标题、间距、分割）

/// 分组 section：无卡片背景与圆角，标题＋内容＋底部 hairline 分割
/// （用户裁决 2026-11-02：内容区不需要圆角卡片背景）。
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // .panel__title：12.5/600；平铺后与页面 26pt 内边距对齐。
            Text(title).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(SettingsPalette.primaryText)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 10)
            content
            // section 之间的分割线（内容末尾）。
            Rectangle()
                .fill(SettingsPalette.hairline)
                .frame(height: 1)
                .padding(.top, 16)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 卡片之间的间距（.panel + .panel { margin-top: 18px }）。
struct SettingsCardSpacing: View {
    var body: some View {
        Color.clear.frame(height: 18)
    }
}

/// 页面 section 之间的分隔线（.hr：hairline，上下留白 18）。
struct SettingsRule: View {
    var body: some View {
        Rectangle()
            .fill(SettingsPalette.hairline)
            .frame(height: 1)
            .padding(.vertical, 18)
            .accessibilityHidden(true)
    }
}

/// 行与行之间的 hairline 分隔（.row + .row { border-top: hairline }）。
struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsPalette.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - 设置行（row）

/// 左标签（含可选说明）右控件的设置行（.row：最小高 44、垂直内边距 9、间距 16）。
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String = ""
    let control: Control
    init(_ title: String, detail: String = "", @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                // .row__label：13px，行高 1.45。
                Text(title).font(.system(size: 13))
                    .foregroundStyle(SettingsPalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty {
                    // .row__detail：11px 次级色。
                    Text(detail).font(.system(size: 11))
                        .foregroundStyle(SettingsPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // .row__control：右对齐。
            control
        }
        .padding(.vertical, 9)
        .frame(minHeight: 44)
    }
}

// MARK: - 键帽（kbd / kcap）

/// 快捷键键帽（.kcap：高 24、最小宽 24、radius 6、border-strong 描边、win-bg 底）。
struct SettingsKeycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12))
            .foregroundStyle(SettingsPalette.primaryText)
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 24)
            .background(SettingsPalette.windowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(SettingsPalette.borderStrong, lineWidth: 1))
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - 搜索框

/// 搜索框（.kssearch／.search：radius 7、描边、放大镜前缀、可清除）。
struct SettingsSearchField: View {
    @Binding var text: String
    let placeholder: String
    var accessibilityName: String
    /// 底色：快捷键页在白卡片上用窗口底色（--win-bg），弹层内用卡片色。
    var background: Color = SettingsPalette.cardBackground

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11))
                .foregroundStyle(SettingsPalette.tertiaryText)
            TextField(placeholder, text: $text).textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(SettingsPalette.primaryText)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(SettingsPalette.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 30)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(SettingsPalette.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityName)
    }
}

// MARK: - 底部状态栏状态

/// 底部状态栏状态。
enum SaveStatus: Equatable {
    case idle
    case saving
    case saved
    case failed(String)

    init(storeStatus: GogakuKit.SettingsStore.Status) {
        switch storeStatus {
        case .idle: self = .idle
        case .saving: self = .saving
        case .saved: self = .saved
        case .failed(let reason): self = .failed(reason)
        }
    }

    var text: String {
        switch self {
        case .idle: return ""
        case .saving: return "正在保存…"
        case .saved: return "已保存"
        case .failed: return "保存失败：目录不可写或权限不足。改动已保留，可重试。"
        }
    }

    var dotColor: Color {
        switch self {
        case .idle: return SettingsPalette.tertiaryText
        case .saving: return Color(nsColor: .systemOrange)
        case .saved: return SettingsPalette.ok
        case .failed: return SettingsPalette.danger
        }
    }
}
