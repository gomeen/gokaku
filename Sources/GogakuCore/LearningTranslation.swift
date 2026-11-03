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
    public static func serviceConfiguration(root: URL = directory(), beam: Int) -> (executable: URL, arguments: [String]) {
        (root.appendingPathComponent("venv/bin/python"),
         [root.appendingPathComponent("quickmt_worker.py").path,
          "--beam", String(clampedBeam(beam))])
    }

    /// 设置页后端状态：venv、worker、manifest 与两向权重是否就绪。
    public struct Environment: Equatable {
        public var ready: Bool
        public var missing: [String]
        public init(ready: Bool, missing: [String]) {
            self.ready = ready; self.missing = missing
        }
    }

    public static func environment(root: URL = directory()) -> Environment {
        let fm = FileManager.default
        var missing: [String] = []
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
        return Environment(ready: missing.isEmpty, missing: missing)
    }

    /// 缺失时的准备指引（在仓库检出目录运行）。
    public static let prepareCommand = "python3 scripts/prepare-learning-translation.py"
}
