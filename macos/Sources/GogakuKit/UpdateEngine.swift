import Foundation

/// GitHub Releases 检查器（只读公开仓库）。
///
/// 流程：releases 列表（分页／ETag／限流／超时）→ 找清单与分离签名 →
/// Ed25519 验签与字段校验 → 通道／构建号／平台／架构／最低系统过滤 →
/// 返回可下载候选。清单无效、缺签名、通道不符或资产不全都明确报错，
/// 不把「无法检查」显示成「已是最新」。
public final class UpdateEngine {
    public struct GitHubRelease: Codable, Equatable, Sendable {
        public struct Asset: Codable, Equatable, Sendable {
            public let id: Int64
            public let name: String
            public let size: Int64
            public let browserDownloadURL: URL
            enum CodingKeys: String, CodingKey {
                case id, name, size
                case browserDownloadURL = "browser_download_url"
            }
        }
        public let id: Int64
        public let tagName: String
        public let name: String?
        public let body: String?
        public let draft: Bool
        public let prerelease: Bool
        public let publishedAt: Date?
        public let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case id, name, body, draft, prerelease, assets
            case tagName = "tag_name"
            case publishedAt = "published_at"
        }
    }

    #if GOGAKU_LITE
    public static let manifestName = "update-manifest-lite.json"
    public static let signatureName = "update-manifest-lite.json.sig"
    public static let v2ManifestName = "update-manifest-lite-v2.json"
    #else
    public static let manifestName = "update-manifest.json"
    public static let signatureName = "update-manifest.json.sig"
    public static let v2ManifestName = "update-manifest-v2.json"
    #endif
    /// 双清单：新客户端优先拉 v2（schema 2，含 dataPackage）；老 Release 没有
    /// v2 资产时回落 schema 1（只含主包）。每个新发布仍同时带 schema 1 清单，
    /// 0.2.0 及更早的旧客户端继续可用（见 docs/update.md）。
    public static let manifestLimit = 256 * 1024
    public static let signatureLimit = 8 * 1024
    public static let releasesPerPage = 30
    public static let maxPages = 3

    private let config: UpdateSourceConfig?
    private let installation: UpdateInstallation
    private let transport: UpdateTransport
    private let preferences: UpdatePreferencesStore
    private let now: () -> Date
    private let timeout: TimeInterval

    public init(config: UpdateSourceConfig?, installation: UpdateInstallation,
                transport: UpdateTransport = URLSessionUpdateTransport(),
                preferences: UpdatePreferencesStore = UpdatePreferencesStore(),
                now: @escaping () -> Date = Date.init,
                timeout: TimeInterval = 20) {
        self.config = config; self.installation = installation
        self.transport = transport; self.preferences = preferences
        self.now = now; self.timeout = timeout
    }

    public var channel: UpdateChannel { installation.channel }

    /// 自动检查是否到期（默认关闭；手动检查不受此限）。
    public func isAutoCheckDue() -> Bool {
        preferences.isAutoCheckDue(channel: channel, now: now())
    }

    public func preferencesStore() -> UpdatePreferencesStore { preferences }

    public func check(automatic: Bool) async -> UpdateCheckOutcome {
        guard let config, config.isConfigured else {
            return outcome(.unconfigured, "未配置更新源（缺少发布仓库或可信公钥）")
        }
        if automatic, !isAutoCheckDue() {
            return outcome(.skipped, "今日已自动检查过")
        }
        defer {
            if automatic { try? preferences.recordAutoCheck(channel: channel, now: now()) }
        }

        guard Self.releasesURL(config: config, page: 1) != nil else {
            return outcome(.unconfigured, "更新源地址非法")
        }
        var releases: [GitHubRelease] = []
        let cachedPages = preferences.cachedReleasePages(for: channel)
        var checkedPages: [UpdateReleasePage] = []
        for page in 1...Self.maxPages {
            guard let url = Self.releasesURL(config: config, page: page) else {
                return outcome(.unconfigured, "更新源地址非法")
            }
            var headers = [
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "Gogaku/\(installation.version) (build \(installation.buildNumber))",
            ]
            let cachedPage = cachedPages.first { $0.url == url }
            if let etag = cachedPage?.etag, !etag.isEmpty {
                headers["If-None-Match"] = etag
            }
            let response: UpdateHTTPResponse
            do {
                response = try await transport.get(url, headers: headers,
                                                   timeout: timeout,
                                                   maxBytes: 2 * 1024 * 1024)
            } catch let error as UpdateTransportError {
                return outcome(.networkError, error.localizedDescription)
            } catch {
                return outcome(.networkError, error.localizedDescription)
            }

            if response.status == 304 {
                guard headers["If-None-Match"] != nil, let cachedPage else {
                    return outcome(.networkError, "更新源返回 304 但没有对应的发布列表缓存")
                }
                checkedPages.append(cachedPage)
                releases.append(contentsOf: cachedPage.releases)
                if cachedPage.releases.count < Self.releasesPerPage { break }
                continue
            }
            if response.status == 403 || response.status == 429,
               response.rateLimitRemaining == 0 {
                let reset = response.rateLimitReset.map { "；\(Self.timeFormatter.string(from: $0)) 重置" } ?? ""
                return outcome(.rateLimited, "更新服务请求受限\(reset)")
            }
            if response.status == 404 {
                return outcome(.noRelease, "更新源不可用（404）：检查发布仓库配置")
            }
            guard response.status == 200 else {
                return outcome(.networkError, "更新服务返回 HTTP \(response.status)")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let pageReleases = try? decoder.decode([GitHubRelease].self, from: response.body) else {
                return outcome(.networkError, "更新服务返回的发布列表无法解析")
            }
            checkedPages.append(UpdateReleasePage(url: url, etag: response.etag, releases: pageReleases))
            releases.append(contentsOf: pageReleases)
            // Release 的 prerelease 标志不等于签名清单的安装通道；满页继续找，最多三页。
            if pageReleases.count < Self.releasesPerPage { break }
        }

        do {
            // 304 只复用对应页的列表；仍重新下载／验签并按当前安装信息评估。
            let result = try await evaluate(releases: releases, config: config)
            try? preferences.recordCheck(pages: checkedPages, outcome: result, channel: channel)
            return result
        } catch let error as UpdateManifestError {
            return outcome(.invalidManifest, error.localizedDescription)
        } catch let error as UpdateTransportError {
            return outcome(.networkError, error.localizedDescription)
        } catch {
            return outcome(.networkError, error.localizedDescription)
        }
    }

    // MARK: - 发布评估

    private func evaluate(releases: [GitHubRelease],
                          config: UpdateSourceConfig) async throws -> UpdateCheckOutcome {
        var sawManifest = false
        var sawWrongChannel = false
        for release in releases where !release.draft {
            // 通道预筛：stable 不读取预发布；dev 可读取 dev／rc／正式。
            if installation.channel == .stable, release.prerelease { continue }
            // 优先 schema 2 双清单；404／缺失回落 schema 1。两者都没有才算
            // 「发布缺少清单」。v2 验签失败按 invalidManifest 处理，不静默回落。
            let manifest: UpdateManifest
            let dataPackage: UpdateDataPackage?
            do {
                if let v2 = try await loadVerifiedManifest(release: release, config: config,
                                                           name: Self.v2ManifestName) {
                    manifest = v2
                    dataPackage = v2.dataPackage.flatMap {
                        $0.platform == installation.platform ? $0 : nil
                    }
                } else if let fallback = try await loadVerifiedManifest(release: release, config: config,
                                                                        name: Self.manifestName) {
                    manifest = fallback
                    dataPackage = nil
                } else {
                    continue
                }
            } catch let error as UpdateTransportError where error == .http(404) {
                // v2 资产在列表里但下载 404：按缺失处理，回落 schema 1。
                guard let fallback = try await loadVerifiedManifest(release: release, config: config,
                                                                    name: Self.manifestName) else {
                    continue
                }
                manifest = fallback
                dataPackage = nil
            }
            sawManifest = true
            if manifest.channel != installation.channel {
                sawWrongChannel = true
                continue
            }
            // 只按构建号判定升级；同版本更高构建号可更新，不自动降级。
            // 用户可见文案不写构建号（2026-11-19 裁决：构建号是纯内部计数器）。
            if manifest.buildNumber <= installation.buildNumber {
                return outcome(.upToDate, "已是最新（\(installation.version)）")
            }
            guard let asset = manifest.asset(platform: installation.platform,
                                             arch: installation.arch,
                                             currentOS: installation.osVersion) else {
                return outcome(.unsupported,
                               "新版本 \(manifest.version) 不支持当前系统或架构（\(installation.platform)/\(installation.arch) ≥ \(installation.osVersion)）")
            }
            guard let releaseAsset = release.assets.first(where: { $0.id == asset.assetId }),
                  releaseAsset.name == asset.name,
                  releaseAsset.size == asset.size else {
                throw UpdateManifestError.invalidField("release asset 与清单不一致")
            }
            try URLSessionUpdateTransport.validate(url: releaseAsset.browserDownloadURL,
                                                   requireAPIHost: false)
            // 数据包资产同样必须真实存在于该 Release。
            var dataDownloadURL: URL?
            if let data = dataPackage {
                guard let dataAsset = release.assets.first(where: { $0.id == data.assetId }),
                      dataAsset.name == data.name,
                      dataAsset.size == data.size else {
                    throw UpdateManifestError.invalidField("release dataPackage 与清单不一致")
                }
                try URLSessionUpdateTransport.validate(url: dataAsset.browserDownloadURL,
                                                       requireAPIHost: false)
                dataDownloadURL = dataAsset.browserDownloadURL
            }
            let candidate = UpdateCandidate(
                releaseTag: release.tagName,
                releaseName: release.name ?? release.tagName,
                manifest: manifest, asset: asset,
                downloadURL: releaseAsset.browserDownloadURL,
                publishedAt: release.publishedAt)
            return outcome(.available,
                           "发现新版本 \(manifest.version)",
                           candidate: candidate, dataPackage: dataPackage, checkedAt: now(),
                           dataDownloadURL: dataDownloadURL)
        }
        if !sawManifest {
            return outcome(.noManifest, "当前通道的发布没有 update-manifest.json 与签名")
        }
        if sawWrongChannel {
            return outcome(.noRelease, "当前通道（\(installation.channel.rawValue)）没有可用发布")
        }
        return outcome(.noRelease, "当前通道没有可用发布")
    }

    /// 下载指定名字的清单与签名并验签。v2 清单不存在（资产缺失）返回 nil；
    /// schema 1 清单缺失抛 malformedManifest（由 evaluate 转 noManifest）。
    private func loadVerifiedManifest(release: GitHubRelease, config: UpdateSourceConfig,
                                      name: String) async throws -> UpdateManifest? {
        guard let manifestAsset = release.assets.first(where: { $0.name == name }),
              let signatureAsset = release.assets.first(where: { $0.name == name + ".sig" }) else {
            return nil
        }
        let manifestBytes = try await downloadSmall(manifestAsset, limit: Self.manifestLimit)
        let signatureBytes = try await downloadSmall(signatureAsset, limit: Self.signatureLimit)
        return try UpdateManifestVerifier.verify(
            manifestBytes: manifestBytes, signature: signatureBytes,
            trustedKeys: config.trustedKeys)
    }

    private func outcome(_ kind: UpdateCheckOutcome.Kind, _ message: String,
                         candidate: UpdateCandidate? = nil,
                         dataPackage: UpdateDataPackage? = nil,
                         checkedAt: Date? = nil,
                         dataDownloadURL: URL? = nil) -> UpdateCheckOutcome {
        if kind == .available, let candidate, let dataPackage, let url = dataDownloadURL {
            Self.dataPackageRegistry.record(manifestVersion: candidate.manifest.version,
                                            buildNumber: candidate.manifest.buildNumber,
                                            dataPackage: dataPackage, url: url)
        }
        return UpdateCheckOutcome(kind: kind, message: message, candidate: candidate,
                                  dataPackage: dataPackage,
                                  checkedAt: checkedAt ?? now())
    }

    private func downloadSmall(_ asset: GitHubRelease.Asset, limit: Int) async throws -> Data {
        try URLSessionUpdateTransport.validate(url: asset.browserDownloadURL, requireAPIHost: false)
        let response = try await transport.getAsset(asset.browserDownloadURL,
                                               headers: ["User-Agent": "Gogaku/\(installation.version)"],
                                               timeout: timeout, maxBytes: limit)
        guard response.status == 200 else {
            throw UpdateTransportError.http(response.status)
        }
        return response.body
    }

    static func hasManifest(_ release: GitHubRelease) -> Bool {
        release.assets.contains { $0.name == manifestName }
            && release.assets.contains { $0.name == signatureName }
    }

    static func releasesURL(config: UpdateSourceConfig, page: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(config.owner)/\(config.repo)/releases"
        components.queryItems = [URLQueryItem(name: "per_page", value: String(releasesPerPage)),
                                 URLQueryItem(name: "page", value: String(page))]
        return components.url
    }

    /// 本进程内缓存的数据包下载记录（供下载阶段取地址）。
    private struct DataPackageRecord {
        let dataVersion: String
        let sha256: String
        let size: Int64
        let url: URL
    }
    /// 数据包下载地址注册表：检查阶段把候选→数据包资产绑定写入，
    /// 下载阶段按（版本＋构建号＋数据指纹）取出。进程内存态，不落盘。
    public final class DataPackageRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [String: DataPackageRecord] = [:]
        public init() {}
        func record(manifestVersion: String, buildNumber: Int,
                    dataPackage: UpdateDataPackage, url: URL) {
            lock.lock(); defer { lock.unlock() }
            records["\(manifestVersion)#\(buildNumber)#\(dataPackage.dataVersion)"] =
                DataPackageRecord(dataVersion: dataPackage.dataVersion,
                                  sha256: dataPackage.sha256, size: dataPackage.size, url: url)
        }
        public func lookup(manifestVersion: String, buildNumber: Int,
                           dataVersion: String) -> (url: URL, sha256: String, size: Int64)? {
            lock.lock(); defer { lock.unlock() }
            guard let record = records["\(manifestVersion)#\(buildNumber)#\(dataVersion)"] else {
                return nil
            }
            return (record.url, record.sha256, record.size)
        }
    }

    /// 默认注册表：UpdateEngine.check 写入，UpdateDownloader 读取。
    public static let dataPackageRegistry = DataPackageRegistry()

    private func outcome(_ kind: UpdateCheckOutcome.Kind, _ message: String,
                         candidate: UpdateCandidate? = nil) -> UpdateCheckOutcome {
        UpdateCheckOutcome(kind: kind, message: message, candidate: candidate, checkedAt: now())
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
