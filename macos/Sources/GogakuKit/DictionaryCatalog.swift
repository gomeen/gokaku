import Foundation
import CGogakuCore
import CryptoKit

/// 官方精选词库渠道客户端（合同见 docs/dictionaries.md §七）。
/// 只在用户点击「获取更多词库」时联网；清单为 `catalog.json`＋分离 Ed25519
/// 签名，从 gogaku-dicts 仓库 latest release 获取。签名公钥复用检查更新的
/// trustedKeys；字段与合同校验（kind／schema／keyId／防回滚／downloadUrl
/// 前缀）只有共享核心一份实现（gc_dict_catalog_parse）。
public enum DictionaryCatalog {

    /// 随包配置：`Contents/Resources/dictionary-catalog-config.json`。
    public struct Config: Codable, Equatable {
        public let schema: Int
        public let owner: String
        public let repo: String
        public let trustedKeyIds: [String]
    }

    public struct Entry: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let category: String
        public let entryDescription: String
        public let version: String
        public let license: String
        public let attribution: String
        public let sourceUrl: String
        public let downloadUrl: String
        public let size: Int64
        public let sha256: String
        public let entryCount: Int64
        public let installed: Bool
        public let updateAvailable: Bool

        public var sizeText: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .memory)
        }
    }

    public struct Snapshot: Equatable {
        public let entries: [Entry]
        public let rejected: [String]
        public let catalogVersion: Int64
    }

    public enum CatalogError: Error, LocalizedError, Equatable {
        case notConfigured
        case invalidConfig
        case signature(String)
        case contract(String)
        case checksum
        case transfer(UpdateTransportError)

        public var errorDescription: String? {
            switch self {
            case .notConfigured: return "未配置词库渠道"
            case .invalidConfig: return "词库渠道配置非法"
            case .signature(let message): return "清单签名校验失败：\(message)"
            case .contract(let message): return "清单内容不合格式：\(message)"
            case .checksum: return "下载的词库与清单校验值不符"
            case .transfer(let error): return error.errorDescription
            }
        }
    }

    /// 随包配置读取（缺失／非法返回 nil；页面显示「未配置词库渠道」）。
    public static func loadConfig(bundle: Bundle = .main) -> Config? {
        guard let url = bundle.url(forResource: "dictionary-catalog-config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data),
              config.schema == 1 else { return nil }
        return config
    }

    private static func copyOut(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        defer { gc_contract_free(pointer) }
        return String(cString: pointer)
    }

    /// 本地防回滚记录：已安装官方词库元数据里的最大 catalogVersion。
    public static func localCatalogVersion(entries: [DictionaryStore.Entry]) -> Int64 {
        max(0, entries.compactMap { entry -> Int64? in
            entry.isOfficial ? readMetaCatalogVersion(id: entry.id) : nil
        }.max() ?? 0)
    }

    private static func readMetaCatalogVersion(id: String) -> Int64? {
        let metaURL = DictionaryStore.dictionariesDirectory.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: metaURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = (object["catalogVersion"] as? NSNumber)?.int64Value else { return nil }
        return version
    }

    /// 拉取并校验官方清单。签名在平台侧验证（CryptoKit）；字段与合同在核心校验。
    public static func fetch(transport: UpdateTransport,
                             config: Config,
                             updateKeys: [UpdateTrustedKey],
                             installed: [DictionaryStore.Entry]) async throws -> Snapshot {
        guard !config.owner.isEmpty, !config.repo.isEmpty, !config.trustedKeyIds.isEmpty else {
            throw CatalogError.notConfigured
        }
        let base = "https://github.com/\(config.owner)/\(config.repo)/releases/latest/download/"
        guard let manifestURL = URL(string: base + "catalog.json"),
              let signatureURL = URL(string: base + "catalog.json.sig") else {
            throw CatalogError.invalidConfig
        }
        // 传输失败（离线／超时／HTTP 等）统一包成 CatalogError.transfer，
        // 页面按错误类型给出不同提示。
        let manifestResponse: UpdateHTTPResponse
        let signatureResponse: UpdateHTTPResponse
        do {
            manifestResponse = try await transport.getAsset(manifestURL, headers: [:],
                                                            timeout: 15, maxBytes: 4 * 1024 * 1024)
            guard manifestResponse.status == 200 else {
                throw CatalogError.transfer(.http(manifestResponse.status))
            }
            signatureResponse = try await transport.getAsset(signatureURL, headers: [:],
                                                             timeout: 15, maxBytes: 4096)
            guard signatureResponse.status == 200 else {
                throw CatalogError.transfer(.http(signatureResponse.status))
            }
        } catch let error as CatalogError {
            throw error
        } catch let error as UpdateTransportError {
            throw CatalogError.transfer(error)
        }
        try verifySignature(manifestBytes: manifestResponse.body,
                            signature: signatureResponse.body,
                            trustedKeyIds: config.trustedKeyIds,
                            trustedKeys: updateKeys)

        // 核心合同校验：kind／schema／keyId／防回滚／downloadUrl 前缀／字段。
        // 清单本身从 latest/download 拉取；条目 downloadUrl 必须在本仓库
        // releases/download/ 前缀下（合同）。
        let downloadPrefix = "https://github.com/\(config.owner)/\(config.repo)/releases/download/"
        let configJSON = """
        {"trustedKeyIds":\(jsonArray(config.trustedKeyIds)),"downloadPrefix":\(jsonString(downloadPrefix)),\
        "catalogVersion":\(localCatalogVersion(entries: installed))}
        """
        let installedJSON = jsonArrayObjects(installed.map { ["id": $0.id, "version": $0.version] })
        var resultJSON: UnsafeMutablePointer<CChar>?
        var err = [CChar](repeating: 0, count: 512)
        let configCopy = configJSON.unsafeConstUTF8Copy()
        let installedCopy = installedJSON.unsafeConstUTF8Copy()
        defer { freeConst(configCopy); freeConst(installedCopy) }
        let manifestParseRc: Int32 = manifestResponse.body.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 1 }
            return gc_dict_catalog_parse(
                base.assumingMemoryBound(to: UInt8.self), manifestResponse.body.count,
                configCopy, installedCopy, &resultJSON, &err, err.count)
        }
        let message = String(cString: err)
        let json = copyOut(resultJSON)
        guard manifestParseRc == 0 else {
            throw manifestParseRc == 3
                ? CatalogError.contract(message.isEmpty ? "清单不是合法 JSON" : message)
                : CatalogError.contract(message.isEmpty ? "清单不合格式" : message)
        }
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.contract("清单结果解析失败")
        }
        var entries: [Entry] = []
        if let items = object["dictionaries"] as? [[String: Any]] {
            for item in items {
                guard let id = item["id"] as? String else { continue }
                entries.append(Entry(
                    id: id,
                    name: item["name"] as? String ?? id,
                    category: item["category"] as? String ?? "",
                    entryDescription: item["description"] as? String ?? "",
                    version: item["version"] as? String ?? "",
                    license: item["license"] as? String ?? "",
                    attribution: item["attribution"] as? String ?? "",
                    sourceUrl: item["sourceUrl"] as? String ?? "",
                    downloadUrl: item["downloadUrl"] as? String ?? "",
                    size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                    sha256: item["sha256"] as? String ?? "",
                    entryCount: (item["entryCount"] as? NSNumber)?.int64Value ?? 0,
                    installed: item["installed"] as? Bool ?? false,
                    updateAvailable: item["updateAvailable"] as? Bool ?? false))
            }
        }
        let rejected = (object["rejected"] as? [[String: Any]])?.compactMap { item -> String? in
            guard let id = item["id"] as? String, let reason = item["reason"] as? String else { return nil }
            return "\(id)：\(reason)"
        } ?? []
        return Snapshot(entries: entries, rejected: rejected,
                        catalogVersion: (object["catalogVersion"] as? NSNumber)?.int64Value ?? 0)
    }

    /// 下载并安装一个官方词库。哈希与大小校验在核心（gc_dict_install）。
    public static func install(_ entry: Entry, catalogVersion: Int64,
                               transport: UpdateTransport,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = URL(string: entry.downloadUrl) else {
            throw CatalogError.contract("下载地址非法")
        }
        let (tempURL, _) = try await transport.download(url, timeout: 300) { bytes in
            if entry.size > 0 { progress(min(1, Double(bytes) / Double(entry.size))) }
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try FileManager.default.createDirectory(at: DictionaryStore.dictionariesDirectory,
                                                withIntermediateDirectories: true)
        let entryJSON = """
        {"id":\(jsonString(entry.id)),"name":\(jsonString(entry.name)),\
        "version":\(jsonString(entry.version)),"license":\(jsonString(entry.license)),\
        "attribution":\(jsonString(entry.attribution)),"sourceUrl":\(jsonString(entry.sourceUrl)),\
        "size":\(entry.size),"sha256":\(jsonString(entry.sha256)),\
        "entryCount":\(entry.entryCount),"catalogVersion":\(catalogVersion)}
        """
        var err = [CChar](repeating: 0, count: 512)
        let dirCopy = DictionaryStore.dictionariesDirectory.path.unsafeConstUTF8Copy()
        let pathCopy = tempURL.path.unsafeConstUTF8Copy()
        let entryCopy = entryJSON.unsafeConstUTF8Copy()
        defer { freeConst(dirCopy); freeConst(pathCopy); freeConst(entryCopy) }
        let rc = gc_dict_install(dirCopy, pathCopy, entryCopy, &err, err.count)
        let message = String(cString: err)
        switch rc {
        case 0: break
        case 4: throw CatalogError.checksum
        case 1: throw CatalogError.contract(message.isEmpty ? "参数错误" : message)
        default: throw CatalogError.contract(message.isEmpty ? "安装失败" : message)
        }
        DictionaryStore.notifyChanged()
    }

    /// 页面错误文案：离线／超时／404／验签失败／哈希不符／URL 越界分别可辨。
    public static func failureMessage(_ error: Error) -> String {
        if let catalogError = error as? CatalogError {
            if case .transfer(let transport) = catalogError {
                switch transport {
                case .offline: return "无法连接词库渠道（离线）"
                case .timeout: return "连接词库渠道超时"
                case .http(404): return "词库渠道还没有发布清单（404）"
                case .http(let status): return "词库渠道返回 HTTP \(status)"
                case .cancelled: return "已取消"
                default: break
                }
            }
            return catalogError.errorDescription ?? "获取词库清单失败"
        }
        if let storeError = error as? DictionaryStore.StoreError {
            return storeError.errorDescription ?? "操作失败"
        }
        return error.localizedDescription
    }

    // MARK: - 签名与 JSON 工具

    /// 分离 Ed25519 签名验证：keyId 必须在随包 trustedKeyIds 里，公钥材料来自
    /// 检查更新的 trustedKeys（同一密钥，kind 字段区分清单）。
    static func verifySignature(manifestBytes: Data, signature: Data,
                                trustedKeyIds: [String],
                                trustedKeys: [UpdateTrustedKey]) throws {
        let manifestObject = (try? JSONSerialization.jsonObject(with: manifestBytes)) as? [String: Any]
        guard let keyId = manifestObject?["keyId"] as? String else {
            throw CatalogError.signature("清单缺少 keyId")
        }
        guard trustedKeyIds.contains(keyId) else {
            throw CatalogError.signature("keyId \(keyId) 不在信任列表")
        }
        guard let trusted = trustedKeys.first(where: { $0.keyId == keyId }),
              let keyData = Data(base64Encoded: trusted.publicKey),
              keyData.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw CatalogError.signature("找不到 keyId \(keyId) 的公钥")
        }
        let signatureBytes: Data
        if signature.count == 64 {
            signatureBytes = signature
        } else {
            let text = String(decoding: signature, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let decoded = Data(base64Encoded: text), decoded.count == 64 else {
                throw CatalogError.signature("签名文件非法")
            }
            signatureBytes = decoded
        }
        guard publicKey.isValidSignature(signatureBytes, for: manifestBytes) else {
            throw CatalogError.signature("签名与清单内容不符")
        }
    }

    static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }

    static func jsonArray(_ values: [String]) -> String {
        let items = values.map(jsonString).joined(separator: ",")
        return "[\(items)]"
    }

    static func jsonArrayObjects(_ objects: [[String: String]]) -> String {
        let items = objects.map { object -> String in
            let pairs = object.sorted { $0.key < $1.key }
                .map { "\(jsonString($0.key)):\(jsonString($0.value))" }
            return "{\(pairs.joined(separator: ","))}"
        }
        return "[\(items.joined(separator: ","))]"
    }
}
