import SwiftUI
import GogakuKit

/// 普通输入页（2026-11-03 定稿，对应原型 panels）：输入方案（纵向单选＋模糊音
/// 三列九项 checkbox）、候选窗与输入区（12–16 整数滑块带刻度、左标签右控件行、
/// 「显示英文释义／显示输入的字母」开关、「展开全拼／原始编码」分段控件）、
/// 英文候选与调频、按应用默认英文。
/// 所有改动立即提交（连续文本输入合并 300ms）。
struct NormalInputPage: View {
    /// 表单控件统一宽度（滑块／分段控件／刻度行共用，避免同一页里控件宽窄不一）。
    static let controlWidth: CGFloat = 220
    @Binding var settings: GogakuKit.Settings
    @State private var freqClearHint = ""
    @ObservedObject private var catalog = AppCatalog()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            schemeCard
            SettingsCardSpacing()
            fuzzyCard
            SettingsCardSpacing()
            candidateCard
            SettingsCardSpacing()
            englishCard
            SettingsCardSpacing()
            appDefaultsCard
            SettingsCardSpacing()
            if !freqClearHint.isEmpty {
                Text(freqClearHint)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondaryText)
                    .padding(.top, 10)
            }
        }
    }

    // MARK: 输入方案（纵向单选，独立一块）

    private var schemeCard: some View {
        SettingsCard("输入方案") {
            Picker("输入方案", selection: binding(\.inputScheme)) {
                Text("小鹤双拼（默认）").tag(InputScheme.xiaohe)
                Text("全拼").tag(InputScheme.fullPinyin)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()   // 区块标题已是「输入方案」，避免行标签重复
            // 原型 .radios 为纵向列表（radioGroup 默认纵向，每项 12px）。
            .font(.system(size: 12))
            .padding(.vertical, 2)
            .accessibilityLabel("输入方案")
        }
    }

    // MARK: 模糊音（三列九项 checkbox，独立一块）

    private var fuzzyCard: some View {
        SettingsCard("模糊音") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 3),
                      alignment: .leading, spacing: 9) {
                ForEach(InputScheme.fuzzyPairs, id: \.id) { pair in
                    Toggle(pair.id, isOn: Binding(
                        get: { settings.fuzzyPinyin.contains(pair.id) },
                        set: { on in
                            if on { settings.fuzzyPinyin.insert(pair.id) } else { settings.fuzzyPinyin.remove(pair.id) }
                            submit()
                        }))
                        .font(.system(size: 11, design: .monospaced))
                        .accessibilityLabel("模糊音 \(pair.id)")
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: 候选窗与输入区（左标签右控件行，行间 hairline）

    private var candidateCard: some View {
        SettingsCard("候选窗与输入区") {
            VStack(alignment: .leading, spacing: 0) {
                // 候选字号：12–16 整数滑块带刻度（原型 .range 宽 150＋两端刻度）。
                SettingsRow("候选字号") {
                    VStack(alignment: .leading, spacing: 1) {
                        Slider(value: Binding(
                            get: { Double(settings.candidateFontSize) },
                            set: { value in
                                let clamped = min(16, max(12, Int(value.rounded())))
                                if clamped != settings.candidateFontSize {
                                    settings.candidateFontSize = clamped
                                    submit()
                                }
                            }), in: 12...16, step: 1)
                            .frame(width: Self.controlWidth)
                            .accessibilityLabel("候选字号")
                            .accessibilityValue("\(settings.candidateFontSize) 号")
                        fontTicks
                    }
                }
                SettingsRowDivider()
                SettingsRow("候选窗排列") {
                    // 用户裁决（2026-11-16）：与「显示内容」同款左右 tab。
                    // 不用 `.pickerStyle(.segmented)`：该样式在本机点击后不触发
                    // binding（设置不落盘，用户看到「切横排又弹回竖排」），改用
                    // 自绘分段控件，点击直接 submit()。
                    SegmentedChoice(
                        options: [(.vertical, "竖排"), (.horizontal, "横排")],
                        selection: settings.candidateLayout,
                        width: Self.controlWidth) { value in
                            guard settings.candidateLayout != value else { return }
                            settings.candidateLayout = value
                            submit()
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("候选窗排列")
                }
                SettingsRowDivider()
                SettingsRow("渲染引擎") {
                    SegmentedChoice(
                        options: [(.bitmap, "自绘"), (.system, "系统")],
                        selection: settings.candidateRenderer,
                        width: Self.controlWidth) { value in
                            guard settings.candidateRenderer != value else { return }
                            settings.candidateRenderer = value
                            submit()
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("渲染引擎")
                }
                if settings.candidateLayout == .horizontal {
                    SettingsRowDivider()
                    SettingsRow("横排每页数量") {
                        VStack(alignment: .leading, spacing: 1) {
                            Slider(value: Binding(
                                get: { Double(settings.horizontalPageSize) },
                                set: { value in
                                    let clamped = min(9, max(4, Int(value.rounded())))
                                    if clamped != settings.horizontalPageSize {
                                        settings.horizontalPageSize = clamped
                                        submit()
                                    }
                                }), in: 4...9, step: 1)
                            // 滑轨两端各让出滑块半径（macOS 分段滑块约 10pt），
                            // 刻度按同一有效宽度等分，才不会出现「9 之后还有一格」。
                            .frame(width: Self.controlWidth)
                            .accessibilityLabel("横排每页数量")
                            SliderTicks(values: Array(4...9), current: settings.horizontalPageSize) { n in
                                if settings.horizontalPageSize != n {
                                    settings.horizontalPageSize = n
                                    submit()
                                }
                            }
                            .accessibilityLabel("横排每页数量刻度")
                        }
                    }
                }
                SettingsRowDivider()
                // 英文释义（用户裁决：显示名「显示英文释义」＋帮助文案；Lite 无释义数据）。
                // 完整版内 Lite 模式：行仍在，但置灰关闭并注明原因（生效值强制 false，
                // 存储的 glossEnabled 不覆写，切回完整后恢复）。
                #if !GOGAKU_LITE
                SettingsRow("显示英文释义",
                            detail: settings.liteModeEnabled
                                ? "Lite 模式下不可用 · 切回完整后恢复"
                                : "候选词的英文词义参考，不随中文上屏") {
                    Toggle("", isOn: settings.liteModeEnabled ? .constant(false) : binding(\.glossEnabled))
                        .toggleStyle(.switch)
                        .disabled(settings.liteModeEnabled)
                        .accessibilityLabel(settings.liteModeEnabled
                                            ? "显示英文释义，Lite 模式下不可用"
                                            : "显示英文释义")
                }
                // 原型 .row--off：不可用行整行变淡（只影响显示，不影响点击目标外的行为）。
                .opacity(settings.liteModeEnabled ? 0.45 : 1)
                SettingsRowDivider()
                #endif
                SettingsRow("在宿主正文显示输入的字母（下划线）") {
                    Toggle("", isOn: binding(\.inputLettersEnabled))
                        .toggleStyle(.switch)
                        .accessibilityLabel("在宿主正文显示输入的字母")
                }
                SettingsRowDivider()
                // 显示内容：分段控件。必须与「候选窗排列」同一个自绘控件：
                // 系统 `.segmented` 忽略外层 `.frame(width:)`，实测宽度只有 146
                // 而自绘控件是 220，同一页上两个分段控件长短不一（2026-11-16
                // 用户报「同样的组件大小不一样」）。
                SettingsRow("显示内容") {
                    SegmentedChoice(
                        options: [(true, "展开全拼"), (false, "原始编码")],
                        selection: settings.fullPinyinPreedit,
                        width: Self.controlWidth) { value in
                            guard settings.fullPinyinPreedit != value else { return }
                            settings.fullPinyinPreedit = value
                            submit()
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("输入区字母显示内容")
                }
            }
        }
    }

    /// 刻度行：按滑块**实际行程**（两端各让出滑块半径）精确对位。
    /// 旧实现用等分 HStack，越靠两端偏差越大（用户实测「刻度和数字有偏移」）。
    private var fontTicks: some View {
        SliderTicks(values: Array(12...16), current: settings.candidateFontSize) { size in
            if settings.candidateFontSize != size {
                settings.candidateFontSize = size
                submit()
            }
        }
        .accessibilityLabel("候选字号刻度")
    }

    // MARK: 英文候选与调频

    private var englishCard: some View {
        SettingsCard("中文模式下的英文候选与调频") {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow("给英文候选（词表＋词频；SCOWL／wordfreq 数据包就绪后生效）") {
                    Toggle("", isOn: binding(\.englishCandidatesEnabled))
                        .toggleStyle(.switch)
                        .accessibilityLabel("给英文候选")
                }
                SettingsRowDivider()
                SettingsRow("本地中文调频（只学习普通模式完整上屏的中文）") {
                    Toggle("", isOn: binding(\.frequencyEnabled))
                        .toggleStyle(.switch)
                        .accessibilityLabel("本地中文调频")
                }
                SettingsRowDivider()
                // 清空操作行（无路径说明；反馈文案与原型一致）。
                // 2026-11 整改：删除失败不再伪报成功；成功后通知输入法清空运行中
                // 引擎的调频内存（org.gogaku.freqdata.cleared），旧数据不再写回。
                HStack {
                    Button("清空调频数据") {
                        let dir = Settings.chineseDirectory
                        do {
                            try FileManager.default.removeItem(at: dir)
                            DistributedNotificationCenter.default().postNotificationName(
                                SettingsStore.frequencyClearedNotification, object: nil, deliverImmediately: true)
                            freqClearHint = "已清空调频数据；自定义词语不受影响。"
                        } catch let error as NSError where error.code == 4 /* NSFileNoSuchFileError：目录本就不存在 */ {
                            freqClearHint = "调频数据本来为空；自定义词语不受影响。"
                        } catch {
                            freqClearHint = "清空失败：\(error.localizedDescription)"
                        }
                    }
                    .accessibilityLabel("清空调频数据，自定义词语不受影响")
                    Spacer()
                }
                .padding(.vertical, 9)
            }
        }
    }

    // MARK: 按应用默认英文（无引导文案；应用列表共用组件）

    private var appDefaultsCard: some View {
        SettingsCard("按应用默认英文") {
            AppListEditor(mode: .defaultEnglish(entries: Binding(
                get: { settings.appDefaultEnglish },
                set: { newValue in
                    settings.appDefaultEnglish = newValue
                    submit()
                })),
                emptyText: "尚未添加应用。添加后，这些应用切入时默认英文。",
                addSheetTitle: "添加应用",
                accessibilityPrefix: "默认英文",
                catalog: catalog)
            .padding(.vertical, 4)
        }
    }

    // MARK: 保存

    private func submit() {
        // 立即提交；保存状态由壳层的 SettingsStore.onStatus 统一驱动。
        SettingsStore.shared.submit(settings)
    }

    private func binding<T: Equatable>(_ keyPath: WritableKeyPath<GogakuKit.Settings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: keyPath] },
                set: { newValue in
                    settings[keyPath: keyPath] = newValue
                    submit()
                })
    }
}


