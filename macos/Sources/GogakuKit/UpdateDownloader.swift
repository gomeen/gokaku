import Foundation
import CryptoKit

public enum UpdateDownloadError: Error, Equatable, LocalizedError {
    case insufficientSpace(required: Int64, available: Int64)
    case sizeMismatch(expected: Int64, actual: Int64)
    case hashMismatch
    case notDownloaded
    case installFailed(String)
    case cancelled
    case installerUnavailable

    public var errorDescription: String? {
        switch self {
        case let .insufficientSpace(required, available):
            return "磁盘空间不足：需要 \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))，可用 \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))"
        case let .sizeMismatch(expected, actual):
            return "下载文件大小不符：期望 \(expected)，实际 \(actual)"
        case .hashMismatch: return "下载文件 SHA-256 与签名清单不符"
        case .notDownloaded: return "安装包尚未下载"
        case let .installFailed(message): return "无法启动安装器：\(message)"
        case .cancelled: return "已取消下载"
        case .installerUnavailable: return "本环境无法就地安装（缺少 xar/cpio 等工具）"
        }
    }
}

/// 下载 → 校验 → 原子落缓存 → 交给系统安装器。
/// 不自动安装、不自动重启；用户点击「安装更新」才调用 `install`。
public final class UpdateDownloader {
    private let transport: UpdateTransport
    private let cacheRoot: URL
    private let fileManager: FileManager

    public init(transport: UpdateTransport = URLSessionUpdateTransport(),
                cacheRoot: URL = UpdateDownloader.defaultCacheRoot(),
                fileManager: FileManager = .default) {
        self.transport = transport; self.cacheRoot = cacheRoot; self.fileManager = fileManager
    }

