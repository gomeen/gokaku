import Foundation

/// quickmt 开发版学习翻译后端（2026-11 用户裁决，docs/learning-quickmt-dev-decision.md）。
///
/// 形态：常驻外置 Python 辅助进程（`venv/bin/python`＋`quickmt_worker.py`，位于
/// `~/Library/Application Support/Gogaku/translation/`），CT2 INT8、双向两份权重，
/// 协议对齐 TranslationRequest／TranslationResult v1；无端口、无文本日志。
/// 网络边界（2026-11-04 用户裁决）：quickmt／small100 本地 worker 无网络；
/// volcengine worker 按设计联网（仅火山翻译 API 域），且只被学习模式拉起——
/// 普通模式不经任何翻译路径。
/// 这是「approved 仅由审核资源清单决定」规则的开发版豁免：成功结果以
/// `resource == quickmt-ct2-dev` 标记并按 approved 进入候选；正式质量门槛与
/// 双端交付口径不变，宿主安全矩阵与学习记录仍保持关闭。
public enum LearningTranslation {
    /// 请求／候选／结果的开发版资源标记：approved 豁免与候选窗标注以此识别。
    public static let resourceID = "quickmt-ct2-dev"
    /// beam 可调范围与默认值（用户指定默认 1；已知重复句等缺陷随 beam 升高缓解）。
    public static let beamRange = 1...10
    public static let defaultBeam = 1

    /// 翻译后端选项：quickmt（默认，快）｜small100（2026-11-03 用户裁决：仅换
    /// 模型的质量试验，功能层不变）｜volcengine（2026-11-04 用户裁决：云端 NMT，
    /// 仅学习模式联网）。未知值一律回退默认。
    /// 2026-11-04 修复：volcengine 未入白名单导致设置页/输入法把它归一化回
    /// quickmt（云端分区不显示、学习翻译实际仍走本地）。
    public static let defaultBackend = "quickmt"
    public static let backendOptions = ["quickmt", "small100", "volcengine"]

    public static func normalizedBackend(_ value: String?) -> String {
        guard let value, backendOptions.contains(value) else { return defaultBackend }
        return value
    }

    /// 装配目录（venv＋两向权重＋worker＋manifest，不进 app bundle）。
    public static func directory(at support: URL = Paths.support) -> URL {
        support.appendingPathComponent("translation", isDirectory: true)
    }

    public static func clampedBeam(_ value: Int) -> Int {
        min(max(value, beamRange.lowerBound), beamRange.upperBound)
    }

    /// TranslationService 启动配置：venv Python＋worker 脚本＋beam 启动参数。
    /// 路径缺失不在构造期校验：请求级错误（service_unavailable／model_missing）
    /// 走现行失败路径，设置页负责展示缺失与准备指引。
    /// small100 装在 translation/small100/ 子目录（独立 venv＋权重＋worker）。
    /// volcengine 用系统 python3＋stdlib worker（无 venv／权重）；凭据从
    /// translation/volcengine-credentials.json（0600）读取，不进命令行。
    public static func serviceConfiguration(root: URL = directory(), beam: Int,
                                            backend: String = defaultBackend) -> (executable: URL, arguments: [String]) {
        switch normalizedBackend(backend) {
        case "small100":
            let base = root.appendingPathComponent("small100", isDirectory: true)
            return (base.appendingPathComponent("venv/bin/python"),
                    [base.appendingPathComponent("small100_worker.py").path,
                     "--beam", String(clampedBeam(beam))])
        case "volcengine":
            return (URL(fileURLWithPath: "/usr/bin/python3"),
                    [root.appendingPathComponent("volcengine_translate_worker.py").path,
                     "--credentials", root.appendingPathComponent("volcengine-credentials.json").path])
        default:
            return (root.appendingPathComponent("venv/bin/python"),
                    [root.appendingPathComponent("quickmt_worker.py").path,
                     "--beam", String(clampedBeam(beam))])
        }
    }

    /// 设置页后端状态：venv、worker、manifest 与两向权重是否就绪。
    public struct Environment: Equatable {
        public var ready: Bool
        public var missing: [String]
        public init(ready: Bool, missing: [String]) {
            self.ready = ready; self.missing = missing
        }
    }

