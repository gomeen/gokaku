import Foundation
import CryptoKit

/// 更新清单与签名合同（2026-11-06 双端功能统一计划）。
///
/// 发布端为每个 Release 附 `update-manifest.json` 与其原始 UTF-8 字节的
/// Ed25519 分离签名 `update-manifest.json.sig`。客户端内置可信公钥，验证
/// 签名后才解析清单；公钥来自随包 `update-config.json`，私钥只在发布环境。
///
/// 本文件只做纯数据与密码学验证，不联网、不读用户输入。Mac 使用 CryptoKit，
/// Windows 端使用系统 CNG Ed25519（同一清单合同），不自行实现密码学。
public enum UpdateChannel: String, Codable, CaseIterable, Sendable {
    case stable
    case dev

    /// 安装通道由 bundle ID 后缀派生（与双通道安装一致）。
    public static func from(bundleIdentifier: String?) -> UpdateChannel {
        bundleIdentifier?.hasSuffix(".dev") == true ? .dev : .stable
    }
}

public struct UpdateAsset: Codable, Equatable, Sendable {
    /// `macos`｜`windows`。
    public let platform: String
    /// `x86_64`（本轮 Mac Intel／Windows x64；Apple Silicon 与 Windows ARM64 不在范围）。
    public let arch: String
    /// 最低系统版本，点分数字（macOS `26.0`；Windows `10.0.22000`）。
    public let minOS: String
    public let assetId: Int64
    public let name: String
    public let size: Int64
    /// 小写十六进制 SHA-256（64 字符）。
    public let sha256: String

    public init(platform: String, arch: String, minOS: String, assetId: Int64,
                name: String, size: Int64, sha256: String) {
        self.platform = platform; self.arch = arch; self.minOS = minOS
        self.assetId = assetId; self.name = name; self.size = size; self.sha256 = sha256
    }
}

/// 数据包资产（schema 2 可选字段）：与主包同 postinstall 机制的 pkg，
/// 只含双 App 的 EngineData；`dataVersion` 是数据内容指纹短哈希，
/// 数据没变的版本之间相同（清单可引用上一个数据未变版本的数据包资产）。
public struct UpdateDataPackage: Codable, Equatable, Sendable {
    public let platform: String
    public let name: String
    public let size: Int64
    public let sha256: String
    public let assetId: Int64
    /// 数据内容指纹（16 位十六进制；算法见 UpdateDataManifest.fingerprint）。
    public let dataVersion: String

    public init(platform: String, name: String, size: Int64, sha256: String,
                assetId: Int64, dataVersion: String) {
        self.platform = platform; self.name = name; self.size = size
        self.sha256 = sha256; self.assetId = assetId; self.dataVersion = dataVersion
    }
}

public struct UpdateManifest: Codable, Equatable, Sendable {
    public let schema: Int
    public let keyId: String
    public let version: String
    public let buildNumber: Int
    public let channel: UpdateChannel
    public let notes: String
    public let assets: [UpdateAsset]
    /// schema 2 起：数据包资产（仅主包所在平台；按本机平台取用）。
    /// schema 1 清单解码为 nil（向后兼容）。
    public let dataPackage: UpdateDataPackage?

    public init(schema: Int = 1, keyId: String, version: String, buildNumber: Int,
                channel: UpdateChannel, notes: String, assets: [UpdateAsset],
                dataPackage: UpdateDataPackage? = nil) {
        self.schema = schema; self.keyId = keyId; self.version = version
        self.buildNumber = buildNumber; self.channel = channel
        self.notes = notes; self.assets = assets; self.dataPackage = dataPackage
    }

    enum CodingKeys: String, CodingKey {
        case schema, keyId, version, buildNumber, channel, notes, assets, dataPackage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        keyId = try container.decode(String.self, forKey: .keyId)
        version = try container.decode(String.self, forKey: .version)
        buildNumber = try container.decode(Int.self, forKey: .buildNumber)
        channel = try container.decode(UpdateChannel.self, forKey: .channel)
        notes = try container.decode(String.self, forKey: .notes)
        assets = try container.decode([UpdateAsset].self, forKey: .assets)
        // schema 1 没有 dataPackage；schema 2 必须有（缺失按结构非法处理，
        // 避免静默丢数据包导致“只升代码不升数据”）。
        if schema >= 2 {
            guard container.contains(.dataPackage) else {
                throw DecodingError.dataCorruptedError(forKey: .dataPackage, in: container,
                                                       debugDescription: "schema 2 清单缺少 dataPackage")
            }
            dataPackage = try container.decodeIfPresent(UpdateDataPackage.self, forKey: .dataPackage)
        } else {
            dataPackage = try container.decodeIfPresent(UpdateDataPackage.self, forKey: .dataPackage)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(keyId, forKey: .keyId)
        try container.encode(version, forKey: .version)
        try container.encode(buildNumber, forKey: .buildNumber)
        try container.encode(channel, forKey: .channel)
        try container.encode(notes, forKey: .notes)
        try container.encode(assets, forKey: .assets)
        try container.encodeIfPresent(dataPackage, forKey: .dataPackage)
    }

