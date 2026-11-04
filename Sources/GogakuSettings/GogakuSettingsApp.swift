import SwiftUI
import GogakuCore

/// 包内构建身份（Contents/Resources/build-identity.json）。
/// 设置页与诊断输出展示完整预发布版本；缺失时回退 Info.plist 三段版本。
enum BuildIdentity {
    static let displayVersion: String = {
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "build-identity", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let full = object["fullVersion"] as? String else {
            let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            return "\(short)（构建 \(build)，无身份记录）"
        }
        let build = object["buildNumber"] as? Int ?? 0
        let dirty = (object["dirty"] as? Bool ?? false) ? " dirty" : ""
        return "\(full) 构建\(build)\(dirty)"
    }()
}

@main struct GogakuSettingsApp: App {
    var body: some Scene {
        Window("Gogaku 设置", id: "settings") {
            SettingsView().frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 900, height: 620)
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case resources, normalInput, customWords, shortcuts, privacy, records
    var id: Self { self }
    var title: String {
        switch self {
        case .resources: return "语言资源"
        case .normalInput: return "普通输入"
        case .customWords: return "自定义词语"
        case .shortcuts: return "快捷键"
        case .privacy: return "学习与隐私"
        case .records: return "学习片段"
        }
    }
}

/// 设置外壳（对应原型 .shell--a）：200pt 文字侧栏、六页、页头 22/600、
/// 内容滚动区（水平内边距 26）、固定底部状态栏。侧栏选中态用 accent-soft 底＋
/// accent-text 文字（原型 .nav__item），无图标。立即保存：普通选项／应用列表／
/// 快捷键改动立即提交，连续文本输入合并 300ms，失焦或关闭窗口时提交剩余有效改动；
/// 保存状态由 SettingsStore 回调驱动。
private struct SettingsView: View {
    @State private var page: SettingsPage = .normalInput
    @State private var settings = Settings.load()
    @State private var status: SaveStatus = .idle
    @State private var records: [LearningEvent] = []
    private let store = LearningStore()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            // 侧栏右描边（.side { border-right: 1px solid var(--border) }）。
            Rectangle().fill(SettingsPalette.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                // 页面只保留标题（原型 .pagehead：22/600，padding 22 26 14）。
                Text(page.title).font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SettingsPalette.primaryText)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 26)
                    .padding(.top, 22)
                    .padding(.bottom, 14)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch page {
                        case .resources: ResourcesPage(settings: $settings)
                        case .normalInput: NormalInputPage(settings: $settings)
                        case .customWords: CustomWordsPage(status: $status)
                        case .shortcuts: ShortcutsPage(settings: $settings)
                        case .privacy: PrivacyPage(settings: $settings)
                        case .records: RecordsPage(records: $records) { refreshRecords() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // .scroller：padding 2 26 18。
                    .padding(.horizontal, 26)
                    .padding(.bottom, 18)
                }
                .id(page)
                statusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(SettingsPalette.windowBackground)
        .font(.system(size: 13))
        .tint(SettingsPalette.accent)
        .onAppear {
            SettingsStore.shared.onStatus = { newStatus in
                status = SaveStatus(storeStatus: newStatus)
                if case .saved = newStatus {
                    // 输入法收到通知重载后，同步一份最新值避免界面显示旧缓存。
                    settings = Settings.load()
                }
            }
            refreshRecords()
        }
        .onChange(of: page) { _, newValue in
            if newValue == .records { refreshRecords() }
        }
        .onDisappear {
            // 关闭窗口／视图销毁时提交剩余有效改动（如 300ms 合并中的文本）。
            SettingsStore.shared.flushPending()
        }
    }

