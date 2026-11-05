import SwiftUI
import GogakuCore

/// 普通输入页（2026-11-03 定稿，对应原型 panels）：输入方案（纵向单选＋模糊音
/// 三列九项 checkbox）、候选窗与输入区（12–16 整数滑块带刻度、左标签右控件行、
/// 「显示英文释义／显示输入的字母」开关、「展开全拼／原始编码」分段控件）、
/// 英文候选与调频、按应用默认英文。
/// 所有改动立即提交（连续文本输入合并 300ms）。
struct NormalInputPage: View {
    @Binding var settings: GogakuCore.Settings
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
                            .frame(width: 150)
                            .accessibilityLabel("候选字号")
                            .accessibilityValue("\(settings.candidateFontSize) 号")
                        fontTicks
                    }
                }
                SettingsRowDivider()
                // 英文释义（用户裁决：显示名「显示英文释义」＋帮助文案）。
                SettingsRow("显示英文释义",
                            detail: "候选词的英文词义参考，不随中文上屏") {
                    Toggle("", isOn: binding(\.glossEnabled))
                        .toggleStyle(.switch)
                        .accessibilityLabel("显示英文释义")
                }
                SettingsRowDivider()
                SettingsRow("在宿主正文显示输入的字母（下划线）") {
                    Toggle("", isOn: binding(\.inputLettersEnabled))
                        .toggleStyle(.switch)
                        .accessibilityLabel("在宿主正文显示输入的字母")
                }
                SettingsRowDivider()
                // 显示内容：分段控件（.seg 两段）。
                SettingsRow("显示内容") {
                    Picker("显示内容", selection: binding(\.fullPinyinPreedit)) {
                        Text("展开全拼").tag(true)
                        Text("原始编码").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .accessibilityLabel("输入区字母显示内容")
                }
            }
        }
    }

    /// 刻度（.ticks：与滑块同宽 150、两端对齐、10px；当前值强调色加粗、可点选）。
    private var fontTicks: some View {
        HStack {
            ForEach([12, 13, 14, 15, 16], id: \.self) { size in
                Text(String(size))
                    .font(.system(size: 10, weight: size == settings.candidateFontSize ? .semibold : .regular))
                    .foregroundStyle(size == settings.candidateFontSize
                                     ? SettingsPalette.accentText : SettingsPalette.tertiaryText)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if settings.candidateFontSize != size {
                            settings.candidateFontSize = size
                            submit()
                        }
                    }
                    .accessibilityLabel("候选字号 \(size) 号")
            }
        }
        .frame(width: 150)
        .accessibilityElement(children: .contain)
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

    private func binding<T: Equatable>(_ keyPath: WritableKeyPath<GogakuCore.Settings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: keyPath] },
                set: { newValue in
                    settings[keyPath: keyPath] = newValue
                    submit()
                })
    }
}