    /// 选出当前平台／架构且系统版本满足的资产。资产不唯一视为清单非法。
    public func asset(platform: String, arch: String, currentOS: String) -> UpdateAsset? {
        assets.first {
            $0.platform == platform && $0.arch == arch
                && UpdateVersion.compareDotted(currentOS, $0.minOS) != .orderedAscending
        }
    }
}

public enum UpdateManifestError: Error, Equatable, LocalizedError {
    case malformedManifest
    case unsupportedSchema(Int)
    case unknownKey(String)
    case malformedPublicKey(String)
    case malformedSignature
    case invalidSignature
    case invalidField(String)
    case missingDataPackage

    public var errorDescription: String? {
        switch self {
        case .malformedManifest: return "更新清单格式非法"
        case let .unsupportedSchema(schema): return "不支持的更新清单版本：\(schema)"
        case let .unknownKey(key): return "更新清单使用了未知公钥：\(key)"
        case let .malformedPublicKey(key): return "内置公钥格式非法：\(key)"
        case .malformedSignature: return "更新清单签名格式非法"
        case .invalidSignature: return "更新清单签名验证失败"
        case let .invalidField(field): return "更新清单字段非法：\(field)"
        case .missingDataPackage: return "schema 2 清单缺少 dataPackage"
        }
    }
}

public enum UpdateVersion {
    /// 点分十进制比较；缺位按 0（`26.0` == `26.0.0`）。非数字段直接判非法。
    public static func compareDotted(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? -1 }
        let right = rhs.split(separator: ".").map { Int($0) ?? -1 }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    public static func isValidDotted(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.split(separator: ".").allSatisfy { component in
            guard let number = Int(component) else { return false }
            return number >= 0
        }
    }

    /// 预发布判定：SemVer 的 `-dev.N`／`-rc.N`；也拒绝空段。
    public static func isPrerelease(_ version: String) -> Bool {
        version.contains("-")
    }

    public static func isValidVersion(_ version: String) -> Bool {
        let pattern = #"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-(0|[1-9]\d*|dev|rc)\.(0|[1-9]\d*))?$"#
        return version.range(of: pattern, options: .regularExpression) != nil
    }
}

public enum UpdateManifestVerifier {
    /// schema 2 双清单资产名：update-manifest-v2.json（schema 1 仍为
    /// update-manifest.json，旧客户端继续读取；客户端优先拉 v2、404 回落 v1）。
    public static let v2ManifestSuffix = "-v2"

    /// 校验原始清单字节的分离 Ed25519 签名，再解析并做字段校验。
    /// 签名文件允许原始 64 字节或 base64 文本（含换行）。
    public static func verify(manifestBytes: Data, signature: Data,
                              trustedKeys: [UpdateTrustedKey]) throws -> UpdateManifest {
        guard let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: manifestBytes) else {
            throw UpdateManifestError.malformedManifest
        }
        try validate(manifest)
        guard let trusted = trustedKeys.first(where: { $0.keyId == manifest.keyId }) else {
            throw UpdateManifestError.unknownKey(manifest.keyId)
        }
        guard let publicKeyData = Data(base64Encoded: trusted.publicKey),
              publicKeyData.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            throw UpdateManifestError.malformedPublicKey(trusted.keyId)
        }
        let signatureBytes: Data
        if signature.count == 64 {
            signatureBytes = signature
        } else {
            let text = String(decoding: signature, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let decoded = Data(base64Encoded: text), decoded.count == 64 else {
                throw UpdateManifestError.malformedSignature
            }
            signatureBytes = decoded
        }
        guard publicKey.isValidSignature(signatureBytes, for: manifestBytes) else {
            throw UpdateManifestError.invalidSignature
        }
        return manifest
    }

