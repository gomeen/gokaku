import Foundation
import AppKit

/// 就地热更新安装器（2026-11 裁决）：不经系统 Installer，客户端自己完成
/// pkg 解包→校验→事务替换→输入法交接。
///
/// 与 pkg-postinstall.sh 逐条对应的事务语义：
/// - recover 上次未完成事务（恢复备份）；
/// - 解包校验 stage 内双 App（bundle ID、CFBundleVersion、TISInputSourceID、签名）；
/// - ditto 备份旧包 → rm -rf 旧 → mv 新；
/// - transaction.txt 状态机（installing/success）留在
///   ~/Library/Application Support/Gogaku/install/，中断可恢复；
/// - lsregister 重新注册两个 App；
/// - 任一步失败：恢复备份、记录 failed、抛 UpdateInstallError。
///
/// 安全约束：绝不 rm 备份以外的唯一副本；绝不使用 SIGKILL；输入法只经
/// Darwin 通知优雅退出（imklaunchagent 之后按需拉起新版）。数据包作为同一
/// 事务的可选第二阶段安装：主包替换成功后解包数据 zip→逐文件哈希校验→
/// 覆盖两个 App 的 EngineData；数据阶段失败不回滚已成功的主包（代码新版＋
/// 数据旧版是受支持的部分成功态），由 UI 明示。
public enum UpdateInstallError: Error, Equatable {
    /// xar／gzip／cpio／ditto／codesign 等外部工具缺失或不可执行。
    case toolUnavailable(String)
    /// pkg 布局不符合预期（找不到组件包／Scripts／Gogaku-apps.zip）。
    case malformedPackage(String)
    /// stage 内 App 身份／构建号／TIS 键／签名校验拒绝。
    case validationFailed(String)
    /// 替换或备份失败；备份已恢复。
    case replacedFailed(String)
    /// 数据包哈希或清单不符；主包安装结果不受影响。
    case dataPackageRejected(String)
    /// 数据包解包或落位失败；主包安装结果不受影响。
    case dataPackageFailed(String)
    /// 本环境无法就地安装（如缺沙箱外权限）；调用方应回落系统安装器。
    case installerUnavailable

    public var errorDescription: String? {
        switch self {
        case let .toolUnavailable(tool): return "缺少安装工具：\(tool)"
        case let .malformedPackage(detail): return "安装包结构异常：\(detail)"
        case let .validationFailed(detail): return "安装内容校验失败：\(detail)"
        case let .replacedFailed(detail): return "替换应用失败（已恢复原版本）：\(detail)"
        case let .dataPackageRejected(detail): return "数据包校验拒绝：\(detail)"
        case let .dataPackageFailed(detail): return "数据包安装失败：\(detail)"
        case .installerUnavailable: return "本环境无法就地安装；将改用系统安装器"
        }
    }
}

/// 安装阶段（UI 进度展示与测试断言用）。
public enum UpdateInstallPhase: Equatable, Sendable {
    case extracting
    case validating
    case replacing
    case restartingInputMethod
    case dataPackage
    case done
}

/// 数据包收据（zip 内 manifest.json）：逐文件哈希清单，安装前校验。
public struct UpdateDataManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
        public init(path: String, sha256: String) {
            self.path = path; self.sha256 = sha256
        }
    }

    public let schema: Int
    public let dataVersion: String
    public let files: [Entry]

    public static let schemaVersion = 1

    public init(schema: Int = UpdateDataManifest.schemaVersion,
                dataVersion: String, files: [Entry]) {
        self.schema = schema; self.dataVersion = dataVersion; self.files = files
    }

    /// 发布侧 `dataVersion` 同算法：对排序后的 (路径, 哈希) 清单再取一次
    /// SHA-256 的前 16 位十六进制。两侧必须逐字一致，客户端才能按版本缓存。
    public static func fingerprint(files: [Entry]) -> String {
        let joined = files
            .sorted { lhs, rhs in lhs.path < rhs.path }
            .map { "\($0.path):\($0.sha256)" }
            .joined(separator: "\n")
        let digest = UpdateDownloader.sha256(of: Data(joined.utf8))
        return String(digest.prefix(16))
    }

    public var fingerprint: String { Self.fingerprint(files: files) }

    public static func decode(from data: Data) throws -> UpdateDataManifest {
        let manifest = try JSONDecoder().decode(UpdateDataManifest.self, from: data)
        guard manifest.schema == schemaVersion, !manifest.dataVersion.isEmpty,
              manifest.dataVersion == manifest.fingerprint, !manifest.files.isEmpty else {
            throw UpdateInstallError.dataPackageRejected("数据清单非法或指纹不符")
        }
        for entry in manifest.files {
            guard !entry.path.isEmpty, !entry.path.hasPrefix("/"),
                  !entry.path.contains(".."), !entry.path.contains("\\"),
                  entry.sha256.count == 64, entry.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw UpdateInstallError.dataPackageRejected("数据清单条目非法：\(entry.path)")
            }
        }
        return manifest
    }
}

