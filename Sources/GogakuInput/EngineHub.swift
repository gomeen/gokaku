import Foundation
import CGogakuCore
import GogakuCore

/// 进程级共享普通模式引擎：所有 IMK 控制器（每个宿主应用一个）共用同一个
/// 共享 C++ 核心会话与同一条串行队列，词库只加载一次；激活多个应用后常驻
/// 内存不随会话数增加。应用／输入框切换由核心的 focusSync 语义处理
/// （app／field 变化即清组合、恢复按应用默认英文），不依赖每会话隔离。
/// 学习会话（CompositionSession）按设置开关创建（quickmt 开发版裁决）；
/// 关闭时不创建，也不加载第二份词库。
final class EngineHub {
    static let shared = EngineHub()
    let queue = DispatchQueue(label: "org.gogaku.engine", qos: .userInteractive)

    private var normal: NormalEngine?
    private var learning: CompositionSession?
    private var creationLogged = false
    private var learningLogged = false
    /// 共享会话当前所在 (应用, 字段)：控制器检测自己是否已被切走（复查 B2）。
    var lastAppField: (app: String, field: String) = ("", "")

    /// 返回共享引擎；未创建时尝试创建（dict 缺失等返回 nil，下次再试）。
    func engine(_ settings: Settings) -> NormalEngine? {
        if let normal { return normal }
        let engine = makeEngine(settings)
        if engine == nil, !creationLogged {
            creationLogged = true
            NSLog("Gogaku EngineHub: 共享核心创建失败（词库缺失或损坏）")
        }
        normal = engine
        return engine
    }

    /// 设置可能影响引擎可用性时调用（如语言资源安装后）。
    func invalidateEngine() {
        normal = nil
        creationLogged = false
    }

    /// 学习会话门禁（quickmt 开发版裁决，docs/learning-quickmt-dev-decision.md）：
    /// 设置开关打开时创建真实共享会话（含第二份词库加载，仅首次约 1s，
    /// 在用户实际进入学习输入时发生）；关闭返回 nil 即回门禁态。
    /// 与 GogakuInputController.learningDevEnabled 同源（同一设置字段），
    /// 两处口径一致。只能在引擎队列上调用创建；读侧用 existingLearningSession。
    func learningSession(_ settings: Settings) -> CompositionSession? {
        guard settings.learningTranslationEnabled else { return nil }
        if let learning { return learning }
        do {
            let engine = try ChineseEngine(directory: Paths.engineData)
            learning = CompositionSession(engine: engine)
            learningLogged = false
            return learning
        } catch {
            // 词库缺失时每次学习键入重试（与共享普通引擎同策略），但只记一次日志。
            if !learningLogged {
                learningLogged = true
                NSLog("Gogaku EngineHub: 学习会话创建失败（词库缺失或损坏）")
            }
            return nil
        }
    }

    /// 已创建的共享学习会话（不触发创建／词库加载）。供读侧与重置路径；
    /// 主线程读引用属良性竞争（只判存在性，创建只在引擎队列发生）。
    var existingLearningSession: CompositionSession? { learning }

    /// 开发版开关关闭时释放共享学习会话（连带释放第二份词库内存）。
    func closeLearningSession() {
        learning = nil
        learningLogged = false
    }

    private func makeEngine(_ settings: Settings) -> NormalEngine? {
        var config = NormalEngineConfig(
            dictPath: Paths.engineData.appendingPathComponent("sc.dict").path,
            modelPath: Paths.engineData.appendingPathComponent("zh_CN.lm").path)
        config.userDir = Settings.chineseDirectory.path
        config.customWordsPath = Settings.customWordsPath.path
        config.englishWordsPath = Paths.engineData.appendingPathComponent("english-words.txt").path
        config.glossPath = Paths.engineData.appendingPathComponent("gloss.tsv").path
        config.scheme = settings.inputScheme == .fullPinyin ? Int32(GC_SCHEME_FULLPINYIN.rawValue) : Int32(GC_SCHEME_XIAOHE.rawValue)
        config.fuzzyMask = settings.fuzzyMask
        config.fullPinyinPreedit = settings.fullPinyinPreedit
        config.freqEnabled = settings.frequencyEnabled
        config.englishEnabled = settings.englishCandidatesEnabled
        let engine = NormalEngine(config: config)
        engine?.setAppDefaults(settings.enabledDefaultEnglishApps)
        engine?.setExcludedApps(Array(settings.quickAddExcludedApplications))
        if let message = engine?.creationError {
            NSLog("Gogaku NormalEngine: %@", message)
        }
        return engine
    }

    /// 引擎队列上同步执行（普通模式逐键路径）。
    func sync<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

    /// 引擎队列上异步执行。
    func async(_ body: @escaping () -> Void) { queue.async(execute: body) }
}
