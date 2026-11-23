import Foundation
import CGogakuCore

/// 扩展词库存储与官方渠道客户端（设置进程使用；合同见 docs/dictionaries.md）。
/// 解析、转换、清单校验只有共享核心一份实现；这里只做线程、路径、网络传输
/// 与 Ed25519 验签（复用检查更新的 CryptoKit 链路）。
///
/// - 目录与两端共用：~/Library/Application Support/Gogaku/dictionaries/。
/// - 设置应用写盘后发送 `org.gogaku.dictionaries.changed`，输入法后台加载
///   词库后回引擎队列挂载；组合进行中由核心返回 3，输入法在组合结束后重试。
public enum DictionaryStore {

    public static let changedNotification =
        Notification.Name("org.gogaku.dictionaries.changed")

    /// 词库目录（stable／dev、完整版／Lite 共用）。
    public static var dictionariesDirectory: URL {
        Settings.chineseDirectory.appendingPathComponent("dictionaries", isDirectory: true)
    }

    /// 一本词库的展示信息（gc_dict_list 结果的 Swift 形状）。
    public struct Entry: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let origin: String          // import / official
        public let sourceFormat: String
        public let sourceFileName: String
        public let version: String
        public let license: String
        public let attribution: String
        public let sourceUrl: String
        public let addedAt: Int64
        public let entryCount: Int
        public let sizeBytes: Int64
        public let estimatedBytes: Int64
        public let enabled: Bool
        public let learning: Bool          // 学习引擎会挂载（阈值内且 learningAvailable）
        public let dropped: [String: Int]  // 导入时各丢弃原因计数

        public var isOfficial: Bool { origin == "official" }