    public static func environment(root: URL = directory(), backend: String = defaultBackend) -> Environment {
        let fm = FileManager.default
        var missing: [String] = []
        switch normalizedBackend(backend) {
        case "small100":
            let base = root.appendingPathComponent("small100", isDirectory: true)
            if !fm.isExecutableFile(atPath: base.appendingPathComponent("venv/bin/python").path) {
                missing.append("venv（python）")
            }
            if !fm.fileExists(atPath: base.appendingPathComponent("small100_worker.py").path) {
                missing.append("small100_worker.py")
            }
            if !fm.fileExists(atPath: base.appendingPathComponent("manifest.json").path) {
                missing.append("manifest.json")
            }
            if !fm.fileExists(atPath: base.appendingPathComponent("ct2-int8/model.bin").path)
                || !fm.fileExists(atPath: base.appendingPathComponent("source/config.json").path) {
                missing.append("small100 权重")
            }
        case "volcengine":
            if !fm.fileExists(atPath: root.appendingPathComponent("volcengine_translate_worker.py").path) {
                missing.append("volcengine_translate_worker.py")
            }
            let credentials = root.appendingPathComponent("volcengine-credentials.json")
            var hasCredentials = false
            if let data = try? Data(contentsOf: credentials),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let accessKey = object["accessKeyId"] as? String, !accessKey.isEmpty,
               let secretKey = object["secretAccessKey"] as? String, !secretKey.isEmpty {
                hasCredentials = true
            }
            if !hasCredentials {
                missing.append("凭据文件（volcengine-credentials.json）")
            }
        default:
            if !fm.isExecutableFile(atPath: root.appendingPathComponent("venv/bin/python").path) {
                missing.append("venv（python）")
            }
            if !fm.fileExists(atPath: root.appendingPathComponent("quickmt_worker.py").path) {
                missing.append("quickmt_worker.py")
            }
            if !fm.fileExists(atPath: root.appendingPathComponent("manifest.json").path) {
                missing.append("manifest.json")
            }
            for name in ["quickmt-en-zh", "quickmt-zh-en"]
            where !fm.fileExists(atPath: root.appendingPathComponent(name)
                .appendingPathComponent("model.bin").path) {
                missing.append("\(name) 权重")
            }
        }
        return Environment(ready: missing.isEmpty, missing: missing)
    }

    /// 火山翻译凭据（读写 0600 凭据文件；绝不进 settings.json／仓库／同步）。
    public struct VolcengineCredentials: Equatable {
        public var accessKey: String
        public var secretKey: String
        public init(accessKey: String, secretKey: String) {
            self.accessKey = accessKey; self.secretKey = secretKey
        }
    }

    public static func volcengineCredentials(root: URL = directory()) -> VolcengineCredentials? {
        let path = root.appendingPathComponent("volcengine-credentials.json")
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessKey = object["accessKeyId"] as? String, !accessKey.isEmpty,
              let secretKey = object["secretAccessKey"] as? String, !secretKey.isEmpty else { return nil }
        return VolcengineCredentials(accessKey: accessKey, secretKey: secretKey)
    }

    public static func saveVolcengineCredentials(_ credentials: VolcengineCredentials, root: URL = directory()) throws {
        let payload: [String: Any] = ["accessKeyId": credentials.accessKey,
                                      "secretAccessKey": credentials.secretKey,
                                      "region": "cn-north-1",
                                      "host": "translate.volcengineapi.com"]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let path = root.appendingPathComponent("volcengine-credentials.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    /// 缺失时的准备指引（在仓库检出目录运行）。
    public static func prepareCommand(backend: String = defaultBackend) -> String {
        switch normalizedBackend(backend) {
        case "small100":
            return "python3 scripts/prepare-learning-small100.py"
        case "volcengine":
            return "python3 scripts/set-volcengine-credentials.py --access-key-id AKLT... --secret-access-key ..."
        default:
            return "python3 scripts/prepare-learning-translation.py"
        }
    }
}