    // MARK: 侧栏（.side：side-bg 底、文字导航、底部版本）

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // .side__title：14/600，padding 18 16 10。
            Text("Gogaku")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SettingsPalette.primaryText)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 10)
            // .nav：gap 1，padding 0 8。
            VStack(alignment: .leading, spacing: 1) {
                ForEach(SettingsPage.allCases) { item in
                    SidebarItem(title: item.title, isSelected: page == item) {
                        page = item
                    }
                }
            }
            .padding(.horizontal, 8)
            .accessibilityElement(children: .contain)
            Spacer(minLength: 0)
            // .side__foot：meta 11 / ver mono 10，padding 12 16 14。
            VStack(alignment: .leading, spacing: 3) {
                Text("本机开发版")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondaryText)
                Text(BuildIdentity.displayVersion)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(SettingsPalette.tertiaryText)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsPalette.sidebarBackground)
    }

    /// 固定底部状态栏（.statusbar：min-height 36、win-bg 底、顶部 border 线、
    /// 圆点 7×7）：保存中／已保存／失败及重试。失败不伪报成功，不无限重试。
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(status.dotColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(status.text.isEmpty ? "修改后立即生效" : status.text)
                .font(.system(size: 11))
                .foregroundStyle(SettingsPalette.secondaryText)
                .accessibilityLabel("保存状态：\(status.text.isEmpty ? "无待保存改动" : status.text)")
            Spacer(minLength: 8)
            if case .failed = status {
                Button("重试") {
                    SettingsStore.shared.retry()
                    status = .saving
                }
                .controlSize(.small)
                .accessibilityLabel("重试保存")
            }
        }
        .padding(.horizontal, 26)
        .frame(minHeight: 36)
        .background(SettingsPalette.windowBackground)
        .overlay(Rectangle().fill(SettingsPalette.border).frame(height: 1), alignment: .top)
    }

    private func refreshRecords() {
        store.list { result in DispatchQueue.main.async {
            switch result {
            case .success(let items): records = items
            case .failure: break   // 片段读取失败只在片段页展示；不影响输入。
            }
        } }
    }
}

/// 侧栏导航项（.nav__item：13px、padding 6 10、radius 6；选中 accent-soft 底＋
/// accent-text 文字＋600 字重，悬停中性灰底；无图标，与原型一致）。
private struct SidebarItem: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? SettingsPalette.accentText : SettingsPalette.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? SettingsPalette.accentSoft
                              : hovered ? Color.primary.opacity(0.13) : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(title)
    }
}

// MARK: - 语言资源页（不提供 Apple Translation 查询与安装入口；
// 原型为两个 section＋hr；quickmt 开发版裁决后新增「学习翻译（开发版）」区块）