        /// 内存估算展示（如 68 MB）。
        public var estimatedMemoryText: String {
            ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .memory)
        }
    }

    public struct Listing {
        public let entries: [Entry]
        public let enabledEstimatedBytes: Int64
        public let warn: Bool              // 启用合计超过 200MB：提醒但不阻止
        public let corrupt: [String]       // 损坏元数据文件（已备份 .corrupt）
    }

    /// 导入结果（gc_dict_import result JSON）。
    public struct ImportResult: Equatable {
        public let id: String
        public let name: String
        public let entryCount: Int
        public let dropped: [String: Int]
        public let sizeBytes: Int64
    }

    // MARK: - 错误

    public enum StoreError: Error, LocalizedError, Equatable {
        case parameter            // 返回码 1
        case io(String)           // 返回码 2：格式／I/O／写盘
        case cancelled            // 返回码 3
        case duplicate(String)    // 返回码 4：重复导入（含冲突 id）
        case verify(String)       // contentId 不符
        case catalog(String)      // 清单合同不符
        case notConfigured        // 未随包词典渠道配置

        public var errorDescription: String? {
            switch self {
            case .parameter: return "参数错误"
            case .io(let message): return message.isEmpty ? "文件格式或读写失败" : message
            case .cancelled: return "已取消"
            case .duplicate(let id): return "同一源文件已导入过（\(id)）"
            case .verify(let message): return message
            case .catalog(let message): return message
            case .notConfigured: return "未配置词库渠道"
            }
        }
    }

    // MARK: - C 指针辅助

    private static func copyOut(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        defer { gc_contract_free(pointer) }
        return String(cString: pointer)
    }

    // MARK: - 列表

    /// 读取词库列表。learningAvailable：完整版且学习翻译启用；否则 learning 全 false。
    public static func list(learningAvailable: Bool) throws -> Listing {
        var out: UnsafeMutablePointer<CChar>?
        let rc = gc_dict_list(dictionariesDirectory.path, learningAvailable ? 1 : 0, &out)
        guard rc == 0 else { throw StoreError.io("词库列表读取失败") }
        let json = copyOut(out)
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StoreError.io("词库列表解析失败")
        }
        var entries: [Entry] = []
        if let items = object["dictionaries"] as? [[String: Any]] {
            for item in items {
                guard let id = item["id"] as? String else { continue }
                var dropped: [String: Int] = [:]
                if let raw = item["dropped"] as? [String: Any] {
                    for (key, value) in raw where value is Int {
                        dropped[key] = value as? Int
                    }
                }
                entries.append(Entry(
                    id: id,
                    name: item["name"] as? String ?? id,
                    origin: item["origin"] as? String ?? "import",
                    sourceFormat: item["sourceFormat"] as? String ?? "",
                    sourceFileName: item["sourceFileName"] as? String ?? "",
                    version: item["version"] as? String ?? "",
                    license: item["license"] as? String ?? "",
                    attribution: item["attribution"] as? String ?? "",
                    sourceUrl: item["sourceUrl"] as? String ?? "",
                    addedAt: (item["addedAt"] as? NSNumber)?.int64Value ?? 0,
                    entryCount: item["entryCount"] as? Int ?? 0,
                    sizeBytes: (item["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                    estimatedBytes: (item["estimatedBytes"] as? NSNumber)?.int64Value ?? 0,
                    enabled: item["enabled"] as? Bool ?? false,
                    learning: item["learning"] as? Bool ?? false,
                    dropped: dropped))
            }
        }
        let corrupt = (object["corrupt"] as? [[String: Any]])?
            .compactMap { $0["file"] as? String } ?? []
        return Listing(
            entries: entries,
            enabledEstimatedBytes: (object["enabledEstimatedBytes"] as? NSNumber)?.int64Value ?? 0,
            warn: object["warn"] as? Bool ?? false,
            corrupt: corrupt)
    }

    // MARK: - 开关与删除

    public static func setEnabled(_ enabled: Bool, id: String) throws {
        var err = [CChar](repeating: 0, count: 256)
        let idCopy = id.unsafeConstUTF8Copy()
        defer { freeConst(idCopy) }
        let rc = gc_dict_set_enabled(dictionariesDirectory.path, idCopy, enabled ? 1 : 0,
                                     &err, err.count)
        notifyChanged()
        guard rc == 0 else { throw StoreError.io(String(cString: err)) }
    }

    public static func remove(id: String) throws {
        var err = [CChar](repeating: 0, count: 256)
        let idCopy = id.unsafeConstUTF8Copy()
        defer { freeConst(idCopy) }
        let rc = gc_dict_remove(dictionariesDirectory.path, idCopy, &err, err.count)
        notifyChanged()
        guard rc == 0 else { throw StoreError.io(String(cString: err)) }
    }

    /// 写盘后通知输入法（组合中由核心延迟到组合结束）。
    public static func notifyChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    // MARK: - 导入

    /// 后台导入一个源文件。progress 在调用线程回调（0…1）；isCancelled 返回
    /// true 时取消（核心清理临时文件，返回 3）。
    public static func importFile(at url: URL, displayName: String? = nil,
                                  progress: (@Sendable (Double) -> Bool)? = nil) throws -> ImportResult {
        try FileManager.default.createDirectory(at: dictionariesDirectory,
                                                withIntermediateDirectories: true)
        var req = GcDictImportRequest()
        let inputCopy = url.path.unsafeConstUTF8Copy()
        let dirCopy = dictionariesDirectory.path.unsafeConstUTF8Copy()
        let dictCopy = Paths.engineData.appendingPathComponent("sc.dict").path.unsafeConstUTF8Copy()
        let nameCopy = displayName?.unsafeConstUTF8Copy()
        defer {
            freeConst(inputCopy); freeConst(dirCopy); freeConst(dictCopy); freeConst(nameCopy)
        }
        req.input_path = inputCopy
        req.dictionaries_dir = dirCopy
        req.system_dict_path = dictCopy
        req.display_name = nameCopy

        // 进度回调桥：Swift 闭包 → C 函数指针（核心在调用方线程回调）。
        var resultJSON: UnsafeMutablePointer<CChar>?
        var err = [CChar](repeating: 0, count: 512)
        final class ProgressContext {
            let callback: @Sendable (Double) -> Bool
            init(_ callback: @escaping @Sendable (Double) -> Bool) { self.callback = callback }
            func invoke(done: Int, total: Int) -> Bool {
                callback(total > 0 ? Double(done) / Double(total) : 0)
            }
        }
        let context: UnsafeMutableRawPointer?
        let callbackFn: (@convention(c) (UnsafeMutableRawPointer?, Int, Int) -> Int32)?
        if let progress {
            let contextObject = ProgressContext(progress)
            context = Unmanaged.passRetained(contextObject).toOpaque()
            callbackFn = { rawCtx, done, total in
                guard let rawCtx else { return 0 }
                let context = Unmanaged<ProgressContext>.fromOpaque(rawCtx).takeUnretainedValue()
                return context.invoke(done: done, total: total) ? 0 : 1
            }
        } else {
            context = nil
            callbackFn = nil
        }
        defer {
            if let context { Unmanaged<ProgressContext>.fromOpaque(context).release() }
        }

        let rc = gc_dict_import(&req, callbackFn, context, &resultJSON, &err, err.count)
        let message = String(cString: err)
        let json = copyOut(resultJSON)
        let result: ImportResult
        switch rc {
        case 0:
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String else {
                throw StoreError.io("导入结果解析失败")
            }
            var dropped: [String: Int] = [:]
            if let raw = object["dropped"] as? [String: Any] {
                for (key, value) in raw where value is Int { dropped[key] = value as? Int }
            }
            result = ImportResult(
                id: id,
                name: object["name"] as? String ?? "",
                entryCount: object["entryCount"] as? Int ?? 0,
                dropped: dropped,
                sizeBytes: (object["sizeBytes"] as? NSNumber)?.int64Value ?? 0)
        case 1: throw StoreError.parameter
        case 2: throw StoreError.io(message)
        case 3: throw StoreError.cancelled
        case 4: throw StoreError.duplicate(message)
        default: throw StoreError.io(message.isEmpty ? "导入失败" : message)
        }
        notifyChanged()
        return result
    }
}
