import Foundation

/// quickmt 开发版学习翻译后端（2026-11 用户裁决，docs/learning-quickmt-dev-decision.md）。
///
/// 形态：常驻外置 Python 辅助进程（`venv/bin/python`＋`quickmt_worker.py`，位于
/// `~/Library/Application Support/Gogaku/translation/`），CT2 INT8、双向两份权重，
/// 协议对齐 TranslationRequest／TranslationResult v1；无端口、无文本日志、无网络。
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
    /// 模型的质量试验，功能层不变）。未知值一律回退默认。
    public static let defaultBackend = "quickmt"
    public static let backendOptions = ["quickmt", "small100"]

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
    public static func serviceConfiguration(root: URL = directory(), beam: Int,
                                            backend: String = defaultBackend) -> (executable: URL, arguments: [String]) {
        switch normalizedBackend(backend) {
        case "small100":
            let base = root.appendingPathComponent("small100", isDirectory: true)
            return (base.appendingPathComponent("venv/bin/python"),
                    [base.appendingPathComponent("small100_worker.py").path,
                     "--beam", String(clampedBeam(beam))])
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

    /// 缺失时的准备指引（在仓库检出目录运行）。
    public static func prepareCommand(backend: String = defaultBackend) -> String {
        normalizedBackend(backend) == "small100"
            ? "python3 scripts/prepare-learning-small100.py"
            : "python3 scripts/prepare-learning-translation.py"
    }
}
