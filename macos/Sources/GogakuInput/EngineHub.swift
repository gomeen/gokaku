import Foundation
import CGogakuCore
import GogakuKit

/// 进程级共享普通模式引擎：所有 IMK 控制器（每个宿主应用一个）共用同一个
/// 共享 C++ 核心会话与同一条串行队列，词库只加载一次；激活多个应用后常驻
/// 内存不随会话数增加。应用／输入框切换由核心的 focusSync 语义处理
/// （app／field 变化即清组合、恢复按应用默认英文），不依赖每会话隔离。
/// 学习会话（CompositionSession）按学习开关创建（2026-11-06 双端统一计划）；
/// 关闭时不创建，也不加载第二份词库。
final class EngineHub {
    static let shared = EngineHub()
    /// 设置应用写盘后发出的分布式通知（与 GogakuKit DictionaryStore 同名合同）。
    static let dictionariesChangedNotification =
        Notification.Name("org.gogaku.dictionaries.changed")
    let queue = DispatchQueue(label: "org.gogaku.engine", qos: .userInteractive)
    /// 词库解析队列（QoS utility）：gc_dict_load 在这里执行，不占引擎队列
    ///（docs/dictionaries.md §六）。
    private let dictQueue = DispatchQueue(label: "org.gogaku.dictionaries", qos: .utility)
    /// 待重试的挂载集合（引擎队列上访问；句柄未被核心消费，替换时手动释放）。
    private var pendingNormalApply: (ids: [String], handles: [OpaquePointer?])?
    private var pendingLearningApply: (ids: [String], handles: [OpaquePointer?])?

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

