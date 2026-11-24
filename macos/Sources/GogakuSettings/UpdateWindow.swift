import SwiftUI
import AppKit
import GogakuKit

/// 更新仅在设置应用内运行。手动与自动检查都只读取元数据，
/// 只有用户在关于页确认「下载并更新」才进入下载和安装。
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
    @Published private(set) var lastAutoAttempt: Date?
    @Published private(set) var autoCheckPreferenceError: String?
    @Published private(set) var lastInstallMessage: String?
    /// 数据包部分成功说明（主包已装、数据未换时的词库回退提示）。
    @Published private(set) var dataNotice: String?
    /// 就地安装需要下载的数据包资产（schema 2；nil＝无数据包或 schema 1 清单）。
    @Published private(set) var pendingDataPackage: UpdateDataPackage?
    /// 就地更新的已下载数据包 zip（跟随下载阶段填充）。
    @Published private(set) var downloadedDataFile: URL?
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

    convenience init(bundle: Bundle = .main,
         transport: UpdateTransport = URLSessionUpdateTransport(),
         downloader: UpdateDownloader = UpdateDownloader(),
         preferences: UpdatePreferencesStore = UpdatePreferencesStore()) {
        self.init(installation: UpdateInstallation.current(bundle: bundle),
                  config: UpdateSourceConfig.load(bundle: bundle), transport: transport,
                  downloader: downloader, preferences: preferences)
    }

    init(installation: UpdateInstallation, config: UpdateSourceConfig?,
         transport: UpdateTransport, downloader: UpdateDownloader,
         preferences: UpdatePreferencesStore, now: @escaping () -> Date = Date.init) {
        self.installation = installation
        self.config = config
        self.preferences = preferences
        self.engine = UpdateEngine(config: config, installation: installation,
                                   transport: transport, preferences: preferences, now: now)
        self.downloader = downloader
        self.autoCheck = preferences.preferences.autoCheck
        self.lastAutoAttempt = savedAutoAttempt
    }

    private var savedAutoAttempt: Date? {
        preferences.preferences.lastAutoCheck[installation.channel.rawValue]
            .map { Date(timeIntervalSince1970: $0) }
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

    @discardableResult
    func runAutoCheckIfDue() -> Task<Void, Never>? {
        guard isConfigured, autoCheck, phase == .idle, canCheck,
              engine.isAutoCheckDue() else { return nil }
        return startCheck(automatic: true)
    }

    var canCheck: Bool {
        (phase == .idle || phase == .ready) && checkTask == nil && downloadTask == nil
    }

    @discardableResult
    func checkNow() -> Task<Void, Never>? {
        guard canCheck else { return nil }
        return startCheck(automatic: false)
    }

    private func startCheck(automatic: Bool) -> Task<Void, Never> {
        phase = .checking
        outcome = nil
        pendingDataPackage = nil
        downloadedFile = nil
        downloadedDataFile = nil
        progress = 0
        errorMessage = nil
        dataNotice = nil
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await self.engine.check(automatic: automatic)
            self.checkTask = nil
            self.lastAutoAttempt = self.savedAutoAttempt
            self.outcome = result
            self.pendingDataPackage = result.dataPackage
            self.phase = .idle
        }
        checkTask = task
        return task
    }

    // MARK: - 用户确认后的下载与安装

    var candidate: UpdateCandidate? { outcome?.kind == .available ? outcome?.candidate : nil }

    @discardableResult
    func downloadAndUpdate() -> Task<Void, Never>? {
        guard canCheck, let candidate else { return nil }
        phase = .downloading
        progress = 0
        errorMessage = nil
        dataNotice = nil
        let dataPackage = pendingDataPackage
        let task = Task { [weak self] in
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
                try Task.checkCancellation()
                self.downloadTask = nil
                self.downloadedFile = file
                self.downloadedDataFile = dataFile
                self.progress = 1
                self.installDownloaded()
            } catch {
                self.downloadTask = nil
                self.phase = .idle
                self.progress = 0
                self.errorMessage = Task.isCancelled ? "已取消下载" : error.localizedDescription
            }
        }
        downloadTask = task
        return task
    }

    func cancelDownload() {
        guard phase == .downloading, let downloadTask else { return }
        downloadTask.cancel()
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

    func retryInstall() {
        guard phase == .ready else { return }
        installDownloaded()
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

    func openSystemInstaller() {
        guard phase == .awaitingSystemInstaller, let candidate, let file = downloadedFile else { return }
        errorMessage = nil
        fallbackToSystemInstaller(candidate, file: file)
    }

    var statusLine: String {
        switch phase {
        case .checking:
            return "检查中…"
        case .downloading:
            return "下载中 \(Int((progress * 100).rounded()))%"
        case .installing(let installPhase):
            return Self.phaseTitle(installPhase)
        case .installed:
            return lastInstallMessage ?? "已完成更新"
        case .awaitingSystemInstaller:
            return fallbackNotice ?? "请在系统安装器完成更新"
        case .idle, .ready:
            return outcome?.message ?? (isConfigured ? "尚未检查" : "未配置更新源")
        }
    }

    // MARK: - 偏好

    @discardableResult
    func setAutoCheck(_ enabled: Bool) -> Task<Void, Never>? {
        do {
            try preferences.setAutoCheck(enabled)
            autoCheck = enabled
            autoCheckPreferenceError = nil
            return enabled ? runAutoCheckIfDue() : nil
        } catch {
            autoCheckPreferenceError = "保存自动检查偏好失败：\(error.localizedDescription)"
            return nil
        }
    }
}

/// 只读发布说明。调用端传入快照，定时检查不会替换用户正在阅读的内容。
struct UpdateNotesView: View {
    let version: String
    let notes: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gogaku \(version) · 更新说明")
                .font(.title3.bold())
            ScrollView {
                Text(notes.isEmpty ? "没有附带更新说明。" : notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 500, height: 320)
    }
}
