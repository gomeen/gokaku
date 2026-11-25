import SwiftUI
import GogakuKit
import AppKit

/// 扩展词库页（2026-11-26 裁决，合同见 docs/dictionaries.md）：导入（多选）＋
/// 词库列表（名称、条目数、来源、内存估算、开关、删除）＋合计内存提醒（超
/// 200MB 提醒不阻止）＋搜狗／萌娘百科链接＋「获取更多词库」官方渠道。
/// 转换在共享核心一份实现；这里只做文件选择、后台线程与展示。
struct DictionariesPage: View {
    /// 学习门禁（学习翻译启用且未在 Lite 模式）为 false 时 learning 列恒 false，
    /// 页面不显示「仅普通模式」标注。
    let learningGateEnabled: Bool

    /// 导入取消旗标（引用类型；设置应用线程与导入进度回调共享）。
    final class ImportCancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            get { lock.withLock { cancelled } }
            set { lock.withLock { cancelled = newValue } }
        }
    }

    enum ImportState: Equatable {
        case idle
        case importing(fileName: String, progress: Double)
        case done(message: String)
        case failed(message: String)
    }

    struct CatalogState: Equatable {
        var snapshot: DictionaryCatalog.Snapshot?
        var loading = false
        var installingID: String?
        var progress: Double = 0
        var message = ""
        var failedMessage = ""
        var pendingRecommendationID: String?
    }

    @State private var entries: [DictionaryStore.Entry] = []
    @State private var enabledEstimatedBytes: Int64 = 0
    @State private var warn = false
    @State private var corrupt: [String] = []
    @State private var loadFailed = false
    @State private var importState: ImportState = .idle
    @State private var importCancelFlag = ImportCancelFlag()
    @State private var catalog = CatalogState()
    @State private var catalogSheet = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var confirmRemoval: DictionaryStore.Entry?

    private let importQueue = DispatchQueue(label: "org.gogaku.settings.dictionaries", qos: .userInitiated)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if loadFailed {
                Label("词库目录读取失败，请检查权限后重开页面。",
                      systemImage: "exclamationmark.triangle").foregroundStyle(SettingsPalette.danger)
            }
            if !corrupt.isEmpty {
                Label("有词库元数据损坏，已备份为 .corrupt：\(corrupt.joined(separator: "、"))。重新导入同一文件即可恢复。",
                      systemImage: "exclamationmark.triangle").foregroundStyle(SettingsPalette.danger)
            }
            if warn {
                Label("启用的词库合计约 \(memoryText(enabledEstimatedBytes))，较大内存占用可能影响整机流畅；可停用暂不需要的词库（提醒，不影响启用）。",
                      systemImage: "exclamationmark.triangle").foregroundStyle(SettingsPalette.warningText)
            }
            topRow
            switch importState {
            case .importing(let fileName, let progress): importProgressRow(fileName: fileName, progress: progress)
            case .done(let message): Text(message).foregroundStyle(SettingsPalette.ok)
            case .failed(let message): Text(message).foregroundStyle(SettingsPalette.danger)
            case .idle: EmptyView()
            }
            if !catalog.message.isEmpty {
                Text(catalog.message).foregroundStyle(.secondary)
            }
            if !catalog.failedMessage.isEmpty {
                Text(catalog.failedMessage).foregroundStyle(SettingsPalette.danger)
            }
            list
            starterRecommendations
            linksSection
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("org.gogaku.dictionaries.changed"))) { _ in
            // 本应用的变更也回到本页：直接重读（核心是唯一解析实现）。
            reload()
        }
        .sheet(isPresented: $catalogSheet, onDismiss: { downloadTask?.cancel() }) { catalogSheetView }
        .alert("删除词库「\(confirmRemoval?.name ?? "")」？",
               isPresented: Binding(get: { confirmRemoval != nil }, set: { if !$0 { confirmRemoval = nil } })) {
            Button("取消", role: .cancel) { confirmRemoval = nil }
            Button("删除", role: .destructive) {
                if let entry = confirmRemoval { remove(entry) }
                confirmRemoval = nil
            }
        } message: {
            Text("已学入调频的词会保留；词库文件与元数据将被删除。")
        }
    }

    // MARK: - 顶部行

    private var topRow: some View {
        HStack(spacing: 12) {
            Button("导入词库") { chooseAndImport() }
                .accessibilityLabel("导入词库文件")
                .disabled(isImporting)
            if isImporting {
                Button("取消导入") { importCancelFlag.isCancelled = true }
            }
            Spacer(minLength: 12)
            if !entries.isEmpty {
                Text("启用合计约 \(memoryText(enabledEstimatedBytes))")
                    .foregroundStyle(.secondary)
            }
            Button("获取更多词库") { fetchCatalog() }
                .disabled(catalog.loading || catalog.installingID != nil)
            if catalog.loading {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var isImporting: Bool {
        if case .importing = importState { return true }
        return false
    }

    private func importProgressRow(fileName: String, progress: Double) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: progress)
            Text("正在导入 \(fileName)（\(Int(progress * 100))%）")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - 列表

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                Text("尚未添加扩展词库。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
            } else {
                ForEach(entries) { entry in
                    row(entry)
                    Divider()
                }
            }
        }
        .background(SettingsPalette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ entry: DictionaryStore.Entry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).fontWeight(.medium)
                    Text(entry.isOfficial ? "官方" : "导入")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(SettingsPalette.accentSoft)
                        .clipShape(Capsule())
                    if entry.isOfficial, !entry.version.isEmpty {
                        Text("v\(entry.version)").font(.caption).foregroundStyle(.secondary)
                    }
                    if learningGateEnabled, !entry.learning {
                        Text("仅普通模式").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text("\(entry.entryCount) 条").font(.caption).foregroundStyle(.secondary)
                    Text("约 \(entry.estimatedMemoryText)").font(.caption).foregroundStyle(.secondary)
                    if entry.isOfficial, !entry.license.isEmpty {
                        Text(entry.license).font(.caption).foregroundStyle(.secondary)
                    } else if !entry.sourceFileName.isEmpty {
                        Text(entry.sourceFileName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 12)
            Toggle("启用", isOn: Binding(
                get: { entry.enabled },
                set: { enabled in toggle(entry, enabled) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("启用\(entry.name)")
            Button("删除") { confirmRemoval = entry }
                .accessibilityLabel("删除\(entry.name)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var starterRecommendations: some View {
        let recommendations = DictionaryCatalog.loadConfig()?.recommendations ?? []
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("入门推荐").font(.headline)
                Spacer()
                Text("官方词库 · 按需安装").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            ForEach(recommendations) { recommendation in
                recommendationRow(recommendation)
                Divider()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recommendationRow(_ recommendation: DictionaryCatalog.Recommendation) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recommendation.name).fontWeight(.medium)
                Text(recommendation.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if catalog.pendingRecommendationID == recommendation.id {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("检查中…").font(.callout).foregroundStyle(.secondary)
                }
            } else if catalog.installingID == recommendation.id {
                HStack(spacing: 6) {
                    ProgressView(value: catalog.progress).frame(width: 48)
                    Text("\(Int(catalog.progress * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("取消") { downloadTask?.cancel() }
                }
            } else if let installed = entries.first(where: { $0.id == recommendation.id }) {
                Text("已安装 v\(installed.version)").font(.callout).foregroundStyle(.secondary)
            } else {
                Button("安装") { fetchCatalog(recommendedID: recommendation.id) }
                    .disabled(catalog.loading || catalog.installingID != nil)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - 链接与官方渠道入口

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            linkRow(title: "打开搜狗细胞词库",
                    detail: "在浏览器打开 pinyin.sogou.com/dict，下载 .scel 后回到这里导入。",
                    url: "https://pinyin.sogou.com/dict")
            linkRow(title: "萌娘百科词库（mw2fcitx）",
                    detail: "打开上游发布页自行下载 .dict 导入。内容为 CC BY-NC-SA 授权，只能非商业使用，Gogaku 不分发。",
                    url: "https://github.com/outloudvi/mw2fcitx/releases")
            if let rejected = catalog.snapshot?.rejected, !rejected.isEmpty {
                Text("清单里 \(rejected.count) 项不合格式未显示：\(rejected.joined(separator: "；"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func linkRow(title: String, detail: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Link(title, destination: URL(string: url) ?? URL(fileURLWithPath: "/"))
                    .font(.callout)
                Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(.secondary)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 官方渠道弹层

    private var catalogSheetView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("官方精选词库").font(.title3).fontWeight(.semibold)
                Spacer()
                Button("关闭") { catalogSheet = false }
            }
            Text("从 gogaku-dicts 发布渠道获取；请求不携带输入内容、凭据或设备标识。已安装的词库显示版本，有新版时显示「更新」。")
                .font(.caption).foregroundStyle(.secondary)
            if catalog.installingID != nil {
                HStack(spacing: 10) {
                    ProgressView(value: catalog.progress)
                    Text("\(Int(catalog.progress * 100))%").font(.callout).foregroundStyle(.secondary)
                    Button("取消下载") { downloadTask?.cancel() }
                }
            }
            if !catalog.failedMessage.isEmpty {
                Text(catalog.failedMessage).foregroundStyle(SettingsPalette.danger)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(catalog.snapshot?.entries ?? []) { entry in
                        catalogRow(entry)
                        Divider()
                    }
                }
            }
            .frame(minHeight: 260)
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }

    private func catalogRow(_ entry: DictionaryCatalog.Entry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).fontWeight(.medium)
                    Text(entry.category).font(.caption).foregroundStyle(.secondary)
                    if entry.installed {
                        Text(entry.updateAvailable ? "有新版" : "已安装")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(entry.entryDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    Text("v\(entry.version)").font(.caption).foregroundStyle(.secondary)
                    Text(entry.sizeText).font(.caption).foregroundStyle(.secondary)
                    Text("\(entry.entryCount) 条").font(.caption).foregroundStyle(.secondary)
                    Text(entry.license).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if catalog.installingID == entry.id {
                ProgressView().controlSize(.small)
            } else if entry.installed, !entry.updateAvailable {
                Text("已是最新").font(.callout).foregroundStyle(.secondary)
            } else {
                Button(entry.installed ? "更新" : "安装") {
                    installCatalogEntry(entry)
                }
                .disabled(catalog.installingID != nil)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - 动作

    private func reload() {
        do {
            let listing = try DictionaryStore.list(learningAvailable: learningGateEnabled)
            entries = listing.entries
            enabledEstimatedBytes = listing.enabledEstimatedBytes
            warn = listing.warn
            corrupt = listing.corrupt
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    private func toggle(_ entry: DictionaryStore.Entry, _ enabled: Bool) {
        do {
            try DictionaryStore.setEnabled(enabled, id: entry.id)
            reload()
        } catch {
            importState = .failed(message: "保存启用状态失败：\(error.localizedDescription)")
        }
    }

    private func remove(_ entry: DictionaryStore.Entry) {
        do {
            try DictionaryStore.remove(id: entry.id)
            reload()
        } catch {
            importState = .failed(message: "删除失败：\(error.localizedDescription)")
        }
    }

    private func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["scel", "yaml", "dict", "txt"]
        panel.message = "选择词库文件（支持搜狗 .scel、Rime .dict.yaml、libime .txt／.dict、纯词表 .txt）"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importSequentially(panel.urls)
    }

    /// 多文件按顺序导入；每个文件都在后台线程执行（核心不建线程，进度回调
    /// 在调用线程）。取消在文件间生效；文件内取消经进度回调传递（返回码 3）。
    private func importSequentially(_ urls: [URL]) {
        importCancelFlag.isCancelled = false
        if let first = urls.first {
            importState = .importing(fileName: first.lastPathComponent, progress: 1)
        }
        let view = self
        let cancelFlag = importCancelFlag
        Task.detached(priority: .userInitiated) { [cancelFlag] in
            var lines: [String] = []
            var firstErrorText = ""
            var imported = 0
            for url in urls {
                if cancelFlag.isCancelled { break }
                let fileName = url.lastPathComponent
                let state = ImportState.importing(fileName: fileName, progress: 1)
                await MainActor.run { view.importState = state }
                do {
                    let result = try DictionaryStore.importFile(at: url) { [cancelFlag] _ in
                        !cancelFlag.isCancelled
                    }
                    imported += 1
                    let droppedText = result.dropped
                        .filter { $0.value > 0 }
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key) \($0.value)" }
                        .joined(separator: "、")
                    lines.append("\(result.name)：导入 \(result.entryCount) 条" +
                                 (droppedText.isEmpty ? "" : "；丢弃 \(droppedText)"))
                } catch DictionaryStore.StoreError.cancelled {
                    lines.append("\(fileName)：已取消")
                } catch DictionaryStore.StoreError.duplicate {
                    lines.append("\(fileName)：同一源文件已导入过，已跳过")
                } catch {
                    if firstErrorText.isEmpty { firstErrorText = error.localizedDescription }
                    lines.append("\(fileName)：\(error.localizedDescription)")
                }
            }
            let summary = lines.joined(separator: "\n")
            let failure = firstErrorText
            let importedCount = imported
            await MainActor.run {
                if importedCount == 0 && !failure.isEmpty && summary.isEmpty {
                    view.importState = .failed(message: failure)
                } else {
                    view.importState = .done(message: summary)
                }
                view.reload()
            }
        }
    }

    private func fetchCatalog(recommendedID: String? = nil) {
        catalog.loading = true
        catalog.pendingRecommendationID = recommendedID
        catalog.failedMessage = ""
        catalog.message = ""
        Task.detached(priority: .userInitiated) {
            do {
                guard let config = DictionaryCatalog.loadConfig() else {
                    throw DictionaryCatalog.CatalogError.notConfigured
                }
                guard let updateConfig = UpdateSourceConfig.load() else {
                    throw DictionaryCatalog.CatalogError.notConfigured
                }
                let installed = try DictionaryStore.list(learningAvailable: learningGateEnabled).entries
                let snapshot = try await DictionaryCatalog.fetch(
                    transport: URLSessionUpdateTransport(),
                    config: config,
                    updateKeys: updateConfig.trustedKeys,
                    installed: installed)
                await MainActor.run {
                    catalog.snapshot = snapshot
                    catalog.loading = false
                    catalog.pendingRecommendationID = nil
                    if let recommendedID {
                        guard let entry = snapshot.entries.first(where: { $0.id == recommendedID }) else {
                            catalog.failedMessage = "官方清单中暂未找到这本入门词库。"
                            return
                        }
                        installCatalogEntry(entry)
                    } else {
                        catalog.message = "清单版本 \(snapshot.catalogVersion)，共 \(snapshot.entries.count) 本"
                        catalogSheet = true
                    }
                }
            } catch {
                await MainActor.run {
                    catalog.loading = false
                    catalog.pendingRecommendationID = nil
                    catalog.failedMessage = DictionaryCatalog.failureMessage(error)
                }
            }
        }
    }

    private func installCatalogEntry(_ entry: DictionaryCatalog.Entry) {
        guard let snapshot = catalog.snapshot, catalog.installingID == nil else { return }
        catalog.failedMessage = ""
        catalog.installingID = entry.id
        catalog.progress = 0
        let version = snapshot.catalogVersion
        downloadTask = Task.detached(priority: .userInitiated) {
            do {
                try await DictionaryCatalog.install(entry, catalogVersion: version,
                                                    transport: URLSessionUpdateTransport()) { fraction in
                    Task { @MainActor in
                        if catalog.installingID == entry.id { catalog.progress = fraction }
                    }
                }
                await MainActor.run {
                    catalog.installingID = nil
                    catalog.message = "已安装「\(entry.name)」"
                    reload()
                }
            } catch {
                await MainActor.run {
                    catalog.installingID = nil
                    catalog.failedMessage = DictionaryCatalog.failureMessage(error)
                }
            }
        }
    }

    private func memoryText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