private struct ResourcesPage: View {
    @Binding var settings: GogakuCore.Settings
    @State private var bundled: [(name: String, size: String?)] = []
    @State private var backend = LearningTranslation.Environment(ready: false, missing: [])
    @State private var volcAccessKey = ""
    @State private var volcSecretKey = ""
    @State private var volcCredentialsDirty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("本地翻译") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(bundled.enumerated()), id: \.element.name) { index, item in
                        resourceRow(item)
                        if index < bundled.count - 1 { SettingsRowDivider() }
                    }
                    Text("以上为实际随包数据。资源缺失时普通输入自动降级，不影响已安装词库。")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsPalette.secondaryText)
                        .padding(.top, 8)
                }
            }
            SettingsRule()
            learningTranslationSection
            SettingsRule()
            section("开发版状态") {
                VStack(alignment: .leading, spacing: 8) {
                    // .body-text：12.5px。
                    Text("普通输入：已在本机开发范围验证，完整宿主与性能验收仍在进行。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsPalette.primaryText)
                    Text("学习功能：quickmt 开发版已按用户裁决解锁本机自用；正式质量门槛与宿主验收未过，双端交付口径不变。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsPalette.primaryText)
                    Text("本页不提供系统语言资源安装入口；正式翻译模型质量与安装流程另行验收。")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsPalette.secondaryText)
                }
            }
        }
        .onAppear {
            loadBundled()
            backend = LearningTranslation.environment(backend: settings.learningTranslationBackend)
            loadVolcengineCredentials()
        }
        .onChange(of: settings.learningTranslationEnabled) { _, _ in
            backend = LearningTranslation.environment(backend: settings.learningTranslationBackend)
        }
        .onChange(of: settings.learningTranslationBackend) { _, _ in
            backend = LearningTranslation.environment(backend: settings.learningTranslationBackend)
            loadVolcengineCredentials()
        }
    }

    /// 火山翻译免费额度用量条（200 万字符/自然月；到量提示付费或切换）。
    /// 截图效果：标签 + 进度条 + 百分比 + 重置倒计时。
    private var volcengineUsageRow: some View {
        let used = max(0, settings.volcengineUsageCharacters)
        let quota = 2_000_000
        let fraction = min(1.0, Double(used) / Double(quota))
        let percent = Int((fraction * 100).rounded())
        let daysLeft = Calendar.current.dateComponents([.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: Self.nextMonthStart())).day ?? 0
        let exhausted = used >= quota
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("火山免费额度")
                    .font(.system(size: 12.5))
                    .foregroundStyle(SettingsPalette.primaryText)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(SettingsPalette.secondaryText.opacity(0.25))
                        Capsule().fill(fraction > 0.95 ? Color.red : (fraction > 0.8 ? Color.orange : Color.green))
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                .frame(height: 6)
                Text("\(percent)%")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(fraction > 0.95 ? Color.red : (fraction > 0.8 ? Color.orange : Color.green))
                    .frame(minWidth: 38, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Text("已用 \(used) / 200 万字符 · \(daysLeft) 天后重置（每月 1 日）")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondaryText)
                if exhausted {
                    Button("切换到 small100（本地）") {
                        settings.learningTranslationBackend = "small100"
                        submit()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
                }
            }
            if exhausted {
                Text("免费额度已用完：继续使用将按 ¥49/百万字符计费（火山引擎账户扣费），或切换后端。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
            }
        }
        .padding(.vertical, 2)
    }

    private static func nextMonthStart() -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: Date())
        return calendar.date(from: DateComponents(year: components.year,
                                                  month: (components.month ?? 1) + 1, day: 1)) ?? Date()
    }

    /// 火山凭据载入输入框（仅学习后端为 volcengine 时有意义）。
    private func loadVolcengineCredentials() {
        guard LearningTranslation.normalizedBackend(settings.learningTranslationBackend) == "volcengine",
              let credentials = LearningTranslation.volcengineCredentials() else { return }
        volcAccessKey = credentials.accessKey
        volcSecretKey = credentials.secretKey
        volcCredentialsDirty = false
    }

    /// 后端感知的就绪描述。
    private var backendReadyText: String {
        switch LearningTranslation.normalizedBackend(settings.learningTranslationBackend) {
        case "small100": return "后端状态：模型就绪（small100 CT2 INT8，本地）"
        case "volcengine": return "后端状态：凭据就绪（火山翻译 NMT，云端——仅学习模式联网）"
        default: return "后端状态：模型就绪（quickmt-en-zh／quickmt-zh-en，CT2 INT8，本地）"
        }
    }

    /// 后端感知的质量说明。
    private var backendNoticeText: String {
        switch LearningTranslation.normalizedBackend(settings.learningTranslationBackend) {
        case "small100": return "未过质量门槛，仅开发版体验：small100 可用率 95.15%／94.34%（残余 5 条语义失败）；候选带开发版标注。"
        case "volcengine": return "未过质量门槛，仅开发版体验：火山翻译实测中位 114ms、20 句固定失败点全对；每次学习翻译经火山 API 域联网（仅学习模式）。"
        default: return "未过质量门槛，仅开发版体验：quickmt 已知固定风险（如短语级复读、en→zh 可用率 77.67%）被开发版接受；候选带「quickmt 开发版」标注。"
        }
    }

    /// 学习翻译（开发版）：启用开关＋beam 步进器＋后端状态＋固定说明；
    /// 改动即时保存并热生效（beam 变更重建辅助进程）。
    private var learningTranslationSection: some View {
        section("学习翻译（开发版）") {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow("启用学习翻译",
                            detail: "关闭即回门禁态：学习菜单置灰、共享学习会话释放。学习记录仍保持关闭。") {
                    Toggle("", isOn: Binding(get: { settings.learningTranslationEnabled },
                                             set: { settings.learningTranslationEnabled = $0; submit() }))
                        .toggleStyle(.switch)
                        .accessibilityLabel("启用学习翻译后端")
                }
                SettingsRowDivider()
                SettingsRow("翻译后端",
                            detail: "quickmt／small100＝本地（无网络）；火山翻译＝云端 NMT（仅学习模式联网，普通模式不经任何翻译路径）。变更热生效。") {
                    Picker("", selection: Binding(get: { settings.learningTranslationBackend },
                                                  set: { settings.learningTranslationBackend = $0; submit() })) {
                        Text("quickmt（本地）").tag("quickmt")
                        Text("small100（本地）").tag("small100")
                        Text("火山翻译（云端）").tag("volcengine")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 190)
                    .accessibilityLabel("学习翻译后端选择")
                }
                if LearningTranslation.normalizedBackend(settings.learningTranslationBackend) == "volcengine" {
                    SettingsRowDivider()
                    volcengineUsageRow
                }
                // 双分区（2026-11-04 方案 A）：本地区（beam＋状态）／云端区（连接卡＋用量）。
                if LearningTranslation.normalizedBackend(settings.learningTranslationBackend) == "volcengine" {
                    SettingsRowDivider()
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Text("火山翻译").font(.system(size: 14, weight: .semibold))
                            Text(backend.ready ? "● 凭据已配置" : "● 凭据未配置")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(backend.ready ? Color.green.opacity(0.12) : Color.red.opacity(0.12))
                                .foregroundStyle(backend.ready ? Color.green : Color.red)
                                .clipShape(Capsule())
                        }
                        .padding(.vertical, 8)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Access Key ID").font(.system(size: 11.5)).foregroundStyle(SettingsPalette.secondaryText)
                            SecureField("AKLT…", text: $volcAccessKey)
                                .font(.system(size: 12, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: volcAccessKey) { _, _ in volcCredentialsDirty = true }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Secret Access Key").font(.system(size: 11.5)).foregroundStyle(SettingsPalette.secondaryText)
                            SecureField("TWp…", text: $volcSecretKey)
                                .font(.system(size: 12, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: volcSecretKey) { _, _ in volcCredentialsDirty = true }
                        }
                        HStack(spacing: 10) {
                            Button("保存凭据") {
                                do {
                                    try LearningTranslation.saveVolcengineCredentials(
                                        LearningTranslation.VolcengineCredentials(accessKey: volcAccessKey, secretKey: volcSecretKey))
                                    volcCredentialsDirty = false
                                    backend = LearningTranslation.environment(backend: settings.learningTranslationBackend)
                                } catch {
                                    NSLog("GogakuSettings: 保存火山凭据失败 \(error)")
                                }
                            }
                            .font(.system(size: 12))
                            .buttonStyle(.borderedProminent)
                            .disabled(volcAccessKey.isEmpty || volcSecretKey.isEmpty || !volcCredentialsDirty)
                            if volcCredentialsDirty {
                                Text("有未保存修改").font(.system(size: 11)).foregroundStyle(SettingsPalette.secondaryText)
                            }
                        }
                        .padding(.vertical, 6)
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield").font(.system(size: 11))
                            Text("凭据仅写入本机 0600 权限文件（~/Library/Application Support/Gogaku/translation/），绝不进入代码仓库、设置同步或任何云端。")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Color.green)
                        .background(Color.green.opacity(0.1))
                        .padding(8)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    SettingsRowDivider()
                    volcengineUsageRow
                    SettingsRowDivider()
                    Text("☁️ 云端仅学习模式联网（只访问火山翻译 API 域）；普通模式不经任何翻译路径。实测中位延迟 114ms，20 句固定失败点全对。")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsPalette.secondaryText)
                        .padding(.vertical, 10)
                    if !backend.ready {
                        Text("缺失：\(backend.missing.joined(separator: "、"))。可在上方填写凭据后保存。")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red)
                            .padding(.bottom, 10)
                    }
                } else {
                    SettingsRowDivider()
                    SettingsRow("beam 大小",
                                detail: "1＝贪心最快（中位约 88ms）；已知重复句等缺陷随 beam 升高缓解，代价是延迟增加。变更后对新翻译请求生效。") {
                        Stepper(value: Binding(get: { settings.learningBeamSize },
                                               set: { settings.learningBeamSize = LearningTranslation.clampedBeam($0); submit() }),
                                in: LearningTranslation.beamRange) {
                            Text("\(settings.learningBeamSize)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(SettingsPalette.primaryText)
                                .frame(minWidth: 24)
                        }
                        .accessibilityLabel("翻译 beam 大小，1 到 10")
                    }
                    SettingsRowDivider()
                    VStack(alignment: .leading, spacing: 4) {
                        if backend.ready {
                            Text(backendReadyText)
                                .font(.system(size: 12.5))
                                .foregroundStyle(SettingsPalette.primaryText)
                        } else {
                            Text("后端状态：缺失（\(backend.missing.joined(separator: "、"))）")
                                .font(.system(size: 12.5))
                                .foregroundStyle(SettingsPalette.primaryText)
                            Text("准备：在仓库检出目录运行 \(LearningTranslation.prepareCommand(backend: settings.learningTranslationBackend))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(SettingsPalette.secondaryText)
                                .textSelection(.enabled)
                        }
                        Text(backendNoticeText)
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsPalette.secondaryText)
                    }
                }
            }
        }
    }

    /// section 标题（.section__title：15/600）。
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SettingsPalette.primaryText)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// 资源行（原型 .word：↧ 图标块 32×32＋名称＋尺寸）。
    private func resourceRow(_ item: (name: String, size: String?)) -> some View {
        HStack(spacing: 10) {
            Text("↧")
                .font(.system(size: 13))
                .foregroundStyle(SettingsPalette.accentText)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(SettingsPalette.accentSoft))
                .accessibilityHidden(true)
            Text(item.name)
                .font(.system(size: 13))
                .foregroundStyle(SettingsPalette.primaryText)
            Spacer()
            Text(item.size ?? "—")
                .font(.system(size: 11))
                .foregroundStyle(SettingsPalette.secondaryText)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name)，\(item.size ?? "未随包提供")")
    }

    private func loadBundled() {
        let data = Paths.engineData
        let names = ["sc.dict", "zh_CN.lm", "english-words.txt", "gloss.tsv"]
        bundled = names.map { name in
            let url = data.appendingPathComponent(name)
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
                return (name, ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
            return (name, nil)
        }
    }

    /// 学习翻译改动即时提交（SettingsStore 通知输入法热生效）。
    private func submit() {
        SettingsStore.shared.submit(settings)
    }
}