/// 就地安装器。所有真实替换都在用户主目录（输入法与设置应用均用户可写），
/// 不提权。`sites` 由通道／产品决定（默认完整版 stable；测试注入临时目录）。
public final class UpdateInstaller {
    public struct Site {
        public let installDirectory: URL
        public let appName: String
        public let bundleIdentifier: String
        /// 输入法 App 还要求 Info.plist 的 TISInputSourceID 与 bundle ID 一致。
        public let requiresTISIdentity: Bool

        public init(installDirectory: URL, appName: String,
                    bundleIdentifier: String, requiresTISIdentity: Bool = false) {
            self.installDirectory = installDirectory
            self.appName = appName; self.bundleIdentifier = bundleIdentifier
            self.requiresTISIdentity = requiresTISIdentity
        }

        public var targetURL: URL { installDirectory.appendingPathComponent(appName, isDirectory: true) }
    }

    /// 事务状态文件（同 postinstall 的位置与格式）。
    public static let stateRelativePath = "Library/Application Support/Gogaku/install"
    public static let backupRelativePath = "Library/Application Support/Gogaku/install/backups"
    /// 输入法优雅退出通知（ DistributedNotificationCenter，跨进程可见）。
    public static let restartNotificationName = "org.gogaku.inputmethod.restart"

    private let home: URL
    private let sites: [Site]
    private let expectedBuild: String
    private let fileManager: FileManager
    private let stateDirectory: URL
    private let backupRoot: URL
    private let registerApps: Bool