    public static func validate(_ manifest: UpdateManifest) throws {
        guard manifest.schema == 1 || manifest.schema == 2 else {
            throw UpdateManifestError.unsupportedSchema(manifest.schema)
        }
        guard manifest.schema < 2 || manifest.dataPackage != nil else {
            throw UpdateManifestError.missingDataPackage
        }
        guard UpdateVersion.isValidVersion(manifest.version) else {
            throw UpdateManifestError.invalidField("version")
        }
        guard manifest.buildNumber > 0 else { throw UpdateManifestError.invalidField("buildNumber") }
        guard !manifest.keyId.isEmpty, manifest.keyId.utf8.count <= 128 else {
            throw UpdateManifestError.invalidField("keyId")
        }
        guard manifest.notes.utf8.count <= 65_536 else {
            throw UpdateManifestError.invalidField("notes")
        }
        guard !manifest.assets.isEmpty else { throw UpdateManifestError.invalidField("assets") }
        var seen = Set<String>()
        for asset in manifest.assets {
            guard ["macos", "windows"].contains(asset.platform) else {
                throw UpdateManifestError.invalidField("assets.platform")
            }
            guard !asset.arch.isEmpty, asset.arch.utf8.count <= 32 else {
                throw UpdateManifestError.invalidField("assets.arch")
            }
            guard UpdateVersion.isValidDotted(asset.minOS) else {
                throw UpdateManifestError.invalidField("assets.minOS")
            }
            guard asset.assetId > 0, asset.size > 0 else {
                throw UpdateManifestError.invalidField("assets.id/size")
            }
            guard !asset.name.isEmpty, asset.name.utf8.count <= 255,
                  !asset.name.contains("/"), !asset.name.contains("\\"),
                  asset.name != ".", asset.name != ".." else {
                throw UpdateManifestError.invalidField("assets.name")
            }
            guard asset.sha256.count == 64,
                  asset.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw UpdateManifestError.invalidField("assets.sha256")
            }
            let key = "\(asset.platform)/\(asset.arch)"
            guard seen.insert(key).inserted else {
                throw UpdateManifestError.invalidField("assets 重复：\(key)")
            }
        }
        // 数据包资产与主包同一套字段约束；只在主包平台声明。
        if let data = manifest.dataPackage {
            guard manifest.assets.contains(where: { $0.platform == data.platform }) else {
                throw UpdateManifestError.invalidField("dataPackage.platform 无主包")
            }
            guard !data.name.isEmpty, data.name.utf8.count <= 255,
                  !data.name.contains("/"), !data.name.contains("\\"),
                  data.name != ".", data.name != ".." else {
                throw UpdateManifestError.invalidField("dataPackage.name")
            }
            guard data.size > 0, data.assetId > 0 else {
                throw UpdateManifestError.invalidField("dataPackage.id/size")
            }
            guard data.sha256.count == 64, data.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw UpdateManifestError.invalidField("dataPackage.sha256")
            }
            guard data.dataVersion.count == 16,
                  data.dataVersion.allSatisfy({ $0.isHexDigit }) else {
                throw UpdateManifestError.invalidField("dataPackage.dataVersion")
            }
        }
        // stable 只接受正式版本；dev 可接受 dev／rc／正式。
        if manifest.channel == .stable, UpdateVersion.isPrerelease(manifest.version) {
            throw UpdateManifestError.invalidField("channel/version")
        }
    }
}

public struct UpdateTrustedKey: Codable, Equatable, Sendable {
    public let keyId: String
    public let publicKey: String
    public init(keyId: String, publicKey: String) {
        self.keyId = keyId; self.publicKey = publicKey
    }
}

public struct UpdateSourceConfig: Codable, Equatable, Sendable {
    public let schema: Int
    public let owner: String
    public let repo: String
    public let trustedKeys: [UpdateTrustedKey]

    public init(schema: Int = 1, owner: String, repo: String, trustedKeys: [UpdateTrustedKey]) {
        self.schema = schema; self.owner = owner; self.repo = repo; self.trustedKeys = trustedKeys
    }

    public var isConfigured: Bool {
        !owner.trimmingCharacters(in: .whitespaces).isEmpty
            && !repo.trimmingCharacters(in: .whitespaces).isEmpty
            && !trustedKeys.isEmpty
    }

    /// 随包配置：`Contents/Resources/update-config.json`。缺失／非法返回 nil
    /// （界面显示「未配置更新源」，不能显示「已是最新」）。
    public static func load(bundle: Bundle = .main) -> UpdateSourceConfig? {
        guard let url = bundle.url(forResource: "update-config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(UpdateSourceConfig.self, from: data),
              config.schema == 1 else { return nil }
        return config
    }

    public static func load(data: Data) -> UpdateSourceConfig? {
        try? JSONDecoder().decode(UpdateSourceConfig.self, from: data)
    }
}

public struct UpdateInstallation: Equatable, Sendable {
    public let version: String
    public let buildNumber: Int
    public let channel: UpdateChannel
    public let platform: String
    public let arch: String
    public let osVersion: String
    /// 已成功安装的数据指纹；缺失时同构建号的 schema 2 数据包需补装。
    public let installedDataVersion: String?