/// 左右分段控件（外观对齐系统 segmented，「显示内容」同款）。
/// 自绘而非 `Picker(.segmented)`：后者在 macOS 26 上点击不触发 selection
/// binding，设置不落盘（2026-11-16 用户实测「切横排立刻弹回竖排」）。
private struct SegmentedChoice<Value: Equatable>: View {
    let options: [(Value, String)]
    let selection: Value
    var width: CGFloat = 220
    let choose: (Value) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button { choose(option.0) } label: {
                    Text(option.1)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : SettingsPalette.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected ? SettingsPalette.accent : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.1)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(SettingsPalette.secondaryText.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(SettingsPalette.border, lineWidth: 1))
    }
}


/// 滑块刻度行：每个数字的中心与滑块在该取值时的**旋钮中心**重合。
/// SwiftUI 的 `Slider` 行程不是满宽，两端各内缩约一个旋钮半径；等分布局
/// 会让刻度越往两端偏得越多（2026-11-16 用户报「刻度和数字有偏移」）。
private struct SliderTicks: View {
    let values: [Int]
    let current: Int
    var width: CGFloat = NormalInputPage.controlWidth
    /// 滑轨两端内缩量（实测：220pt 宽的 Slider 上系统刻度点在 10／210，
    /// 即内缩 10pt、间距 50pt；用 11 会让两端各偏 1–2px）。
    var knobInset: CGFloat = 10
    var onSelect: ((Int) -> Void)? = nil

    private var labelWidth: CGFloat { 22 }

    private func centerX(_ index: Int) -> CGFloat {
        guard values.count > 1 else { return width / 2 }
        let usable = max(width - knobInset * 2, 1)
        let step = usable / CGFloat(values.count - 1)
        return knobInset + step * CGFloat(index)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Text(String(value))
                    .font(.system(size: 10, weight: value == current ? .semibold : .regular))
                    .foregroundStyle(value == current ? SettingsPalette.accentText : SettingsPalette.tertiaryText)
                    .frame(width: labelWidth)
                    .offset(x: centerX(index) - labelWidth / 2)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect?(value) }
            }
        }
        .frame(width: width, height: 14, alignment: .topLeading)
    }
}