    public static func defaultCacheRoot() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("Gogaku/updates", isDirectory: true)
    }

    private func downloadDirectory(for candidate: UpdateCandidate) throws -> URL {
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let directory = cacheRoot.appendingPathComponent(
            "\(candidate.manifest.version)-b\(candidate.manifest.buildNumber)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// 数据包缓存根：~/Library/Caches/Gogaku/updates/data/<dataVersion>/。
    /// 同一数据版本的文件跨代码版本复用（数据指纹不变则不重新下载）。
    public static func defaultDataCacheRoot() -> URL {
        defaultCacheRoot().appendingPathComponent("data", isDirectory: true)
    }

    /// 按资产大小自适应的下载总超时：GitHub 资产域名实测可低至 ~80KB/s
    /// （2026-11-20 用户 0.3.0→0.3.2 升级：36.7MB 数据包在固定 300s 资源超时内
    /// 下不完；无字节级续传，重试从头下载导致永远超时）。按 50KB/s 保底速度
    /// 估算总时长，下限 300s：11MB 主包仍 300s，36.7MB 数据包 ≈ 734s。
    /// 空闲断流由传输层独立的请求级超时兑底，不会无限挂起。
    public static func downloadTimeout(forBytes bytes: Int64, floor: TimeInterval = 300) -> TimeInterval {
        max(floor, TimeInterval(bytes) / 50_000)
    }

    /// 下载并校验数据包（若 candidate 携带且本地缓存没有该数据版本）。
    /// 返回已校验的数据包 zip 路径；清单无数据包时返回 nil。
    /// - Parameters:
    ///   - dataPackage: 检查阶段得到的本平台数据包资产（schema 2；nil＝无）。
    ///   - resolved: 检查阶段记录的 (下载地址, sha256, size)；无记录时不下载。
    public func downloadDataPackage(candidate: UpdateCandidate,
                                    dataPackage: UpdateDataPackage?,
                                    resolved: (url: URL, sha256: String, size: Int64)?,
                                    progress: @escaping @Sendable (Double) -> Void) async throws -> URL? {
        guard let dataPackage, let resolved else { return nil }
        let dataRoot = cacheRoot.appendingPathComponent("data", isDirectory: true)
        try fileManager.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let directory = dataRoot.appendingPathComponent(dataPackage.dataVersion, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let final = directory.appendingPathComponent(dataPackage.name)
        let expected = UpdateAsset(platform: dataPackage.platform, arch: "x86_64", minOS: "26.0",
                                   assetId: dataPackage.assetId, name: dataPackage.name,
                                   size: dataPackage.size, sha256: dataPackage.sha256)
        if fileManager.fileExists(atPath: final.path),
           (try? Self.verify(file: final, asset: expected)) != nil {
            progress(1)
            return final
        }
        // 哈希绑定：数据包资产自述的 sha256 必须与检查时记录的一致。
        guard resolved.sha256.caseInsensitiveCompare(dataPackage.sha256) == .orderedSame,
              resolved.size == dataPackage.size else {
            throw UpdateDownloadError.hashMismatch
        }
        let partial = directory.appendingPathComponent(dataPackage.name + ".partial")
        try? fileManager.removeItem(at: partial)
        let available = (try? dataRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        let required = dataPackage.size + 32 * 1024 * 1024
        if available > 0, available < required {
            throw UpdateDownloadError.insufficientSpace(required: required, available: available)
        }
        let temporary: URL
        do {
            (temporary, _) = try await transport.download(
                resolved.url, timeout: Self.downloadTimeout(forBytes: dataPackage.size)) { written in
                let fraction = dataPackage.size > 0
                    ? min(1, Double(written) / Double(dataPackage.size)) : 0
                progress(fraction)
            }
        } catch let error as UpdateTransportError {
            if error == .cancelled { throw UpdateDownloadError.cancelled }
            throw error
        } catch is CancellationError {
            throw UpdateDownloadError.cancelled
        }
        do {
            do {
                try fileManager.moveItem(at: temporary, to: partial)
            } catch {
                try fileManager.copyItem(at: temporary, to: partial)
                try? fileManager.removeItem(at: temporary)
            }
            try Self.verify(file: partial, asset: expected)
            if fileManager.fileExists(atPath: final.path) { try fileManager.removeItem(at: final) }
            try fileManager.moveItem(at: partial, to: final)
            progress(1)
            return final
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    /// 返回已校验的安装包缓存路径。已存在且校验通过时直接复用（支持重试）。
    public func download(_ candidate: UpdateCandidate,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let directory = try downloadDirectory(for: candidate)
        let final = directory.appendingPathComponent(candidate.asset.name)
        if fileManager.fileExists(atPath: final.path),
           (try? Self.verify(file: final, asset: candidate.asset)) != nil {
            progress(1)
            return final
        }
        let partial = directory.appendingPathComponent(candidate.asset.name + ".partial")
        try? fileManager.removeItem(at: partial)

        let available = (try? cacheRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        // 预留 64MiB 给解包／安装器；不足时不开始下载。
        let required = candidate.asset.size + 64 * 1024 * 1024
        if available > 0, available < required {
            throw UpdateDownloadError.insufficientSpace(required: required, available: available)
        }

        let temporary: URL
        do {
            (temporary, _) = try await transport.download(
                candidate.downloadURL, timeout: Self.downloadTimeout(forBytes: candidate.asset.size)) { written in
                let fraction = candidate.asset.size > 0
                    ? min(1, Double(written) / Double(candidate.asset.size)) : 0
                progress(fraction)
            }
        } catch let error as UpdateTransportError {
            if error == .cancelled { throw UpdateDownloadError.cancelled }
            throw error
        } catch is CancellationError {
            throw UpdateDownloadError.cancelled
        }
        do {
            do {
                try fileManager.moveItem(at: temporary, to: partial)
            } catch {
                // 临时目录与缓存可能跨卷；退化为复制后删源，失败仍清理。
                try fileManager.copyItem(at: temporary, to: partial)
                try? fileManager.removeItem(at: temporary)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw UpdateDownloadError.installFailed("无法保存下载文件：\(error.localizedDescription)")
        }
        do {
            try Self.verify(file: partial, asset: candidate.asset)
            if fileManager.fileExists(atPath: final.path) { try fileManager.removeItem(at: final) }
            try fileManager.moveItem(at: partial, to: final)
            progress(1)
            return final
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    /// 启动安装前再次校验（防止缓存被替换或截断）。
    public func verifyBeforeInstall(_ candidate: UpdateCandidate, file: URL) throws {
        try Self.verify(file: file, asset: candidate.asset)
    }

    /// 就地热更新：客户端自己完成 pkg 解包→校验→事务替换→输入法交接，
    /// 不打开系统 Installer（事务语义见 UpdateInstaller，与 pkg-postinstall.sh
    /// 逐条对应）。数据包安装失败属部分成功态：主包已装好、数据保留旧版，
    /// 返回给 UI 明示的说明（nil＝完全成功）。
    /// 工具链不可用时抛 `installerUnavailable`，调用方回落 open-installer。
    @discardableResult
    public func installInPlace(_ candidate: UpdateCandidate, file: URL,
                               dataPackageZip: URL?,
                               progress: @escaping (UpdateInstallPhase) -> Void) throws -> String? {
        try Self.verify(file: file, asset: candidate.asset)
        let installer = UpdateInstaller(expectedBuild: String(candidate.manifest.buildNumber))
        try installer.install(packageURL: file, dataPackageZip: dataPackageZip, progress: progress)
        return installer.lastDataNotice
    }

    /// 打开系统安装器。Mac 交给 Installer（用户级 pkg 不需要提权）；
    /// Windows 端由平台实现调用 `/S` 或 ShellExecute（本文件只编译 Mac）。
    public func install(_ candidate: UpdateCandidate, file: URL) throws {
        try Self.verify(file: file, asset: candidate.asset)
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [file.path]
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw UpdateDownloadError.installFailed("Installer 退出码 \(process.terminationStatus)")
            }
        } catch let error as UpdateDownloadError {
            throw error
        } catch {
            throw UpdateDownloadError.installFailed(error.localizedDescription)
        }
        #else
        throw UpdateDownloadError.installFailed("当前平台未实现安装交接")
        #endif
    }

    public static func verify(file: URL, asset: UpdateAsset) throws {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw UpdateDownloadError.notDownloaded }
        let size = Int64(values.fileSize ?? 0)
        guard size == asset.size else {
            throw UpdateDownloadError.sizeMismatch(expected: asset.size, actual: size)
        }
        let digest = try sha256(file: file)
        guard digest.caseInsensitiveCompare(asset.sha256) == .orderedSame else {
            throw UpdateDownloadError.hashMismatch
        }
    }

    static func sha256(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 小数据的便捷 SHA-256（数据指纹与测试用）。
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
