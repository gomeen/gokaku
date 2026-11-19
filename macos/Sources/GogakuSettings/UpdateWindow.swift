import SwiftUI
import AppKit
import GogakuKit

/// 检查更新控制器。只在设置应用内运行：输入法进程不发起更新请求，也不在
/// 按键路径执行网络或磁盘检查。自动检查默认关闭；开启后设置应用启动及运行
/// 期间按 24 小时间隔尝试，失败不紧密重试。发现新版只在设置内提示，不抢焦点。
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

    let installation: UpdateInstallation
    private let config: UpdateSourceConfig?
    private let preferences: UpdatePreferencesStore
    private let engine: UpdateEngine
    private let downloader: UpdateDownloader
    private var checkTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
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
        "\(installation.version)（构建 \(installation.buildNumber)）"
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

    // MARK: - 手动／自动检查

    func checkNow() {
        guard phase != .checking, phase != .downloading else { return }
        startCheck(automatic: false)
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

    // MARK: - 下载与安装

    var candidate: UpdateCandidate? { outcome?.candidate }

    func download() {
        guard let candidate else { return }
        guard phase == .idle || phase == .ready else { return }
        phase = .downloading
        progress = 0
        errorMessage = nil
        lastInstallMessage = nil
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
                    self.phase = .ready
                    self.progress = 1
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

    /// 就地更新的已下载数据包 zip（跟随下载阶段填充）。
    @Published private(set) var downloadedDataFile: URL?

    static func phaseTitle(_ phase: UpdateInstallPhase) -> String {
        switch phase {
        case .extracting: return "解包安装内容…"
        case .validating: return "校验签名与身份…"
        case .replacing: return "替换应用…"
        case .dataPackage: return "更新出厂数据…"
        case .restartingInputMethod: return "通知输入法重启…"
        case .done: return "完成"
        }
    }

    /// 「就地更新（不弹安装器）」：客户端自己完成解包→校验→事务替换→
    /// 输入法交接。工具链缺失（installerUnavailable）时回落旧的 open-installer。
    func install() {
        guard let candidate, let file = downloadedFile else { return }
        guard phase == .idle || phase == .ready else { return }
        do {
            try downloader.verifyBeforeInstall(candidate, file: file)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        phase = .installing(.extracting)
        errorMessage = nil
        lastInstallMessage = nil
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
                        ? "已更新到 \(version)；输入法将在下次激活时使用新版。"
                        : "已更新到 \(version)；输入法将在下次激活时使用新版。\(notice!)"
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

    private var installTask: Task<Void, Never>?

    /// 旧的 open-installer 路径（fallback）：交给系统 Installer，用户点向导。
    private func fallbackToSystemInstaller(_ candidate: UpdateCandidate, file: URL) {
        do {
            try downloader.install(candidate, file: file)
            phase = .idle
            lastInstallMessage = "已打开系统安装器；按向导完成安装后重新打开设置。"
        } catch {
            phase = .ready
            errorMessage = "系统安装器也启动失败：\(error.localizedDescription)"
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

/// 独立更新窗口（版本信息旁「检查更新」打开）。不自动下载、不自动安装。
struct UpdateView: View {
    @ObservedObject private var controller = UpdateController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(SettingsPalette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusBlock
                    if let candidate = controller.candidate {
                        releaseBlock(candidate)
                    }
                    if controller.phase == .downloading {
                        downloadBlock
                    }
                    if case let .installing(installPhase) = controller.phase {
                        installingBlock(installPhase)
                    }
                    if controller.phase == .ready {
                        readyBlock
                    }
                    if let error = controller.errorMessage {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let message = controller.lastInstallMessage {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.green)
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
            if controller.phase == .checking {
                ProgressView().controlSize(.small)
            } else {
                Button("检查更新") { controller.checkNow() }
                    .font(.system(size: 12))
                    .disabled(controller.phase == .downloading || controller.phase == .checking)
            }
        }
        .padding(22)
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
            } else if let outcome = controller.outcome {
                Label(outcomeTitle(outcome), systemImage: outcomeIcon(outcome))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(outcomeColor(outcome))
                Text(outcome.message)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsPalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("尚未检查。手动检查始终可用；自动检查默认关闭。")
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
                Text("构建 \(candidate.manifest.buildNumber)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SettingsPalette.secondaryText)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: candidate.asset.size, countStyle: .file))
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondaryText)
            }
            Text(candidate.manifest.notes)
                .font(.system(size: 12))
                .foregroundStyle(SettingsPalette.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(SettingsPalette.secondaryText.opacity(0.06)))
            HStack(spacing: 10) {
                if controller.phase == .ready {
                    Button("就地更新（不弹安装器）") { controller.install() }
                        .buttonStyle(.borderedProminent)
                        .tint(SettingsPalette.accent)
                } else {
                    Button("下载安装包") { controller.download() }
                        .buttonStyle(.borderedProminent)
                        .tint(SettingsPalette.accent)
                        .disabled(controller.phase != .idle)
                }
                Text("签名已验证；下载后还会核对大小与 SHA-256。")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondaryText)
            }
            if let data = controller.pendingDataPackage {
                Text("新版包含数据包 \(data.name)（\(ByteCountFormatter.string(fromByteCount: data.size, countStyle: .file))，数据版本 \(data.dataVersion)）；本地已有同版本数据时不再下载。")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func installingBlock(_ phase: UpdateInstallPhase) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(UpdateController.phaseTitle(phase))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SettingsPalette.primaryText)
            }
            Text("解包 → 校验 → 替换 → 重启输入法 → 完成；不会弹出系统安装器，失败会自动恢复旧版本。")
                .font(.system(size: 11))
                .foregroundStyle(SettingsPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
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

    private var readyBlock: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(Color.green)
            Text("安装包已下载并通过校验。点击「就地更新（不弹安装器）」由客户端完成替换；不会自动重启，输入法下次激活时用新版。")
                .font(.system(size: 11))
                .foregroundStyle(SettingsPalette.secondaryText)
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
            Text("默认关闭。开启后仅在设置应用启动及运行期间每天最多尝试一次；不自动下载、安装或重启，不会在输入按键路径检查。检查会连接 GitHub，不携带输入内容、火山凭据、学习记录或设备唯一标识。")
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
