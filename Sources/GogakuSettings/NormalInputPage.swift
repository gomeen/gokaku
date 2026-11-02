import SwiftUI
import GogakuCore

/// 普通输入页（2026-11-03 定稿）：字号 12–16 整数滑块带刻度、展开全拼／原始编码
/// 分段控件、模糊音三列九项（无计数／解释／批量操作）、按应用默认英文与快速添加
/// 排除共用应用列表组件。所有改动立即提交（连续文本输入合并 300ms）。
struct NormalInputPage: View {
    @Binding var settings: GogakuCore.Settings
    @State private var freqClearHint = ""
    @ObservedObject private var catalog = AppCatalog()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            schemeCard
            candidateCard
            englishCard
            appDefaultsCard
            quickAddCard
            if !freqClearHint.isEmpty {
                Text(freqClearHint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 输入方案

    private var schemeCard: some View {
        SettingsCard("输入方案") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("输入方案", selection: binding(\.inputScheme)) {
                    Text("小鹤双拼（默认）").tag(InputScheme.xiaohe)
                    Text("全拼").tag(InputScheme.fullPinyin)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .accessibilityLabel("输入方案")
                VStack(alignment: .leading, spacing: 8) {
                    Text("模糊音（默认全关）").font(.system(size: 12, weight: .medium))
                    // 三列九项，无计数、解释或批量操作。
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 3),
                              alignment: .leading, spacing: 8) {
                        ForEach(InputScheme.fuzzyPairs, id: \.id) { pair in
                            Toggle(pair.id, isOn: Binding(
                                get: { settings.fuzzyPinyin.contains(pair.id) },
                                set: { on in
                                    if on { settings.fuzzyPinyin.insert(pair.id) } else { settings.fuzzyPinyin.remove(pair.id) }
                                    submit()
                                }))
                                .font(.system(size: 12))
                                .accessibilityLabel("模糊音 \(pair.id)")
                        }
                    }
                }
            }
        }
    }

    // MARK: 候选窗与输入区

    private var candidateCard: some View {
        SettingsCard("候选窗与输入区") {
            VStack(alignment: .leading, spacing: 12) {
                // 候选字号 12–16 整数滑块＋刻度。
                VStack(alignment: .leading, spacing: 4) {
                    Text("候选字号：\(settings.candidateFontSize) 号（注释 −1，序号 −3）")
                        .font(.system(size: 13))
                    Slider(value: Binding(
                        get: { Double(settings.candidateFontSize) },
                        set: { value in
                            let clamped = min(16, max(12, Int(value.rounded())))
                            if clamped != settings.candidateFontSize {
                                settings.candidateFontSize = clamped
                                submit()
                            }
                        }), in: 12...16, step: 1)
                        .accessibilityLabel("候选字号")
                        .accessibilityValue("\(settings.candidateFontSize) 号")
                    HStack {
                        ForEach([12, 13, 14, 15, 16], id: \.self) { size in
                            Text(String(size))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .onTapGesture {
                                    if settings.candidateFontSize != size {
                                        settings.candidateFontSize = size
                                        submit()
                                    }
                                }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("候选字号刻度")
                }
                Toggle("候选旁英文释义（词性＋译文；无合格词性数据时只显示译文）",
                       isOn: binding(\.glossEnabled)).font(.system(size: 13))
                Toggle("在宿主正文显示输入的字母（下划线）",
                       isOn: binding(\.inputLettersEnabled)).font(.system(size: 13))
                // 显示内容：分段控件。
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

    // MARK: 英文候选与调频

    private var englishCard: some View {
        SettingsCard("中文模式下的英文候选与调频") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("给英文候选（词表＋词频；数据包就绪后生效）",
                       isOn: binding(\.englishCandidatesEnabled)).font(.system(size: 13))
                Toggle("本地中文调频（只学习普通模式完整上屏的中文）",
                       isOn: binding(\.frequencyEnabled)).font(.system(size: 13))
                HStack {
                    Button("清空调频数据") {
                        let dir = Settings.chineseDirectory
                        try? FileManager.default.removeItem(at: dir)
                        freqClearHint = "已清空调频数据；自定义词语不受影响。输入法下次重载后生效。"
                    }
                    Text("数据存 ~/Library/Application Support/Gogaku/chinese/").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 按应用默认英文

    private var appDefaultsCard: some View {
        SettingsCard("按应用默认英文") {
            VStack(alignment: .leading, spacing: 8) {
                Text("这些应用切入时为临时英文；手动 Shift 可覆盖，无组合时 Esc 回到该应用默认。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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
            }
        }
    }

    // MARK: 快速添加

    private var quickAddCard: some View {
        SettingsCard("快速添加") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("快捷键").font(.system(size: 13))
                    Spacer()
                    ShortcutEditor(command: .quickAdd,
                                   shortcut: Binding(get: { settings.quickAddShortcut },
                                                     set: { settings.quickAddShortcut = $0; submit() }),
                                   settings: settings)
                    .frame(width: 240, alignment: .trailing)
                }
                Text("把当前应用、当前输入框 60 秒内最近一次完整上屏的中文候选连同实际拼音加为拼音词；排除应用中不生效。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("排除应用（加入即排除，移除即恢复）").font(.system(size: 12, weight: .medium))
                    AppListEditor(mode: .excluded(ids: Binding(
                        get: { settings.quickAddExcludedApplications },
                        set: { newValue in
                            settings.quickAddExcludedApplications = newValue
                            submit()
                        })),
                        emptyText: "尚未排除任何应用；加入后这些应用里不能用快速添加。",
                        addSheetTitle: "添加要排除的应用",
                        accessibilityPrefix: "快速添加排除",
                        catalog: catalog)
                }
            }
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