    /// 学习会话门禁：只有用户启用学习翻译（且未处于 Lite 模式、凭据就绪）时才
    /// 创建真实共享会话（含第二份词库加载，仅首次约 1s，在用户实际进入学习
    /// 输入时发生）；关闭返回 nil 即回门禁态。与 GogakuInputController 同源：
    /// `Settings.learningEnabled`。
    /// 只能在引擎队列上调用创建；读侧用 existingLearningSession。
    /// 学习组合状态机在共享 C++ 核心（ABI v3）中；这里只创建薄封装。
    func learningSession(_ settings: Settings) -> CompositionSession? {
        guard settings.learningEnabled else { return nil }
        if let learning { return learning }
        do {
            let session = try CompositionSession(config: CompositionSession.Config(
                dictPath: Paths.engineData.appendingPathComponent("sc.dict").path,
                modelPath: Paths.engineData.appendingPathComponent("zh_CN.lm").path))
            learning = session
            learningLogged = false
            return session
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

    /// 学习开关关闭时释放共享学习会话（连带释放第二份词库内存）。
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
        #if !GOGAKU_LITE
        config.glossPath = Paths.engineData.appendingPathComponent("gloss.tsv").path
        #endif
        config.scheme = settings.inputScheme.coreValue
        config.fuzzyMask = settings.fuzzyMask
        config.fullPinyinPreedit = settings.fullPinyinPreedit
        config.freqEnabled = settings.frequencyEnabled
        config.englishEnabled = settings.englishCandidatesEnabled
        let engine = NormalEngine(config: config)
        engine?.setAppDefaults(settings.enabledDefaultEnglishApps)
        Self.applyPageSizes(to: engine, settings: settings)
        if let message = engine?.creationError {
            NSLog("Gogaku NormalEngine: %@", message)
        }
        return engine
    }

    /// 引擎队列上同步执行（普通模式逐键路径）。
    func sync<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

    /// 引擎队列上异步执行。
    func async(_ body: @escaping () -> Void) { queue.async(execute: body) }

    // MARK: - 扩展词库挂载（docs/dictionaries.md §六：后台串行队列解析，
    // 回引擎队列 apply；组合中核心返回 3，在组合结束后的下一个事件前重试）

    /// 有待重试的挂载（输入侧在每个事件后查询，非组合状态时冲刷）。引擎队列
    /// 上写入，主线程只读存在性（与 existingLearningSession 同口径）。
    var hasPendingDictApply: Bool {
        pendingNormalApply != nil || pendingLearningApply != nil
    }

    /// 设置应用写盘后的通知入口：后台解析全部启用词库，回引擎队列应用。
    /// 普通会话与学习会话各自独立解析加载（句柄所有权不能跨会话共享）。
    func reloadDictionaries(learningEnabled: Bool) {
        dictQueue.async { [weak self] in
            guard let self else { return }
            let (ids, handles) = self.loadEnabledDictHandles(learningAvailable: learningEnabled)
            self.queue.async { [weak self] in
                self?.applyDictionaries(ids: ids, handles: handles)
            }
        }
    }

    /// dictQueue：加载全部启用词库；返回的句柄所有权随集合移交。
    private func loadEnabledDictHandles(learningAvailable: Bool) -> ([String], [OpaquePointer?]) {
        do {
            let listing = try DictionaryStore.list(learningAvailable: learningAvailable)
            var ids: [String] = []
            var handles: [OpaquePointer?] = []
            for entry in listing.entries where entry.enabled {
                var handle: OpaquePointer?
                var err = [CChar](repeating: 0, count: 256)
                let idCopy = entry.id.unsafeConstUTF8Copy()
                defer { freeConst(idCopy) }
                let rc = gc_dict_load(DictionaryStore.dictionariesDirectory.path,
                                      idCopy, &handle, &err, err.count)
                if rc == 0, let handle {
                    ids.append(entry.id)
                    handles.append(handle)
                } else {
                    NSLog("Gogaku EngineHub: 词库 %@ 加载失败（%d）",
                          entry.id as NSString, rc)
                }
            }
            return (ids, handles)
        } catch {
            NSLog("Gogaku EngineHub: 词库列表读取失败")
            return ([], [])
        }
    }

    /// 引擎队列上应用挂载集合。组合中把句柄存为待重试；替换待重试集合时
    /// 释放旧句柄（未被核心消费）。学习会话独立解析加载（阈值过滤在核心）。
    private func applyDictionaries(ids: [String], handles: [OpaquePointer?]) {
        if let pending = pendingNormalApply { freeHandles(pending.handles) }
        pendingNormalApply = nil
        if let pending = pendingLearningApply { freeHandles(pending.handles) }
        pendingLearningApply = nil

        if let normal {
            if normal.applyDicts(ids: ids, handles: handles) == 3 {
                pendingNormalApply = (ids: ids, handles: handles)
            }
            // 返回 0／2：非空句柄已由核心释放（含内部错误路径）。
        } else {
            freeHandles(handles)
        }
        // 学习会话独立加载；无会话（学习关闭或未创建）不加载。
        if existingLearningSession != nil, !ids.isEmpty {
            let target = ids
            dictQueue.async { [weak self] in
                self?.loadAndApplyLearning(ids: target)
            }
        }
    }

    /// 学习会话的独立加载（组合中返回 3 转待重试）。
    private func loadAndApplyLearning(ids: [String]) {
        var handles: [OpaquePointer?] = []
        for id in ids {
            var handle: OpaquePointer?
            var err = [CChar](repeating: 0, count: 256)
            let idCopy = id.unsafeConstUTF8Copy()
            defer { freeConst(idCopy) }
            if gc_dict_load(DictionaryStore.dictionariesDirectory.path, idCopy,
                            &handle, &err, err.count) == 0, let handle {
                handles.append(handle)
            }
        }
        queue.async { [weak self] in
            guard let self else {
                handles.forEach { gc_dict_handle_free($0) }
                return
            }
            if let learning = self.existingLearningSession {
                if learning.applyDicts(ids: ids, handles: handles) == 3 {
                    if let pending = self.pendingLearningApply { self.freeHandles(pending.handles) }
                    self.pendingLearningApply = (ids: ids, handles: handles)
                }
            } else {
                handles.forEach { gc_dict_handle_free($0) }
            }
        }
    }

    private func freeHandles(_ handles: [OpaquePointer?]) {
        for handle in handles where handle != nil {
            gc_dict_handle_free(handle)
        }
    }

    /// 组合结束后的下一个事件前调用（输入侧在非组合状态的事件后触发）：
    /// 冲刷待重试挂载。
    func flushPendingDictApply() {
        queue.async { [weak self] in
            guard let self else { return }
            if let pending = self.pendingNormalApply {
                self.pendingNormalApply = nil
                if let normal = self.normal {
                    if normal.applyDicts(ids: pending.ids, handles: pending.handles) == 3 {
                        self.pendingNormalApply = pending
                    }
                } else {
                    self.freeHandles(pending.handles)
                }
            }
            if let pending = self.pendingLearningApply {
                self.pendingLearningApply = nil
                if let learning = self.existingLearningSession {
                    if learning.applyDicts(ids: pending.ids, handles: pending.handles) == 3 {
                        self.pendingLearningApply = pending
                    }
                } else {
                    self.freeHandles(pending.handles)
                }
            }
        }
    }

    /// 每页数量随排列分流：横排走 setLayout 的 4–9，竖排走附加导出
    /// setVerticalPageSize（默认 9）。设置变更热更新与创建时同口径。
    static func applyPageSizes(to engine: NormalEngine?, settings: Settings) {
        guard let engine else { return }
        if settings.candidateLayout == .horizontal {
            engine.setLayout(horizontalPageSize: Int32(settings.horizontalPageSize))
        } else {
            engine.setLayout(horizontalPageSize: 0)
            engine.setVerticalPageSize(Int32(settings.verticalPageSize))
        }
    }
}
