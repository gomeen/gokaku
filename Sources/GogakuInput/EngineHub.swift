import Foundation
import CGogakuCore
import GogakuCore

/// 进程级共享普通模式引擎：所有 IMK 控制器（每个宿主应用一个）共用同一个
/// 共享 C++ 核心会话与同一条串行队列，词库只加载一次；激活多个应用后常驻
/// 内存不随会话数增加。应用／输入框切换由核心的 focusSync 语义处理
/// （app／field 变化即清组合、恢复按应用默认英文），不依赖每会话隔离。
/// 学习路径（CompositionSession／ChineseEngine）只有在学习安全验收通过后
/// 才创建；当前模型门槛未通过，永不创建，也不加载第二份词库。
final class EngineHub {
    static let shared = EngineHub()
    let queue = DispatchQueue(label: "org.gogaku.engine", qos: .userInteractive)

    private var normal: NormalEngine?
    private var learning: CompositionSession?
    private var creationLogged = false
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

    func learningSession(_ settings: Settings) -> CompositionSession? {
        // 真实宿主安全矩阵与翻译模型未通过前不创建学习会话（连带不加载词库）；
        // 门禁与 GogakuInputController.learningHostValidated 同源，验收通过时两处一起改。
        return nil
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