// MARK: - 学习与隐私页（原型为三个 section＋hr；排除应用按规格保留原生应用列表）

private struct PrivacyPage: View {
    @Binding var settings: GogakuCore.Settings
    @State private var ignored = ""
    @ObservedObject private var catalog = AppCatalog()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("学习记录") {
                SettingsRow("记录学习片段",
                            detail: "当前开发版尚未接通成功提交后的记录；此开关只保存偏好，不解除真实学习记录门禁，也不会开始采集。") {
                    Toggle("", isOn: Binding(get: { settings.recording },
                                             set: { settings.recording = $0; submit() }))
                        .toggleStyle(.switch)
                        .accessibilityLabel("记录学习片段，保留30天")
                }
            }
            SettingsRule()
            section("排除应用") {
                AppListEditor(mode: .excluded(ids: Binding(
                    get: { settings.excludedApplications },
                    set: { settings.excludedApplications = $0; submit() })),
                    emptyText: "尚未排除任何应用。",
                    addSheetTitle: "添加不记录学习内容的应用",
                    accessibilityPrefix: "学习记录排除",
                    catalog: catalog)
            }
            SettingsRule()
            section("英语忽略词") {
                ignoreEditor
            }
        }
        .onAppear { ignored = settings.ignoredWords.sorted().joined(separator: "\n") }
    }

    /// section 标题（.section__title：15/600）。
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SettingsPalette.primaryText)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// 忽略词文本域（原型 .textarea mono 四行＋占位「每行一个忽略词」）。
    private var ignoreEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(
                get: { ignored },
                set: { newValue in
                    ignored = newValue
                    applyIgnored()
                }))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(SettingsPalette.primaryText)
                .scrollContentBackground(.hidden)
                .background(SettingsPalette.cardBackground)
                .frame(height: 96)
                .padding(5)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(SettingsPalette.borderStrong, lineWidth: 1))
                .accessibilityLabel("英语忽略词，每行一个")
            if ignored.isEmpty {
                Text("每行一个忽略词")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SettingsPalette.tertiaryText)
                    .padding(.horizontal, 11)
                    .padding(.top, 11)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 连续文本输入合并 300ms 后提交（SettingsStore 内部去抖）。
    private func applyIgnored() {
        settings.ignoredWords = Set(ignored.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
        submit(coalesce: true)
    }

    private func submit(coalesce: Bool = false) {
        SettingsStore.shared.submit(settings, coalesce: coalesce)
    }
}

