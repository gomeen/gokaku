import SwiftUI
import GogakuKit

/// 首次打开设置时的一次性「选择你的使用模式」（2026-11-18，完整版内 Lite 模式）。
///
/// 只有完整版有这个概念：GOGAKU_LITE 构建没有学习代码，不显示引导、不加开关。
/// 选择结果写进 `Settings.liteModeEnabled`，`modeOnboardingCompleted` 置真后不再
/// 出现；未选择就关窗不落盘，下次打开仍显示。
enum ModeOnboarding {
    /// 两种使用模式（完整／Lite 观感）。
    enum Choice: String, CaseIterable, Sendable {
        case full
        case lite

        var title: String {
            switch self {
            case .full: return "完整模式"
            case .lite: return "Lite 模式"
            }
        }

        var tag: String {
            switch self {
            case .full: return "全部功能"
            case .lite: return "轻量输入"
            }
        }

        var summary: String {
            switch self {
            case .full:
                return "面向语言学习者：日常输入之外，用学习模式在中英互译中练习。"
            case .lite:
                return "面向纯输入场景：更简洁的设置与更安静的系统行为（与 Gogaku Lite 独立安装包同观感）。"
            }
        }

        /// 差异点文案。Lite 列出的都是本实现真实生效的行为：不改候选窗排列与渲染的
        /// 用户设置，也不改动任何已存数据。
        var details: [String] {
            switch self {
            case .full:
                return ["普通输入＋英文候选与释义",
                        "学习模式（中→英／英→中，需配火山翻译）",
                        "学习片段记录、拼写波浪线",
                        "设置全量页面（八页）显示"]
            case .lite:
                return ["普通输入＋英文候选（无释义注释）",
                        "无学习模式、无学习快捷键",
                        "设置四个功能页＋关于：普通输入／自定义词语／皮肤／快捷键",
                        "候选窗排列与渲染照常可在设置里调整"]
            }
        }

        /// 该模式下实际生效的释义开关（只影响生效值，不覆写用户存的 glossEnabled）。
        var glossEnabledEffective: Bool { self == .full }
    }

    /// 本构建是否提供该引导（只有完整版有）。
    static var isSupported: Bool {
        #if GOGAKU_LITE
        return false
        #else
        return true
        #endif
    }

    /// 是否应该显示引导：本构建支持且用户还没做过选择。
    static func shouldShow(for settings: GogakuKit.Settings) -> Bool {
        isSupported && !settings.modeOnboardingCompleted
    }

    /// 记录选择：写入模式并把引导标记为已完成。`glossEnabled` 存储值不动——
    /// Lite 下只把生效值强制为关闭，切回完整模式即恢复用户此前的选择。
    static func apply(_ choice: Choice, to settings: inout GogakuKit.Settings) {
        settings.liteModeEnabled = choice == .lite
        settings.modeOnboardingCompleted = true
    }
}

/// 引导页（对应原型场景 1）：200pt 侧栏之外铺满设置窗口，浅深外观都走 palette。
struct ModeOnboardingView: View {
    @Binding var settings: GogakuKit.Settings
    @State private var selection: ModeOnboarding.Choice = .full
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("初次设置")
                .font(.system(size: 10.5, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(SettingsPalette.tertiaryText)
            Text("选择你的使用模式")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(SettingsPalette.primaryText)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            Text("这决定了设置页显示哪些功能、学习入口与释义是否出现。之后随时可以在设置侧栏底部切换，你的所有数据都会保留。")
                .font(.system(size: 13))
                .foregroundStyle(SettingsPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.bottom, 26)
            modeCards
            if selection == .lite { liteNote }
            HStack {
                Spacer(minLength: 0)
                Button(selection == .lite ? "使用 Lite 模式" : "使用完整模式", action: confirm)
                    .font(.system(size: 12.5, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(SettingsPalette.accent)
                    .controlSize(.regular)
                    .accessibilityLabel(selection == .lite ? "使用 Lite 模式" : "使用完整模式")
            }
            .padding(.top, 26)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 56)
        .padding(.top, 44)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsPalette.cardBackground)
    }

    /// 两张并排卡片（原型 `.modes`：1fr 1fr、gap 14）。
    private var modeCards: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(ModeOnboarding.Choice.allCases, id: \.self) { choice in
                card(choice)
            }
        }
    }

    private func card(_ choice: ModeOnboarding.Choice) -> some View {
        let selected = selection == choice
        return Button {
            selection = choice
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(choice.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SettingsPalette.primaryText)
                    Text(choice.tag)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SettingsPalette.accentText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(SettingsPalette.accentSoft))
                }
                .padding(.bottom, 2)
                Text(choice.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(choice.details, id: \.self) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text("·").font(.system(size: 11.5))
                            Text(line)
                                .font(.system(size: 11.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(SettingsPalette.tertiaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(selected ? SettingsPalette.cardBackground : SettingsPalette.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? SettingsPalette.accent : SettingsPalette.borderStrong,
                              lineWidth: 1.5))
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 15)
                .fill(selected ? SettingsPalette.accentSoft : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityLabel("\(choice.title)，\(choice.tag)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityHint(choice.summary)
    }

    /// 选 Lite 时的说明条（原型 `.callout`）。只讲显示与入口，不宣称删数据。
    private var liteNote: some View {
        Text("已选 Lite 模式：英文释义关闭，学习相关页面与快捷键不显示。这只影响显示与入口，不删除任何数据；随时可切回。")
            .font(.system(size: 11.5))
            .foregroundStyle(SettingsPalette.warningText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(SettingsPalette.warningBackground))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(SettingsPalette.warningBorder, lineWidth: 1))
            .padding(.top, 12)
            .accessibilityLabel("已选 Lite 模式：英文释义关闭，学习相关页面与快捷键不显示；数据保留，随时可切回")
    }

    private func confirm() {
        ModeOnboarding.apply(selection, to: &settings)
        onConfirm()
    }
}