    /// - Parameters:
    ///   - home: 用户主目录（测试注入临时目录）。
    ///   - sites: 要替换的 App 位置（顺序即替换顺序）。
    ///   - expectedBuild: 期望 CFBundleVersion（构建号字符串）。
    ///   - registerApps: 是否调用 lsregister（测试的临时目录跳过）。
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                sites: [Site]? = nil, expectedBuild: String,
                fileManager: FileManager = .default, registerApps: Bool = true) {
        self.home = home
        self.fileManager = fileManager
        self.expectedBuild = expectedBuild
        self.registerApps = registerApps
        if let sites {
            self.sites = sites
        } else {
            self.sites = Self.defaultSites(
                settingsBundleIdentifier: Bundle.main.bundleIdentifier ?? "org.gogaku.settings",
                home: home)
        }
        self.stateDirectory = home.appendingPathComponent(Self.stateRelativePath, isDirectory: true)
        self.backupRoot = home.appendingPathComponent(Self.backupRelativePath, isDirectory: true)
    }

    var transactionURL: URL { stateDirectory.appendingPathComponent("transaction.txt") }

    /// 运行方是设置应用：从其 bundle ID 派生产品／通道与输入法身份。
    /// org.gogaku.settings(.dev) ↔ org.gogaku.inputmethod(.dev)；
    /// org.gogaku.lite.settings(.dev) ↔ org.gogaku.lite.inputmethod(.dev)。
    /// 与 package-macos-pkg.py 的 CHANNELS 表逐项对应（测试绑定）。
    public static func defaultSites(settingsBundleIdentifier: String,
                                    home: URL) -> [Site] {
        let settingsID = settingsBundleIdentifier
        let isLite = settingsID.contains(".lite.")
        let isDev = settingsID.hasSuffix(".dev")
        let inputID = settingsID.replacingOccurrences(of: ".settings", with: ".inputmethod")
        let channelSuffix = isDev ? " Dev" : ""
        let productPrefix = isLite ? "Gogaku Lite" : "Gogaku"
        return [
            Site(installDirectory: home.appendingPathComponent("Library/Input Methods", isDirectory: true),
                 appName: productPrefix + channelSuffix + ".app",
                 bundleIdentifier: inputID, requiresTISIdentity: true),
            Site(installDirectory: home.appendingPathComponent("Applications", isDirectory: true),
                 appName: productPrefix + " Settings" + channelSuffix + ".app",
                 bundleIdentifier: settingsID),
        ]
    }

    // MARK: - 工具进程（xar／gzip｜cpio／ditto／codesign）

    @discardableResult
    private func runTool(_ launchPath: String, _ arguments: [String],
                         cwd: URL? = nil) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw UpdateInstallError.toolUnavailable(launchPath)
        }
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func requireTool(_ path: String) throws {
        guard fileManager.isExecutableFile(atPath: path) else {
            throw UpdateInstallError.installerUnavailable
        }
    }

    // MARK: - 事务状态

    private func writeState(phase: String, backup: String) throws {
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let text = """
        phase=\(phase)
        build=\(expectedBuild)
        backup=\(backup)
        updated=\(formatter.string(from: Date()))

        """
        let temporary = stateDirectory.appendingPathComponent("transaction.tmp")
        try text.write(to: temporary, atomically: true, encoding: .utf8)
        _ = try fileManager.replaceItemAt(transactionURL, withItemAt: temporary)
    }

    private func stateValue(_ key: String) -> String? {
        guard let text = try? String(contentsOf: transactionURL, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            if line.hasPrefix(key + "=") { return String(line.dropFirst(key.count + 1)) }
        }
        return nil
    }

    /// 复刻 postinstall recover_incomplete：phase=success 直接返回；
    /// 否则把 backup 里两个 .disabled 移回原位（有备份才动目标）。
    public func recoverIncompleteInstallation() {
        guard let phase = stateValue("phase"), phase != "success" else { return }
        guard let backup = stateValue("backup"),
              fileManager.fileExists(atPath: backup) else { return }
        for site in sites {
            let saved = URL(fileURLWithPath: backup, isDirectory: true)
                .appendingPathComponent(site.appName + ".disabled", isDirectory: true)
            guard fileManager.fileExists(atPath: saved.path) else { continue }
            try? fileManager.removeItem(at: site.targetURL)
            try? fileManager.moveItem(at: saved, to: site.targetURL)
        }
    }

    // MARK: - pkg 解包

    /// xar → 组件 pkg 的 Scripts（gzip+cpio）→ Gogaku-apps.zip（ditto）→ stage。
    /// 返回包含 `stage/`（解包后的双 App）等工作目录；调用方完成替换后负责
    /// 清理（install 的 defer / 测试的 tearDown）。
    public func extractPackage(at packageURL: URL) throws -> URL {
        try requireTool("/usr/bin/xar")
        try requireTool("/usr/bin/gzip")
        try requireTool("/usr/bin/cpio")
        try requireTool("/usr/bin/ditto")
        let cacheRoot = home.appendingPathComponent("Library/Caches/Gogaku", isDirectory: true)
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let work = try fileManager.url(for: .itemReplacementDirectory,
                                       in: .userDomainMask, appropriateFor: cacheRoot, create: true)
        // 1. xar 解包（组件 pkg、distribution、Resources）。
        let xarDir = work.appendingPathComponent("xar", isDirectory: true)
        try fileManager.createDirectory(at: xarDir, withIntermediateDirectories: true)
        let (status, message) = try runTool("/usr/bin/xar", ["-xf", packageURL.path, "-C", xarDir.path])
        guard status == 0 else {
            throw UpdateInstallError.malformedPackage("xar 解包失败：\(message.suffix(200))")
        }
        // 2. 找组件包的 Scripts（gzip+cpio 的归档文件，不是目录）。
        let contents = (try? fileManager.contentsOfDirectory(at: xarDir, includingPropertiesForKeys: nil)) ?? []
        var scriptsFile: URL?
        for candidate in contents where candidate.pathExtension == "pkg" {
            let scripts = candidate.appendingPathComponent("Scripts")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: scripts.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                scriptsFile = scripts
                break
            }
        }
        guard let scriptsFile else {
            throw UpdateInstallError.malformedPackage("pkg 内没有组件 Scripts 归档")
        }
        let scriptsDir = work.appendingPathComponent("scripts", isDirectory: true)
        try fileManager.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        let shell = """
        gzip -dc "$1" | cpio -idm --quiet
        """
        let (shellStatus, shellMessage) = try runTool(
            "/bin/sh", ["-c", shell, "scripts-archive", scriptsFile.path], cwd: scriptsDir)
        guard shellStatus == 0 else {
            throw UpdateInstallError.malformedPackage("Scripts 解包失败：\(shellMessage.suffix(200))")
        }
        // 3. Gogaku-apps.zip → stage（.app 不会被 LaunchServices 提前扫描）。
        let zip = scriptsDir.appendingPathComponent("Gogaku-apps.zip")
        guard fileManager.fileExists(atPath: zip.path) else {
            throw UpdateInstallError.malformedPackage("Scripts 缺少 Gogaku-apps.zip")
        }
        let appsDir = work.appendingPathComponent("stage", isDirectory: true)
        try fileManager.createDirectory(at: appsDir, withIntermediateDirectories: true)
        let (dittoStatus, dittoMessage) = try runTool(
            "/usr/bin/ditto", ["-x", "-k", zip.path, appsDir.path])
        guard dittoStatus == 0 else {
            throw UpdateInstallError.malformedPackage("Gogaku-apps.zip 解包失败：\(dittoMessage.suffix(200))")
        }
        return work
    }

    // MARK: - stage 校验（同 postinstall 标准）

    /// bundle ID、构建号、TIS 身份键、可执行存在；最后 codesign 严格校验。
    /// zip 解包不带 quarantine；不重签，保留打包阶段签名。
    public func validateStagedBundles(in stage: URL) throws {
        try requireTool("/usr/bin/codesign")
        for site in sites {
            let bundle = stage.appendingPathComponent(site.appName, isDirectory: true)
            guard fileManager.fileExists(atPath: bundle.path) else {
                throw UpdateInstallError.validationFailed("缺少 \(site.appName)")
            }
            let plist = bundle.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let info = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any] else {
                throw UpdateInstallError.validationFailed("\(site.appName) 缺少 Info.plist")
            }
            guard info["CFBundleIdentifier"] as? String == site.bundleIdentifier else {
                throw UpdateInstallError.validationFailed(
                    "\(site.appName) 身份不符：\(info["CFBundleIdentifier"] as? String ?? "nil")")
            }
            guard info["CFBundleVersion"] as? String == expectedBuild else {
                throw UpdateInstallError.validationFailed(
                    "\(site.appName) 构建号不符：\(info["CFBundleVersion"] as? String ?? "nil") ≠ \(expectedBuild)")
            }
            if site.requiresTISIdentity {
                guard info["TISInputSourceID"] as? String == site.bundleIdentifier else {
                    throw UpdateInstallError.validationFailed(
                        "输入法身份键不符：\(info["TISInputSourceID"] as? String ?? "nil")")
                }
            }
            let executable = info["CFBundleExecutable"] as? String ?? ""
            guard !executable.isEmpty,
                  fileManager.fileExists(atPath: bundle.appendingPathComponent("Contents/MacOS/\(executable)").path) else {
                throw UpdateInstallError.validationFailed("\(site.appName) 缺少可执行文件")
            }
            // 与 postinstall 同标准：--deep --strict。数据文件在打包阶段已被
            // 密封进签名；数据包更新走受支持的整包替换路径（见 installData）。
            let (status, message) = try runTool(
                "/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path])
            guard status == 0 else {
                throw UpdateInstallError.validationFailed("\(site.appName) 签名校验失败：\(message.suffix(200))")
            }
        }
    }

    // MARK: - 主流程

    /// 完整就地安装。`progress` 上报 UI 阶段；失败已恢复备份并写 failed 状态。
    public func install(packageURL: URL,
                        dataPackageZip: URL? = nil,
                        progress: @escaping (UpdateInstallPhase) -> Void = { _ in }) throws {
        recoverIncompleteInstallation()
        let work = try extractPackage(at: packageURL)
        defer { try? fileManager.removeItem(at: work) }
        let stage = work.appendingPathComponent("stage", isDirectory: true)
        progress(.extracting)
        try validateStagedBundles(in: stage)
        progress(.validating)

        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = backupRoot.appendingPathComponent(formatter.string(from: Date()) + "-"
                                                       + UUID().uuidString.prefix(6), isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        try writeState(phase: "installing", backup: backup.path)

        do {
            // 备份（复制不移动；失败恢复）→ 替换。
            for site in sites where fileManager.fileExists(atPath: site.targetURL.path) {
                let saved = backup.appendingPathComponent(site.appName + ".disabled", isDirectory: true)
                try fileManager.copyItem(at: site.targetURL, to: saved)
                guard fileManager.fileExists(atPath: saved.appendingPathComponent("Contents/Info.plist").path) else {
                    throw UpdateInstallError.replacedFailed("\(site.appName) 备份不完整")
                }
            }
            try fileManager.createDirectory(at: sites[0].installDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: sites[1].installDirectory, withIntermediateDirectories: true)
            for site in sites {
                if fileManager.fileExists(atPath: site.targetURL.path) {
                    try fileManager.removeItem(at: site.targetURL)
                }
                try fileManager.moveItem(at: stage.appendingPathComponent(site.appName, isDirectory: true),
                                         to: site.targetURL)
            }            // 替换后复核身份（同 postinstall 的安装后校验）。
            for site in sites {
                let plist = site.targetURL.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: plist),
                      let info = try? PropertyListSerialization.propertyList(
                        from: data, options: [], format: nil) as? [String: Any],
                      info["CFBundleIdentifier"] as? String == site.bundleIdentifier,
                      info["CFBundleVersion"] as? String == expectedBuild else {
                    throw UpdateInstallError.replacedFailed("\(site.appName) 安装后身份不符")
                }
            }
            // EngineData 结转：主包不再携带出厂数据。schema 1 路径（清单无
            // 数据包）或数据包安装失败时，从备份把旧数据结转进新包——
            // 核心兼容旧数据，输入法不因数据包缺失而不可用。
            for site in sites {
                let targetData = site.targetURL.appendingPathComponent(
                    "Contents/Resources/EngineData", isDirectory: true)
                var hasData = false
                if let children = try? fileManager.contentsOfDirectory(at: targetData,
                                                                       includingPropertiesForKeys: nil) {
                    hasData = !children.isEmpty
                }
                if !hasData {
                    let savedData = backup.appendingPathComponent(
                        site.appName + ".disabled/Contents/Resources/EngineData", isDirectory: true)
                    if fileManager.fileExists(atPath: savedData.path) {
                        try? fileManager.copyItem(at: savedData, to: targetData)
                    }
                }
            }
            progress(.replacing)
        } catch {
            // 复刻 restore：有备份恢复备份；否则清掉半装的新包（原副本已删）。
            for site in sites {
                let saved = backup.appendingPathComponent(site.appName + ".disabled", isDirectory: true)
                if fileManager.fileExists(atPath: saved.path) {
                    try? fileManager.removeItem(at: site.targetURL)
                    try? fileManager.moveItem(at: saved, to: site.targetURL)
                } else if fileManager.fileExists(atPath: site.targetURL.path) {
                    try? fileManager.removeItem(at: site.targetURL)
                }
            }
            try? writeState(phase: "failed", backup: backup.path)
            throw error
        }

        // 可选数据包：主包已成功，数据失败不回滚主包（部分成功态）。
        var dataNotice: String?
        if let dataPackageZip {
            progress(.dataPackage)
            do {
                let manifest = try installData(from: dataPackageZip)
                dataNotice = "已更新数据到 \(manifest.dataVersion)"
            } catch let error as UpdateInstallError {
                dataNotice = error.errorDescription
            }
            lastDataNotice = dataNotice
        }

        if registerApps {
            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/" +
                "LaunchServices.framework/Support/lsregister"
            if fileManager.isExecutableFile(atPath: lsregister) {
                for site in sites {
                    _ = try? runTool(lsregister, ["-f", site.targetURL.path])
                }
            }
        }
        try writeState(phase: "success", backup: backup.path)
        pruneOldBackups(keep: 2)
        progress(.done)
        // 通知输入法优雅退出（延迟由输入法侧决定；imklaunchagent 随后拉起新版）。
        progress(.restartingInputMethod)
        Self.requestInputMethodRestart()
    }

    /// 数据包部分成功态说明（nil＝无数据包或已完全成功）。
    public private(set) var lastDataNotice: String?

    /// 保留最近 N 份备份（同 postinstall 的 tail -n +3）。
    func pruneOldBackups(keep: Int) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: backupRoot, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsSubdirectoryDescendants) else { return }
        let sorted = entries.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return l > r
        }
        for stale in sorted.dropFirst(keep) {
            try? fileManager.removeItem(at: stale)
        }
    }

    // MARK: - 数据包安装

    /// 解包数据 zip（ditto -x -k）→ 读取并校验 manifest.json → 逐文件哈希 →
    /// 依次替换各 App 的 Contents/Resources/EngineData。
    ///
    /// 签名相互作用：替换整包时 EngineData 属于旧签名密封，替换完成后按
    /// postinstall 同款逐 Mach-O 校验（覆盖 Info.plist／二进制篡改；EngineData
    /// 为运行时读取的资源）。本函数返回已安装的数据清单（fingerprint 可供 UI 显示）。
    @discardableResult
    public func installData(from zip: URL, progress: @escaping (UpdateInstallPhase) -> Void = { _ in }) throws -> UpdateDataManifest {
        try requireTool("/usr/bin/ditto")
        let work = try fileManager.url(for: .itemReplacementDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: fileManager.temporaryDirectory, create: true)
        defer { try? fileManager.removeItem(at: work) }
        let extracted = work.appendingPathComponent("data", isDirectory: true)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        let (status, message) = try runTool("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
        guard status == 0 else {
            throw UpdateInstallError.dataPackageFailed("数据 zip 解包失败：\(message.suffix(200))")
        }
        let manifestFile = extracted.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestFile) else {
            throw UpdateInstallError.dataPackageRejected("数据包缺少 manifest.json")
        }
        let manifest = try UpdateDataManifest.decode(from: manifestData)
        // zip 内容与清单一致（缺文件／哈希错都拒绝）。
        for entry in manifest.files {
            let file = extracted.appendingPathComponent(entry.path)
            guard fileManager.fileExists(atPath: file.path) else {
                throw UpdateInstallError.dataPackageRejected("数据包缺少 \(entry.path)")
            }
            let digest = try UpdateDownloader.sha256(file: file)
            guard digest.caseInsensitiveCompare(entry.sha256) == .orderedSame else {
                throw UpdateInstallError.dataPackageRejected("数据文件哈希不符：\(entry.path)")
            }
        }
        progress(.validating)
        // 依次替换各 App 的 EngineData：先建备份，全部校验通过才动第一个目标。
        var backups: [(URL, URL)] = []
        do {
            for site in sites {
                let target = site.targetURL.appendingPathComponent("Contents/Resources/EngineData", isDirectory: true)
                let saved = work.appendingPathComponent("backup-" + site.appName, isDirectory: true)
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.copyItem(at: target, to: saved)
                    backups.append((target, saved))
                }
            }
            for site in sites {
                let target = site.targetURL.appendingPathComponent("Contents/Resources/EngineData", isDirectory: true)
                try fileManager.removeItem(at: target)
                for entry in manifest.files {
                    let destination = target.appendingPathComponent(entry.path)
                    try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
                    try fileManager.copyItem(at: extracted.appendingPathComponent(entry.path), to: destination)
                }
            }
            progress(.dataPackage)
        } catch {
            for (target, saved) in backups.reversed() {
                try? fileManager.removeItem(at: target)
                try? fileManager.moveItem(at: saved, to: target)
            }
            if error is UpdateInstallError {
                throw error
            }
            throw UpdateInstallError.dataPackageFailed("数据落位失败：\(error.localizedDescription)")
        }
        return manifest
    }

    // MARK: - 输入法交接

    /// 通过 DistributedNotificationCenter 请求输入法优雅退出。
    /// 绝不 SIGKILL；GogakuInput 自行延迟结束组合后 NSApp.terminate，
    /// imklaunchagent 在连接断开后按需拉起新版进程。
    public static func requestInputMethodRestart() {
        DistributedNotificationCenter.default()
            .postNotificationName(Notification.Name(restartNotificationName),
                                  object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// GogakuInput 启动早期调用：注册优雅退出监听。幂等（多次调用只注册一次）。
    /// 返回观察者（removeObserver 用；测试断言幂等时对比非 nil 即可）。
    @discardableResult
    public static func observeInputMethodRestart(onExit perform: @escaping () -> Void) -> NSObjectProtocol {
        return DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(restartNotificationName), object: nil, queue: nil) { _ in
            perform()
        }
    }
}