// MARK: - 学习片段页（真实存储读取；原型 listhead＋记录行＋出厂空状态）

private struct RecordsPage: View {
    @Binding var records: [LearningEvent]
    let onRefresh: () -> Void
    private let store = LearningStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // .listhead：标题与刷新按钮两端对齐。
            HStack {
                Text("最近的片段").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SettingsPalette.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("刷新", action: onRefresh).controlSize(.small)
                    .accessibilityLabel("刷新学习片段")
            }
            .padding(.top, 2)
            if records.isEmpty {
                // .empty：虚线框空状态。
                VStack(spacing: 5) {
                    Image(systemName: "text.book.closed").font(.system(size: 26))
                        .foregroundStyle(SettingsPalette.tertiaryText)
                    Text("暂无学习片段").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SettingsPalette.primaryText)
                    Text("已确认成功的学习内容会显示在这里。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(SettingsPalette.borderStrong,
                                      style: StrokeStyle(lineWidth: 1, dash: [4])))
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(records) { event in
                        recordRow(event)
                    }
                }
            }
        }
    }

    /// 记录行（原型 .rec：左 pair＋meta，右操作按钮）。
    private func recordRow(_ event: LearningEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.source + " → " + event.target)
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsPalette.primaryText)
                    .textSelection(.enabled)
                Text("\(event.direction == .zhToEn ? "中→英" : "英→中") · \(event.category) · \(event.createdAt.formatted())")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                if !event.issues.isEmpty {
                    Button("排除此条误报") { store.dismissIssues(id: event.id) { _ in onRefresh() } }
                        .controlSize(.small)
                        .accessibilityLabel("排除此条误报：\(event.source)")
                }
                Button("删除片段") { store.delete(ids: [event.id]) { _ in onRefresh() } }
                    .controlSize(.small)
                    .accessibilityLabel("删除片段：\(event.source)")
            }
        }
        .padding(.vertical, 10)
    }
}
