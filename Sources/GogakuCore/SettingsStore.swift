import Foundation
import AppKit

/// 设置写入协调器：串行处理提交，最新改动胜出。
///
/// 规则（2026-11-03 定稿）：
/// - 普通选项、应用列表、有效快捷键改动立即提交（`coalesce: false`）；
///   连续文本输入合并 300ms 后提交（`coalesce: true`）。
/// - 每次落盘前重新读取磁盘上的 settings.json，把「与上次已写基线的差异字段」
///   合并进去，避免旧整份快照覆盖其他页或输入法进程写入的偏好。
/// - 两个进程（设置应用与输入法）走同一文件协调规则（NSFileCoordinator），
///   磁盘操作不放入按键回调（调用方负责线程）。
/// - 仅成功落盘后发送 `org.gogaku.settings.changed`；失败保留待保存修改，
///   不伪报成功，不无限重试（重试由用户或下一次提交触发）。
public final class SettingsStore {
    public enum Outcome {
        case success
        case failure(String)
    }

    public enum Status: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    public static let changedNotification = Notification.Name("org.gogaku.settings.changed")

    /// 每进程一个实例；串行队列保证提交顺序。
    public static let shared = SettingsStore()

    private let queue = DispatchQueue(label: "org.gogaku.settings.store", qos: .utility)
    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("settings.json", isDirectory: false) }

    /// 最近一次成功读取或写入的顶层字段（合并基线）。
    private var baseline: [String: Any]?
    /// 待保存的最新值与是否还有待合并的改动。
    private var pendingValue: Settings?
    private var pendingWork: DispatchWorkItem?
    private var writing = false
    /// 主线程状态回调（saving／saved／failed）。
    public var onStatus: (@MainActor (Status) -> Void)?

    public init(directory: URL = Paths.support) {
        self.directory = directory
        // 初始化基线，避免首次提交把磁盘上未被 UI 加载的改动回滚。
        if let data = try? Data(contentsOf: fileURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            baseline = object
        }
    }

    // MARK: - 用量计量专用提交（不发设置变更通知）

    /// 仅合并火山用量两个字段落盘，不广播设置变更——全量提交会在每次翻译
    /// 成功后经 DistributedNotificationCenter 触发输入法 reloadSettings→
    /// suspend，致英→中面板每句闪没（2026-11-04 用户报告）。设置应用的用量
    /// 条在自身下次读取设置时刷新。
    public func submitUsage(characters: Int, month: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let fields = ["volcengineUsageCharacters": characters,
                          "volcengineUsageMonth": month]
            let url = self.fileURL
            if let written = Self.writeMerged(pending: fields, baseline: self.baseline, to: url) {
                self.baseline = written
            }
        }
    }

    // MARK: - 提交入口（任意线程）

    /// 立即提交；`coalesce` 用于连续文本输入（300ms 合并，最后一次胜出）。
    public func submit(_ value: Settings, coalesce: Bool = false, completion: (@MainActor (Outcome) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingValue = value
            self.pendingWork?.cancel()
            guard !self.writing else { return }   // 写入中：等本次写完再排下一次
            let work = DispatchWorkItem { [weak self] in self?.flush(completion: completion) }
            self.pendingWork = work
            self.queue.asyncAfter(deadline: .now() + (coalesce ? 0.3 : 0), execute: work)
        }
    }

    /// 失焦／关窗时的剩余提交；无待保存改动时为空操作。
    public func flushPending(completion: (@MainActor (Outcome) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, self.pendingValue != nil else { return }
            self.pendingWork?.cancel()
            self.writing ? self.reportStatus(.saving) : self.flush(completion: completion)
        }
    }

    /// 用户触发的重试；无失败待保存改动时为空操作。
    public func retry(completion: (@MainActor (Outcome) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, self.pendingValue != nil, !self.writing else { return }
            self.flush(completion: completion)
        }
    }

    // MARK: - 落盘（串行队列）

    private func flush(completion: (@MainActor (Outcome) -> Void)? = nil) {
        guard let value = pendingValue else { return }
        writing = true
        reportStatus(.saving)
        let url = fileURL
        let previousBaseline = baseline
        if let written = Self.writeMerged(value: value, baseline: previousBaseline, to: url) {
            baseline = written
            pendingValue = nil
            writing = false
            // 仅成功落盘后通知输入法重载。
            DistributedNotificationCenter.default().postNotificationName(Self.changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
            reportStatus(.saved)
            reportCompletion(completion, .success)
        } else {
            writing = false   // pendingValue 保留，等待重试或下一次提交
            reportStatus(.failed("设置写入失败：目录不可写或权限不足"))
            reportCompletion(completion, .failure("设置写入失败：目录不可写或权限不足"))
        }
        // 写入期间到达的新改动：排下一次 flush，保证最新改动胜出。
        if pendingValue != nil {
            let work = DispatchWorkItem { [weak self] in self?.flush(completion: nil) }
            pendingWork = work
            queue.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }

    private func reportCompletion(_ completion: (@MainActor (Outcome) -> Void)?, _ outcome: Outcome) {
        guard let completion else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(outcome) } }
    }

    private func reportStatus(_ status: Status) {
        guard let onStatus else { return }
        let reported = status
        DispatchQueue.main.async { MainActor.assumeIsolated { onStatus(reported) } }
    }

    // MARK: - 读改写合并

    /// 读取磁盘最新文件，只把相对基线发生变化的顶层字段合并进去后原子写入。
    /// 基线缺失（首次写入或文件损坏）时按整份写入。跨进程读写经
    /// NSFileCoordinator 协调，与输入法进程遵守同一文件协调规则。
    /// 返回写入结果（nil＝合并或写入失败，由调用方保留待保存改动）。
    static func writeMerged(value: Settings, baseline: [String: Any]?, to url: URL) -> [String: Any]? {
        let pendingDict = try? Self.dictionary(of: value)
        return writeMerged(pending: pendingDict ?? [:], baseline: baseline, to: url)
    }

    /// 任意字段的最小合并落盘（用量计量专用路径使用）。
    static func writeMerged(pending pendingDict: [String: Any], baseline: [String: Any]?, to url: URL) -> [String: Any]? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var mergedResult: [String: Any]?
            var accessorRan = false
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(writingItemAt: url, options: [], error: nil) { coordinatedURL in
                accessorRan = true
                let merged = Self.merge(pending: pendingDict, baseline: baseline, disk: Self.readDictionary(at: coordinatedURL))
                guard let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]) else { return }
                // 原子写入：成功 rename 才算落盘；失败保留原文件不动。
                if (try? data.write(to: coordinatedURL, options: .atomic)) != nil { mergedResult = merged }
            }
            // 访问块未运行或未确认写入都按失败计，不得伪报成功。
            guard accessorRan, mergedResult != nil else { return nil }
            return mergedResult
        } catch {
            return nil
        }
    }

    static func readDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func dictionary(of value: Settings) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "org.gogaku.settings", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "设置编码结果不是 JSON 对象"])
        }
        return object
    }

    /// 顶层字段合并：pending 与基线不同的字段胜出；其余保留磁盘值。
    /// 值比较用 JSON 等价（字典／数组递归比较），避免顺序差异误判。
    static func merge(pending: [String: Any], baseline: [String: Any]?, disk: [String: Any]?) -> [String: Any] {
        guard let baseline else { return pending }
        var merged = disk ?? pending
        for (key, pendingValue) in pending {
            let old = baseline[key]
            if !Self.jsonEqual(pendingValue, old) { merged[key] = pendingValue }
        }
        // pending 删除的键不会出现（Settings 无可选删除字段）；磁盘新键保留。
        return merged
    }

    static func jsonEqual(_ lhs: Any, _ rhs: Any?) -> Bool {
        guard let rhs else { return false }
        if let l = lhs as? [String: Any], let r = rhs as? [String: Any] {
            guard l.count == r.count else { return false }
            return l.allSatisfy { jsonEqual($1, r[$0]) }
        }
        if let l = lhs as? [Any], let r = rhs as? [Any] {
            guard l.count == r.count else { return false }
            return zip(l, r).allSatisfy { jsonEqual($0, $1) }
        }
        return (lhs as? NSObject) == (rhs as? NSObject)
    }
}