    public init(version: String, buildNumber: Int, channel: UpdateChannel,
                platform: String, arch: String, osVersion: String,
                installedDataVersion: String? = nil) {
        self.version = version; self.buildNumber = buildNumber; self.channel = channel
        self.platform = platform; self.arch = arch; self.osVersion = osVersion
        self.installedDataVersion = installedDataVersion
    }

    public static func current(bundle: Bundle = .main) -> UpdateInstallation {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(x86_64)
        let arch = "x86_64"
        #elseif arch(arm64)
        let arch = "arm64"
        #else
        let arch = "unknown"
        #endif
        let marker = bundle.resourceURL?.appendingPathComponent("EngineData/.gogaku-data-version")
        let installedDataVersion = marker.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return UpdateInstallation(version: version, buildNumber: build,
                                  channel: UpdateChannel.from(bundleIdentifier: bundle.bundleIdentifier),
                                  platform: "macos", arch: arch, osVersion: osVersion,
                                  installedDataVersion: installedDataVersion)
    }
}

public struct UpdateCheckOutcome: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case unconfigured
        case upToDate
        case available
        case dataUpdateAvailable
        case unsupported
        case noManifest
        case invalidManifest
        case rateLimited
        case networkError
        case noRelease
        case skipped
    }

    public let kind: Kind
    public let message: String
    public let candidate: UpdateCandidate?
    public let checkedAt: Date
    /// 代码升级或数据修复时携带（schema 2 且本平台有数据包；schema 1 或无数据包为 nil）。
    /// Codable 兼容旧缓存：缺键解码为 nil。
    public let dataPackage: UpdateDataPackage?

    public init(kind: Kind, message: String, candidate: UpdateCandidate? = nil,
                dataPackage: UpdateDataPackage? = nil, checkedAt: Date) {
        self.kind = kind; self.message = message; self.candidate = candidate
        self.dataPackage = dataPackage; self.checkedAt = checkedAt
    }

    enum CodingKeys: String, CodingKey {
        case kind, message, candidate, dataPackage, checkedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        message = try container.decode(String.self, forKey: .message)
        candidate = try container.decodeIfPresent(UpdateCandidate.self, forKey: .candidate)
        dataPackage = try container.decodeIfPresent(UpdateDataPackage.self, forKey: .dataPackage)
        checkedAt = try container.decode(Date.self, forKey: .checkedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(candidate, forKey: .candidate)
        try container.encodeIfPresent(dataPackage, forKey: .dataPackage)
        try container.encode(checkedAt, forKey: .checkedAt)
    }
}

public struct UpdateCandidate: Codable, Equatable, Sendable {
    public let releaseTag: String
    public let releaseName: String
    public let manifest: UpdateManifest
    public let asset: UpdateAsset
    public let downloadURL: URL
    public let publishedAt: Date?

    public init(releaseTag: String, releaseName: String, manifest: UpdateManifest,
                asset: UpdateAsset, downloadURL: URL, publishedAt: Date?) {
        self.releaseTag = releaseTag; self.releaseName = releaseName
        self.manifest = manifest; self.asset = asset
        self.downloadURL = downloadURL; self.publishedAt = publishedAt
    }
}

/// 双清单：新客户端优先 update-manifest-v2.json（schema 2，含 dataPackage），
/// 404／缺失回落 update-manifest.json（schema 1，只含主包——0.2.0 及更早
/// 客户端只认这个名字，照常升级主包）。
public enum UpdateManifestSourcing {
    /// 本安装形态的清单资产名（不含 -v2 后缀）。
    public static func baseManifestName(flavor: String = "full") -> String {
        flavor == "lite" ? "update-manifest-lite.json" : "update-manifest.json"
    }

    /// schema 2 清单资产名：基础名去掉 .json、加 -v2 再补回后缀
    /// （update-manifest.json → update-manifest-v2.json；
    ///   update-manifest-lite.json → update-manifest-lite-v2.json）。
    public static func v2ManifestName(flavor: String = "full") -> String {
        let base = baseManifestName(flavor: flavor)
        guard base.hasSuffix(".json") else { return base }
        return base.dropLast(5) + "-v2.json"
    }
}
