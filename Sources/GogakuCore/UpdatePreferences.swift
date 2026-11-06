import Foundation

/// 每个页面的响应内容与 ETag 成对保存；URL 隔离不同仓库和页码。
struct UpdateReleasePage: Codable, Equatable, Sendable {
    let url: URL
    let etag: String?
    let releases: [UpdateEngine.GitHubRelease]
}

/// 更新偏好与检查节流。按计划「更新偏好单独版本化」：
/// - 自动检查默认关闭；
/// - 检查状态与节流时间按平台／安装通道独立保存；
/// - 自动检查每天最多尝试一次，网络失败不紧密重试；手动检查可立即重试。
public struct UpdatePreferences: Codable, Equatable, Sendable {
    public var schema: Int = 1
    public var autoCheck: Bool = false
    /// 自动检查最近一次尝试时间（epoch 秒），按通道。
    public var lastAutoCheck: [String: Double] = [:]
    /// GitHub releases 列表 ETag，按通道。
    public var etag: [String: String] = [:]
    /// 最近一次成功检查结果（仅用于界面复显，不用于 304），按通道。
    public var lastOutcome: [String: UpdateCheckOutcome] = [:]
    /// 仅在列表评估成功后保存，304 必须重新评估，不能复用 lastOutcome。
    var releasePages: [String: [UpdateReleasePage]] = [:]

    public init(schema: Int = 1, autoCheck: Bool = false,
                lastAutoCheck: [String: Double] = [:], etag: [String: String] = [:],
                lastOutcome: [String: UpdateCheckOutcome] = [:]) {
        self.schema = schema; self.autoCheck = autoCheck
        self.lastAutoCheck = lastAutoCheck; self.etag = etag; self.lastOutcome = lastOutcome
    }

    private enum CodingKeys: String, CodingKey {
        case schema, autoCheck, lastAutoCheck, etag, lastOutcome, releasePages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        autoCheck = try c.decodeIfPresent(Bool.self, forKey: .autoCheck) ?? false
        lastAutoCheck = try c.decodeIfPresent([String: Double].self, forKey: .lastAutoCheck) ?? [:]
        etag = try c.decodeIfPresent([String: String].self, forKey: .etag) ?? [:]
        // 损坏的单条结果只丢弃该条，不影响自动检查开关。
        lastOutcome = (try? c.decodeIfPresent([String: UpdateCheckOutcome].self, forKey: .lastOutcome)) ?? [:]
        // 旧偏好只有 ETag／结论，没有列表：下次必须无条件重新拉取。
        releasePages = (try? c.decodeIfPresent([String: [UpdateReleasePage]].self, forKey: .releasePages)) ?? [:]
    }
}

public final class UpdatePreferencesStore {
    public static let autoCheckInterval: TimeInterval = 24 * 60 * 60
    public private(set) var preferences: UpdatePreferences
    private let url: URL
    private let fileManager: FileManager

    public init(url: URL = Paths.support.appendingPathComponent("update-preferences.json"),
                fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(UpdatePreferences.self, from: data) {
            self.preferences = decoded
        } else {
            self.preferences = UpdatePreferences()
        }
        if self.preferences.schema < 1 { self.preferences.schema = 1 }
    }

    @discardableResult
    public func save() throws -> Bool {
        guard preferences != loadedPreferences else { return false }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        loadedPreferences = preferences
        return true
    }

    /// 最近一次落盘的快照；只有实际变化才写盘（避免每次检查都重写）。
    private var loadedPreferences: UpdatePreferences? {
        get { _loadedPreferences }
        set { _loadedPreferences = newValue }
    }
    private var _loadedPreferences: UpdatePreferences?

    public func setAutoCheck(_ enabled: Bool) throws {
        guard preferences.autoCheck != enabled else { return }
        preferences.autoCheck = enabled
        try save()
    }

    public func isAutoCheckDue(channel: UpdateChannel, now: Date = Date()) -> Bool {
        guard preferences.autoCheck else { return false }
        guard let last = preferences.lastAutoCheck[channel.rawValue] else { return true }
        return now.timeIntervalSince1970 - last >= Self.autoCheckInterval
    }

    /// 自动检查的「尝试」时间：成功、失败与限流都记录，避免紧密重试。
    public func recordAutoCheck(channel: UpdateChannel, now: Date = Date()) throws {
        preferences.lastAutoCheck[channel.rawValue] = now.timeIntervalSince1970
        try save()
    }

    func cachedReleasePages(for channel: UpdateChannel) -> [UpdateReleasePage] {
        preferences.releasePages[channel.rawValue] ?? []
    }

    /// 一次写入列表、对应的 ETag 与结论，失败检查不得更新任一项。
    func recordCheck(pages: [UpdateReleasePage], outcome: UpdateCheckOutcome,
                     channel: UpdateChannel) throws {
        let previous = preferences
        preferences.releasePages[channel.rawValue] = pages
        preferences.lastOutcome[channel.rawValue] = outcome
        preferences.etag[channel.rawValue] = pages.first?.etag
        do { try save() }
        catch { preferences = previous; throw error }
    }

    /// 兼容旧偏好的展示接口；条件请求只使用 cachedReleasePages 中的成对数据。
    public func etag(for channel: UpdateChannel) -> String? {
        preferences.etag[channel.rawValue]
    }

    public func setETag(_ value: String?, channel: UpdateChannel) throws {
        if let value, !value.isEmpty { preferences.etag[channel.rawValue] = value }
        else { preferences.etag.removeValue(forKey: channel.rawValue) }
        try save()
    }

    public func cachedOutcome(for channel: UpdateChannel) -> UpdateCheckOutcome? {
        preferences.lastOutcome[channel.rawValue]
    }

    public func setOutcome(_ outcome: UpdateCheckOutcome, channel: UpdateChannel) throws {
        preferences.lastOutcome[channel.rawValue] = outcome
        preferences.schema = max(1, preferences.schema)
        try save()
    }
}
