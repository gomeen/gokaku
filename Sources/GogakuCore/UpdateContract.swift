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

public struct UpdateManifest: Codable, Equatable, Sendable {
    public let schema: Int
    public let keyId: String
    public let version: String
    public let buildNumber: Int
    public let channel: UpdateChannel
    public let notes: String
    public let assets: [UpdateAsset]

    public init(schema: Int = 1, keyId: String, version: String, buildNumber: Int,
                channel: UpdateChannel, notes: String, assets: [UpdateAsset]) {
        self.schema = schema; self.keyId = keyId; self.version = version
        self.buildNumber = buildNumber; self.channel = channel
        self.notes = notes; self.assets = assets
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

    public var errorDescription: String? {
        switch self {
        case .malformedManifest: return "更新清单格式非法"
        case let .unsupportedSchema(schema): return "不支持的更新清单版本：\(schema)"
        case let .unknownKey(key): return "更新清单使用了未知公钥：\(key)"
        case let .malformedPublicKey(key): return "内置公钥格式非法：\(key)"
        case .malformedSignature: return "更新清单签名格式非法"
        case .invalidSignature: return "更新清单签名验证失败"
        case let .invalidField(field): return "更新清单字段非法：\(field)"
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
        guard manifest.schema == 1 else { throw UpdateManifestError.unsupportedSchema(manifest.schema) }
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

    public init(version: String, buildNumber: Int, channel: UpdateChannel,
                platform: String, arch: String, osVersion: String) {
        self.version = version; self.buildNumber = buildNumber; self.channel = channel
        self.platform = platform; self.arch = arch; self.osVersion = osVersion
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
        return UpdateInstallation(version: version, buildNumber: build,
                                  channel: UpdateChannel.from(bundleIdentifier: bundle.bundleIdentifier),
                                  platform: "macos", arch: arch, osVersion: osVersion)
    }
}

public struct UpdateCheckOutcome: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case unconfigured
        case upToDate
        case available
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

    public init(kind: Kind, message: String, candidate: UpdateCandidate? = nil, checkedAt: Date) {
        self.kind = kind; self.message = message; self.candidate = candidate; self.checkedAt = checkedAt
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
