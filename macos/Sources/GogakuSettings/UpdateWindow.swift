import SwiftUI
import AppKit
import GogakuKit

/// 检查更新控制器（2026-11-20 用户裁决：检查更新交互一步化）。
/// 只在设置应用内运行：输入法进程不发起更新请求，也不在按键路径执行网络或
/// 磁盘检查。自动检查默认关闭；开启后设置应用启动及运行期间按 24 小时间隔
/// 尝试，失败不紧密重试。发现新版只在设置内提示，不抢焦点。
///
/// 单按钮状态机：「检查更新」一个按钮贯穿全流程——点击后自动完成
/// 检查 →（有新版）下载 → 就地安装 → 完成；各阶段在按钮文案与状态行体现。
/// 任一步失败按钮变「重试」，错误行显示原因。唯一可能暂停等用户的是
/// installerUnavailable fallback：自动转系统安装器（按钮变「打开安装器」）。
/// 自动检查发现新版只静默预下载，UI 呈现「一键更新到 X」单按钮，点击即装。
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        case ready
        case installing(UpdateInstallPhase)
        case installed(String?)
        /// 就地安装不可用，已转系统安装器路径（用户点向导完成）。
        case awaitingSystemInstaller
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var outcome: UpdateCheckOutcome?
    @Published private(set) var progress: Double = 0
    @Published private(set) var downloadedFile: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var autoCheck: Bool = false
    @Published private(set) var hasUpdate: Bool = false
    @Published private(set) var lastInstallMessage: String?
    /// 数据包部分成功说明（主包已装、数据未换时的词库回退提示）。
    @Published private(set) var dataNotice: String?
    /// 就地安装需要下载的数据包资产（schema 2；nil＝无数据包或 schema 1 清单）。
    @Published private(set) var pendingDataPackage: UpdateDataPackage?
    /// 就地更新的已下载数据包 zip（跟随下载阶段填充）。
    @Published private(set) var downloadedDataFile: URL?
    /// 下载中是否为自动检查触发的静默预下载（此时按钮呈「一键更新到 X」）。
    @Published private(set) var isSilentPrefetch = false
    /// fallback 说明（转系统安装器的原因）；回到检查/空闲时清空。
    @Published private(set) var fallbackNotice: String?

    let installation: UpdateInstallation
    private let config: UpdateSourceConfig?
    private let preferences: UpdatePreferencesStore
    private let engine: UpdateEngine
    private let downloader: UpdateDownloader
    private var checkTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var timer: Timer?

    init(bundle: Bundle = .main,
         transport: UpdateTransport = URLSessionUpdateTransport(),
         downloader: UpdateDownloader = UpdateDownloader(),
         preferences: UpdatePreferencesStore = UpdatePreferencesStore()) {
        let installation = UpdateInstallation.current(bundle: bundle)
        let config = UpdateSourceConfig.load(bundle: bundle)
        self.installation = installation
        self.config = config
        self.preferences = preferences
        self.engine = UpdateEngine(config: config, installation: installation,
                                   transport: transport, preferences: preferences)
        self.downloader = downloader
        self.autoCheck = preferences.preferences.autoCheck
        if let cached = preferences.cachedOutcome(for: installation.channel) {
            self.outcome = cached
            self.hasUpdate = cached.kind == .available
        }
    }

    var channelTitle: String {
        installation.channel == .dev ? "dev" : "stable"
    }

    var currentVersionText: String {
        // 构建号不上面向用户的 UI（2026-11-19 裁决）：只显纯版本号。
        installation.version
    }

    var isConfigured: Bool { config?.isConfigured == true }

    // MARK: - 生命周期

    /// 设置应用启动时调用一次；内部每小时检查是否到达 24 小时节流。
    func startAutoLoop() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runAutoCheckIfDue() }
        }
        runAutoCheckIfDue()
    }

    func runAutoCheckIfDue() {
        guard isConfigured, autoCheck, phase == .idle, checkTask == nil,
              engine.isAutoCheckDue() else { return }
        startCheck(automatic: true)
    }

    // MARK: - 检查（手动与自动同一条链）

    /// 一键入口：检查 →（有新版）下载 → 安装。无新版回到「检查更新」。
    func checkNow() {
        guard phase != .checking, phase != .downloading else { return }
        startCheck(automatic: false)
    }

    /// 自动检查发现新版后的静默预下载入口（不自动安装；按钮呈「一键更新到 X」）。
    private func startSilentPrefetch() {
        isSilentPrefetch = true
        startDownload()
    }

    private func startCheck(automatic: Bool) {
        phase = .checking
        errorMessage = nil
        lastInstallMessage = nil
        let previousOutcome = outcome
        checkTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.engine.check(automatic: automatic)
            await MainActor.run {
                self.checkTask = nil
                self.phase = .idle
                self.apply(result, previous: previousOutcome)
                if self.hasUpdate, self.downloadedFile == nil, automatic {
                    // 自动发现新版：静默预下载（裁决），UI 只显示「一键更新到 X」。
                    self.startSilentPrefetch()
                }
            }
        }
    }

    private func apply(_ result: UpdateCheckOutcome, previous: UpdateCheckOutcome?) {
        outcome = result
        hasUpdate = result.kind == .available
        pendingDataPackage = result.candidate?.manifest.dataPackage.flatMap {
            $0.platform == installation.platform ? $0 : nil
        }
        if result.kind == .available {
            downloadedFile = nil
            progress = 0
            return
        }
        // 检查失败不覆盖已知的新版信息；只更新错误提示。
        if result.kind == .networkError || result.kind == .rateLimited,
           previous?.kind == .available {
            outcome = previous
            hasUpdate = true
            errorMessage = result.message
            return
        }
        if result.kind == .networkError || result.kind == .rateLimited
            || result.kind == .invalidManifest || result.kind == .noManifest {
            errorMessage = result.message
        }
    }

    // MARK: - 下载与安装（一步化链路内部阶段）

    var candidate: UpdateCandidate? { outcome?.candidate }

    private func startDownload() {
        guard let candidate else { return }
        phase = .downloading
        progress = 0
        errorMessage = nil
        dataNotice = nil
        let dataPackage = pendingDataPackage
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let file = try await self.downloader.download(candidate) { fraction in
                    Task { @MainActor in
                        if self.phase == .downloading { self.progress = fraction }
                    }
                }
                // 数据包：主包就绪后按需下载（本地已有该数据版本则复用缓存）。
                var dataFile: URL?
                if let dataPackage {
                    let resolved = UpdateEngine.dataPackageRegistry.lookup(
                        manifestVersion: candidate.manifest.version,
                        buildNumber: candidate.manifest.buildNumber,
                        dataVersion: dataPackage.dataVersion)
                    dataFile = try await self.downloader.downloadDataPackage(
                        candidate: candidate, dataPackage: dataPackage, resolved: resolved) { fraction in
                        Task { @MainActor in
                            if case .downloading = self.phase { self.progress = fraction }
                        }
                    }
                }
                await MainActor.run {
                    self.downloadTask = nil
                    self.downloadedFile = file
                    self.downloadedDataFile = dataFile
                    self.progress = 1
                    self.installDownloaded()
                }
            } catch {
                await MainActor.run {
                    self.downloadTask = nil
                    self.phase = .idle
                    self.progress = 0
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        phase = .idle
        progress = 0
        errorMessage = "已取消下载"
    }

    static func phaseTitle(_ phase: UpdateInstallPhase) -> String {
        switch phase {
        case .extracting: return "解包安装内容…"
        case .validating: return "校验签名与身份…"
        case .replacing: return "安装中：替换文件"
        case .dataPackage: return "更新出厂数据…"
        case .restartingInputMethod: return "通知输入法重启…"
        case .done: return "完成"
        }
    }

    /// 安装已通过校验的安装包（就地热更新；链路的最后一段）。
    private func installDownloaded() {
        guard let candidate, let file = downloadedFile else { return }
        phase = .installing(.extracting)
        errorMessage = nil
        dataNotice = nil
        let dataZip = downloadedDataFile
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                let notice = try await Task.detached(priority: .userInitiated) {
                    try self.downloader.installInPlace(candidate, file: file,
                                                       dataPackageZip: dataZip) { phase in
                        Task { @MainActor in
                            if case .installing = self.phase { self.phase = .installing(phase) }
                        }
                    }
                }.value
                await MainActor.run {
                    self.installTask = nil
                    self.phase = .installed(notice)
                    self.dataNotice = notice
                    let version = candidate.manifest.version
                    self.lastInstallMessage = notice == nil
                        ? "已更新到 \(version)，下次打字生效。"
                        : "已更新到 \(version)，下次打字生效。\(notice!)"
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.installTask = nil
                    self.phase = .ready
                }
            } catch {
                await MainActor.run {
                    self.installTask = nil
                    if case .ready = self.phase { return }
                    // 回落：就地安装不可用（缺 xar/cpio 等）时保留旧路径。
                    if (error as? UpdateDownloadError) == .installerUnavailable
                        || (error as? UpdateInstallError) == .installerUnavailable {
                        self.fallbackToSystemInstaller(candidate, file: file)
                        return
                    }
                    self.phase = .ready
                    self.errorMessage = "就地更新失败（可重试）：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 旧的 open-installer 路径（fallback）：交给系统 Installer，用户点向导。
    private func fallbackToSystemInstaller(_ candidate: UpdateCandidate, file: URL) {
        do {
            try downloader.install(candidate, file: file)
            phase = .awaitingSystemInstaller
            fallbackNotice = "本环境缺少就地安装工具（xar/cpio 等），已改用系统安装器；按向导完成安装后重新打开设置。"
        } catch {
            phase = .ready
            errorMessage = "系统安装器也启动失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 按钮状态机（UpdateView 消费）

    enum ButtonState: Equatable {
        case check
        case checking
        case oneClickInstall(version: String)
        case downloading
        case installing
        case openInstaller
        case retry
        case updated(version: String)
    }

    /// 按钮状态：单按钮贯穿全流程（检查→下载→安装→完成；重试/打开安装器）。
    var buttonState: ButtonState {
        switch phase {
        case .checking:
            return .checking
        case .downloading:
            return .downloading
        case .installing:
            return .installing
        case .installed(let noticeVersion):
            return .updated(version: noticeVersion ?? outcome?.candidate?.manifest.version ?? installation.version)
        case .awaitingSystemInstaller:
            return .openInstaller
        case .idle, .ready:
            if errorMessage != nil { return .retry }
            if let version = outcome?.candidate?.manifest.version, hasUpdate {
                return .oneClickInstall(version: version)
            }
            return .check
        }
    }

    /// 按钮点击：按当前阶段继续同一条链（检查/一键安装/重试/打开安装器）。
    func primaryAction() {
        switch buttonState {
        case .check, .retry:
            checkNow()
        case .oneClickInstall:
            startDownload()
        case .openInstaller:
            // 系统安装器可能被用户关闭而未装完：重新打开（包已在本地缓存）。
            if let candidate, let file = downloadedFile {
                fallbackToSystemInstaller(candidate, file: file)
            } else {
                checkNow()
            }
        case .checking, .downloading, .installing, .updated:
            break
        }
    }

    /// 按钮旁的状态行：各阶段人话描述（含下载百分比与安装阶段）。
    var statusLine: String? {
        switch phase {
        case .checking:
            return "检查中…"
        case .downloading:
            return isSilentPrefetch
                ? "已发现新版，正在后台预下载 \(Int((progress * 100).rounded()))%"
                : "下载中 \(Int((progress * 100).rounded()))%"
        case .installing(let installPhase):
            return Self.phaseTitle(installPhase)
        case .installed:
            return lastInstallMessage
        case .awaitingSystemInstaller:
            return fallbackNotice
        case .idle, .ready:
            return nil
        }
    }

    // MARK: - 偏好

    func setAutoCheck(_ enabled: Bool) {
        do {
            try preferences.setAutoCheck(enabled)
            autoCheck = enabled
            if enabled { runAutoCheckIfDue() }
        } catch {
            errorMessage = "保存自动检查偏好失败：\(error.localizedDescription)"
        }
    }
}

/// 独立更新窗口（关于页「检查更新」打开）。单按钮一步化：
/// 检查 →（有新版）自动下载安装 → 完成；不弹系统安装器（fallback 除外）。
struct UpdateView: View {
    @ObservedObject private var controller = UpdateController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(SettingsPalette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusBlock
                    if let candidate = controller.candidate, controller.hasUpdate {
                        releaseBlock(candidate)
                    }
                    if controller.phase == .downloading, !controller.isSilentPrefetch {
                        downloadBlock
                    }
                    if let line = controller.statusLine {
                        Text(line)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SettingsPalette.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = controller.errorMessage {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let message = controller.dataNotice {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(SettingsPalette.border)
            footer
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(SettingsPalette.windowBackground)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("检查更新")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SettingsPalette.primaryText)
                Text("当前版本 \(controller.currentVersionText) · \(controller.channelTitle) 通道")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SettingsPalette.secondaryText)
            }
            Spacer()
            primaryButton
        }
        .padding(22)
    }

    /// 单按钮：检查更新 → 下载中 → 安装中 → 已更新；失败变重试；
    /// fallback 变打开安装器。检查/下载/安装阶段置灰。
    @ViewBuilder
    private var primaryButton: some View {
        switch controller.buttonState {
        case .check:
            button("检查更新", prominent: true) { controller.primaryAction() }
        case .checking:
            button("检查中…", prominent: true) {}
        case let .oneClickInstall(version):
            button("一键更新到 \(version)", prominent: true) { controller.primaryAction() }
        case .downloading:
            button("下载中…", prominent: true) {}
        case .installing:
            button("安装中…", prominent: true) {}
        case .openInstaller:
            button("打开安装器", prominent: true) { controller.primaryAction() }
        case .retry:
            button("重试", prominent: true) { controller.primaryAction() }
        case let .updated(version):
            button("已更新到 \(version)", prominent: false) {}
        }
    }

    private func button(_ title: String, prominent: Bool,
                        action: @escaping () -> Void) -> some View {
        Group {
            if prominent {
                Button(title, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(SettingsPalette.accent)
            } else {
                Button(title, action: action)
                    .buttonStyle(.bordered)
                    .disabled(true)
            }
        }
        .font(.system(size: 12))
        .disabled(title.hasSuffix("…"))
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !controller.isConfigured {
                Label("未配置更新源", systemImage: "questionmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.orange)
                Text("本机构建没有发布仓库地址或可信公钥；不能据此判断是否有新版本。发布流程见 docs/update.md。")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if controller.hasUpdate {
                EmptyView()
            } else if let outcome = controller.outcome {
                Label(outcomeTitle(outcome), systemImage: outcomeIcon(outcome))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(outcomeColor(outcome))
                Text(outcome.message)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsPalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("尚未检查。点击「检查更新」自动完成检查、下载与安装；不会弹出系统安装器。")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsPalette.secondaryText)
            }
        }
    }

    private func releaseBlock(_ candidate: UpdateCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("新版 \(candidate.manifest.version)")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: candidate.asset.size, countStyle: .file))
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondaryText)
            }
            // 说明区是清单里的应用内短文本（纯文本）：发布侧保证不超 12 行；
            // 再长由外层 ScrollView 滚动，不嵌套内层滚动视图（会抢手势）。
            Text(candidate.manifest.notes)
                .font(.system(size: 12))
                .foregroundStyle(SettingsPalette.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(SettingsPalette.secondaryText.opacity(0.06)))
            Text("点击「一键更新到 \(candidate.manifest.version)」自动完成下载、校验与就地安装；不会弹出系统安装器，失败会自动恢复旧版本。")
                .font(.system(size: 11))
                .foregroundStyle(SettingsPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let data = controller.pendingDataPackage {
                // 数据包文件名与数据版本指纹属内部身份，不在 UI 展示（2026-11-19 同口径）。
                Text("本次更新包含出厂数据（\(ByteCountFormatter.string(fromByteCount: data.size, countStyle: .file))）；本地已有同版本数据时不重复下载。")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var downloadBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: controller.progress)
            HStack {
                Text("下载中 \(Int((controller.progress * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SettingsPalette.secondaryText)
                Spacer()
                Button("取消") { controller.cancelDownload() }
                    .font(.system(size: 11))
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { controller.autoCheck },
                                 set: { controller.setAutoCheck($0) })) {
                Text("自动检查更新")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text("默认关闭。开启后仅在设置应用启动及运行期间每天最多尝试一次；发现新版只静默预下载，安装仍需点击「一键更新」。不会在输入按键路径检查。检查会连接 GitHub，不携带输入内容、火山凭据、学习记录或设备唯一标识。")
                .font(.system(size: 10.5))
                .foregroundStyle(SettingsPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
    }

    private func outcomeTitle(_ outcome: UpdateCheckOutcome) -> String {
        switch outcome.kind {
        case .available: return "发现新版本"
        case .upToDate: return "已是最新"
        case .unconfigured: return "未配置更新源"
        case .unsupported: return "当前系统不支持该版本"
        case .noManifest: return "发布缺少更新清单"
        case .invalidManifest: return "更新清单校验失败"
        case .rateLimited: return "更新服务请求受限"
        case .networkError: return "无法连接更新服务"
        case .noRelease: return "没有可用发布"
        case .skipped: return "今日已自动检查"
        }
    }

    private func outcomeIcon(_ outcome: UpdateCheckOutcome) -> String {
        switch outcome.kind {
        case .available: return "arrow.down.circle"
        case .upToDate: return "checkmark.circle"
        case .invalidManifest, .noManifest, .unconfigured: return "exclamationmark.triangle"
        case .unsupported: return "desktopcomputer"
        case .rateLimited, .networkError, .noRelease: return "wifi.exclamationmark"
        case .skipped: return "clock"
        }
    }

    private func outcomeColor(_ outcome: UpdateCheckOutcome) -> Color {
        switch outcome.kind {
        case .available: return SettingsPalette.accent
        case .upToDate: return .green
        case .invalidManifest, .noManifest, .unconfigured, .rateLimited, .networkError, .noRelease:
            return .orange
        case .unsupported: return .orange
        case .skipped: return SettingsPalette.secondaryText
        }
    }
}
