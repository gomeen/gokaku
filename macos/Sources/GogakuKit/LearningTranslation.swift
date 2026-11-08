import Foundation

/// 学习翻译配置：只保留火山翻译（Volcengine NMT）。
///
/// 2026-11-06 双端功能统一计划裁决：两端移除本地翻译模型，不再随包模型、
/// CT2、SentencePiece、PyTorch，也不保留后端选择、beam 与模型准备入口。
/// 普通输入离线可用；学习翻译需要用户保存火山凭据并显式启用。
///
/// 形态：常驻外置辅助进程 `GogakuTranslator --volcengine`（随 app 包分发），
/// JSON 行协议对齐 TranslationRequest／TranslationResult v1；无端口、无文本日志。
/// 网络只发生在辅助进程内，且只访问火山翻译 API 域；普通模式不经任何翻译路径。
public enum LearningTranslation {
    /// 候选／结果资源标记：火山 NMT。只有该资源的成功结果按 approved 进入候选。
    public static let resourceID = "volcengine-nmt"
    /// 设置页展示名。
    public static let displayName = "火山翻译"

    /// 随包 helper（GogakuTranslator）。设置应用自身不运行输入法，按通道定位
    /// 已安装（或同目录 dist）的输入法 app；输入法进程则使用自己的 bundle。
    public static func helperURL(bundle: Bundle = .main) -> URL {
        if bundle.bundleIdentifier?.hasPrefix("org.gogaku.inputmethod") == true {
            return bundle.bundleURL.appendingPathComponent("Contents/Helpers/GogakuTranslator")
        }
        let dev = bundle.bundleIdentifier?.hasSuffix(".dev") == true
        let name = dev ? "Gogaku Dev.app" : "Gogaku.app"
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/").appendingPathComponent(name)
            .appendingPathComponent("Contents/Helpers/GogakuTranslator")
        if FileManager.default.isExecutableFile(atPath: installed.path) { return installed }
        return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(name)
            .appendingPathComponent("Contents/Helpers/GogakuTranslator")
    }

    /// 辅助进程启动配置：helper ＋ 凭据文件路径。凭据不进命令行。
    public static func serviceConfiguration(
        bundle: Bundle = .main,
        root: URL = directory(),
        helperOverride: URL? = nil
    ) -> (executable: URL, arguments: [String]) {
        ((helperOverride ?? helperURL(bundle: bundle)),
         ["--volcengine", "--credentials", credentialsPath(root: root).path])
    }

    /// 装配目录：只放凭据文件；不再有 venv、权重或模型 manifest。
    public static func directory(at support: URL = Paths.support) -> URL {
        support.appendingPathComponent("translation", isDirectory: true)
    }

    public static func credentialsPath(root: URL = directory()) -> URL {
        root.appendingPathComponent("volcengine-credentials.json")
    }

    /// 设置页状态：helper 是否存在、凭据是否可解析。缺失项逐条展示。
    public struct Environment: Equatable, Sendable {
        public var ready: Bool
        public var missing: [String]
        public var hasCredentials: Bool
        public init(ready: Bool, missing: [String], hasCredentials: Bool) {
            self.ready = ready; self.missing = missing; self.hasCredentials = hasCredentials
        }
    }

    public static func environment(bundle: Bundle = .main, root: URL = directory(),
                                   helperOverride: URL? = nil) -> Environment {
        let fm = FileManager.default
        var missing: [String] = []
        let helper = helperOverride ?? helperURL(bundle: bundle)
        if !fm.isExecutableFile(atPath: helper.path) {
            missing.append("翻译辅助进程（GogakuTranslator）")
        }
        let path = credentialsPath(root: root)
        let credentials = try? VolcengineCredentials.load(at: path)
        if credentials == nil { missing.append("火山翻译凭据") }
        return Environment(ready: missing.isEmpty, missing: missing, hasCredentials: credentials != nil)
    }

    public static func credentials(root: URL = directory()) -> VolcengineCredentials? {
        try? VolcengineCredentials.load(at: credentialsPath(root: root))
    }

    public static func saveCredentials(_ credentials: VolcengineCredentials,
                                       root: URL = directory()) throws {
        try credentials.save(at: credentialsPath(root: root))
    }

    public static func removeCredentials(root: URL = directory()) throws {
        try VolcengineCredentials.remove(at: credentialsPath(root: root))
    }

    /// 用户点击「连接测试」时调用：真实签名＋TLS＋一次短文本请求。
    /// 不写 usage、不缓存；设置页只展示结果与耗时。
    public static func testConnection(root: URL = directory(),
                                      source: String = "你好") async throws -> VolcengineResult {
        let client = VolcengineClient(credentialsPath: credentialsPath(root: root), timeout: 12)
        return try await client.translate(source: source, direction: .zhToEn)
    }

    /// 统一失败文案：保留输入、明确原文上屏，不自动提交或切语言。
    public static func failureMessage(_ error: String) -> String {
        let name = displayName
        switch error {
        case "credentials_missing":
            return "\(name)凭据未配置：在设置「学习翻译」保存 Access Key ID 与 Secret Access Key；输入已保留，可 ⌘Return 明确原文上屏"
        case "timeout":
            return "\(name)超时；输入已保留，可 ⌘Return 明确原文上屏"
        case "service_unavailable", "service_exited", "service_eof":
            return "\(name)辅助进程不可用；输入已保留，可 ⌘Return 明确原文上屏"
        case "backend_error", "empty_output":
            return "\(name)未返回可用译文；输入已保留，可 ⌘Return 明确原文上屏"
        case "auth_error":
            return "\(name)认证或权限失败：检查 Access Key ID／Secret Key 与翻译服务权限；输入已保留，可 ⌘Return 明确原文上屏"
        case "network_error":
            return "\(name)网络不可用或请求失败；输入已保留，可 ⌘Return 明确原文上屏"
        case "unsupported_host":
            return "\(name)服务地址不受支持；输入已保留，可 ⌘Return 明确原文上屏"
        case "invalid_request":
            return "\(name)请求无效；输入已保留，可 ⌘Return 明确原文上屏"
        default:
            return "\(name)翻译失败（\(error)）；输入已保留，可 ⌘Return 明确原文上屏"
        }
    }

    /// 设置页「连接测试」的短文案：不包含输入保留／原文上屏提示。
    public static func connectionErrorMessage(_ error: Error) -> String {
        switch errorCode(for: error) {
        case "credentials_missing": return "凭据未配置或文件不可读"
        case "auth_error": return "认证失败：检查 Access Key ID／Secret Key 与翻译服务权限"
        case "timeout": return "连接超时"
        case "network_error": return "无法连接火山翻译服务（网络或代理）"
        case "unsupported_host": return "服务地址不受支持"
        case "empty_output": return "服务返回空译文"
        default: return "翻译服务返回错误（\(errorCode(for: error))）"
        }
    }

    /// worker 错误码 → 稳定的用户可见错误码（设置页与状态行共用）。
    public static func errorCode(for error: Error) -> String {
        switch error {
        case VolcengineError.credentialsMissing: return "credentials_missing"
        case VolcengineError.timeout: return "timeout"
        case VolcengineError.network: return "network_error"
        case VolcengineError.unsupportedHost: return "unsupported_host"
        case VolcengineError.emptyOutput: return "empty_output"
        case let VolcengineError.backend(status):
            return status == 401 || status == 403 ? "auth_error" : "backend_error"
        default: return "backend_error"
        }
    }
}
