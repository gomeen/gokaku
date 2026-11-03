import AppKit
import InputMethodKit
import Carbon
import CGogakuCore
import GogakuCore
import GogakuHost

private struct FocusTarget: Equatable {
    let application: String
    let pid: pid_t
    let anchor: NSRange        // 该输入框的锚定选区（首次定位或提交后重锚），组合内粘性
    let selection: NSRange     // 当前选区（复查与展示用；组合中会被字母推动）
    let markedRange: NSRange   // 宿主报告的字母范围（location NSNotFound = 无）
    let rect: NSRect           // 本次读取有效的宿主光标矩形；未读取或无效时为零矩形
    // 宿主自报窗口层级（IMKTextInput.windowLevel，经 GogakuHost 快照带回）。
    // 只用于候选窗排序，不参与目标身份相等判断（见 ==）；未知时 valid=false、值为 0。
    let windowLevel: Int
    let windowLevelValid: Bool
    // IMK 每次返回的 client 代理不是同一实例，uniqueClientIdentifierString 也
    // 实测逐次变化；组合中字母会移动宿主选区，目标身份用「应用／进程＋锚点」
    // 比较，同框判断含字母范围规则（FocusRule，有单元测试）。
    static func == (lhs: FocusTarget, rhs: FocusTarget) -> Bool {
        lhs.application == rhs.application && lhs.pid == rhs.pid && lhs.anchor == rhs.anchor
    }
    var fieldID: String { "\(pid):\(anchor.location):\(anchor.length)" }
}

/// Shift 单击判定：按住期间无其他按键且按时长 <600ms（规格表）。
private struct ShiftClickTracker {
    private var pressTime: TimeInterval = 0
    private var side: Int64 = 0
    private var otherKeySeen = false

    mutating func press(_ event: NSEvent) {
        pressTime = event.timestamp
        side = (event.keyCode == 60) ? 1 : 0   // 60 右 Shift，56 左 Shift
        otherKeySeen = false
    }

    mutating func release(_ event: NSEvent) -> Int64? {
        defer { pressTime = 0 }
        guard pressTime > 0, !otherKeySeen, event.timestamp - pressTime < 0.6 else { return nil }
        return side
    }

    mutating func markOtherKey() { otherKeySeen = true }
    var pressing: Bool { pressTime > 0 }
}

/// 修饰键事件依赖宿主投递；Orca（Chromium 系）会投递但每个过渡双投递
/// （2026-11-02 侧车实测，已由事件通路幂等化修复）。若某宿主完全不投递，
/// 事件通路永远沉默——轮询 CGEventSource 会话级修饰键快照作纯兜底
/// （共享内存读取，无需任何权限）：仅当整个按住窗口＋120ms 宽限内没有任何
/// flagsChanged 事件时才代发，保证与事件通路互斥、永不双发。
private final class ShiftTapPoller {
    private var timer: Timer?
    private var shiftDown = false          // 上次采样的 Shift 状态
    private var pressTime: TimeInterval = 0
    private var otherKeySeen = false       // 按住期间出现过按键（含其他修饰键）
    private var lastFlagsEventAt: TimeInterval = -10
    private var pendingFire: (press: TimeInterval, side: Int64)?
    private var pendingTimer: Timer?

    private let onShiftClick: (Int64) -> Void

    init(onShiftClick: @escaping (Int64) -> Void) { self.onShiftClick = onShiftClick }

    /// 25Hz 采样：兼顾快速单击捕获与开销（flagsState 为共享内存读取）。
    func start() {
        guard timer == nil else { return }
        shiftDown = Self.shiftNow()
        let t = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
        pendingTimer?.invalidate(); pendingTimer = nil
        pendingFire = nil
        shiftDown = false; pressTime = 0
    }

    /// 事件通路每收到一条 flagsChanged 都告知（按下／释放／其他修饰键均算）。
    func noteFlagsEvent() { lastFlagsEventAt = ProcessInfo.processInfo.systemUptime }

    /// 按住期间出现按键（keyDown／其他修饰键事件）→ 取消单击资格。
    func markOtherKey() { if pressTime > 0 { otherKeySeen = true } }

    private static func flagsNow() -> CGEventFlags { CGEventSource.flagsState(.combinedSessionState) }
    private static func shiftNow() -> Bool { flagsNow().contains(.maskShift) }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let flags = Self.flagsNow()
        let shift = flags.contains(.maskShift)
        let other = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).rawValue != 0
        if shift && !shiftDown {
            shiftDown = true; pressTime = now; otherKeySeen = other
        } else if !shift && shiftDown {
            shiftDown = false
            let press = pressTime
            pressTime = 0
            let sawFlagsEvents = lastFlagsEventAt >= press
            // 与事件通路同一规格：<600ms、按住期间无其他按键／修饰键；
            // 延迟 120ms 确认期内事件通路仍无任何 flagsChanged 才代发。
            if !sawFlagsEvents, press > 0, !otherKeySeen, now - press < 0.6 {
                pendingFire = (press, 0)
                let t = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in self?.confirmPendingFire() }
                RunLoop.main.add(t, forMode: .common)
                pendingTimer = t
            }
        } else if other {
            markOtherKey()
        }
    }

    private func confirmPendingFire() {
        pendingTimer = nil
        guard let (press, side) = pendingFire else { return }
        pendingFire = nil
        // 宽限期内事件通路收到了任何 flagsChanged → 本轮由事件通路负责，不代发。
        guard lastFlagsEventAt < press else { return }
        onShiftClick(side)
    }
}

@objc(GogakuInputController)
final class GogakuInputController: IMKInputController, NSMenuItemValidation {
    /// 共享引擎（词库只加载一次）；本控制器只是调用方。
    private let hub = EngineHub.shared
    // 学习会话不再由控制器持有：共享会话在 EngineHub，全部经
    // hub.learningSession（创建）／existingLearningSession（读）访问。
    private var focus: UInt64 = 0
    private var target: FocusTarget?
    private var active = false
    private var engineAvailable = false
    private var pendingEdits = 0
    private var displayed: CompositionView?
    private var markedShown = ""
    private var markedCaret = -1
    #if GOGAKU_VALIDATION
    private var compositionStart: UInt64?
    #endif
    private var committed = Set<UUID>()
    private var settings = Settings.load()
    private var mode: InputMode = .normal
    private var direction: Direction = .zhToEn
    private var application = ""
    private var sourceIndex = 0
    private var requestedSpellStamp: InputStamp?
    private var shiftTracker = ShiftClickTracker()
    /// Orca 等 Chromium 系宿主不转发 flagsChanged 的轮询兜底（验后保留，仅日志可移除）。
    /// 学习模式下的 Shift 单击：切中→英／英→中方向（2026-11 用户裁决），
    /// 不进普通模式的临时英文路径。
    private func handleShiftClickInLearning() {
        guard learningDevEnabled else { NSSound.beep(); return }
        toggleDirection(nil)
    }
    private lazy var shiftPoller = ShiftTapPoller { [weak self] side in
        guard let self, self.active, self.engineAvailable else { return }
        if self.mode == .learning { self.handleShiftClickInLearning(); return }
        if let current = self.currentTarget() {
            _ = self.handleNormalSync(.shiftClick(side: side), at: current, fieldChanged: self.target == nil)
        } else { self.suspend() }
    }
    private var flushWork: DispatchWorkItem?
    /// 当前有效显示位置（宿主光标矩形）；nil＝面板隐藏但组合保留。
    /// 与目标身份锚点分离：位置变化不改变目标身份。
    private var displayRect: NSRect?
    /// 锚点瞬移过滤器（AnchorPlausibility）的连续可疑计数；组合开始/结束、
    /// 换目标、隐藏面板时随 displayRect 一并清零。
    private var anchorSuspectStreak = 0
    /// 组合中的位置复查定时器（100ms；处理滚动／窗口移动；无组合或失焦立即停止）。
    private var positionTimer: Timer?
    // 学习功能门禁（quickmt 开发版裁决，docs/learning-quickmt-dev-decision.md）：
    // 真实宿主安全矩阵仍未验收，但用户已接受开发版风险，由设置开关解锁本机
    // 自用；关闭开关即回门禁态。与 EngineHub.learningSession 同源（同一设置
    // 字段），两处口径一致；正式验收口径与双端交付门槛不变。
    private var learningDevEnabled: Bool { settings.learningTranslationEnabled }

    private lazy var spelling: TranslationService = {
        let service = TranslationService(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/GogakuTranslator"), arguments: ["--spell"])
        service.onResult = { [weak self] result in
            DispatchQueue.main.async {
                guard let self, var view = self.displayed, view.stamp == result.stamp,
                      self.pendingEdits == 0,
                      let current = self.currentTarget(), current == self.target,
                      let rect = self.displayRect else { return }
                view.issues = result.issues ?? []; self.displayed = view
                // 英→中无译文阶段不显示面板（拼写结果入缓存，译文到达后随面板显示）。
                if view.stamp.mode == .learning, view.stamp.direction == .enToZh, view.candidates.isEmpty { return }
                self.panel.render(view, at: rect, targetWindowLevel:
                                  GGPanelTargetLevel(current.windowLevel, current.windowLevelValid))
            }
        }
        return service
    }()

    private var panel: CandidatePanel { CandidatePanel.shared }

    /// 「中／英」Shift 单击提示，0.8 秒自动消失。
    private lazy var toast: ToastWindow = {
        let t = ToastWindow()
        return t
    }()

    private let records = LearningStore()
    /// 学习中→英走普通核心路径时的应用哨兵：绕开按应用默认英文（学习组合
    /// 始终组中文），与真实应用隔离；核心按键语义与普通模式完全一致。
    private static let learningCoreApp = "org.gogaku.learning"
    /// 已知译文（学习中→英）：来自候选预译与历史提交；注释即提交文本。
    private var translationMemory: [String: String] = [:]
    /// 逐候选预译：高亮优先，串行逐个请求（同一服务内不超一个在飞，
    /// 避免 latest-wins 丢请求）。
    private var eagerInFlight: String?
    private var eagerBacklog: [String] = []
    /// 预译专用服务：与提交／英→中请求隔离，避免互相顶掉在飞请求。
    private lazy var eagerTranslator = makeEagerTranslator()
    /// 译文未就绪的提交：缓冲后续按键，避免译文异步上屏与新组合交错。
    private struct PendingTranslatedCommit {
        let source: String
        let anchor: FocusTarget
        var buffer: [NSEvent]
    }
    private var pendingTranslatedCommit: PendingTranslatedCommit?
    /// 英→中无译文阶段的延迟隐藏任务（防逐键闪烁）。
    private var enToZhHideWork: DispatchWorkItem?
    /// 中→英预译的空闲防抖任务（2026-11 用户反馈：连续输入加防抖）。
    private var eagerDebounceWork: DispatchWorkItem?
    /// 学习翻译后端：quickmt 开发版外置 Python 辅助进程（装配路径与 beam 由
    /// 设置解析）；设置变更时销毁重建（rebuildLearningTranslatorIfNeeded）。
    /// 请求按 sourceID 分路：commit＝提交替换（学习模式中→英）、
    /// eager＝高亮候选预译，其余＝英→中组合会话请求。
    private lazy var translator = makeTranslator()

    private func makeTranslator() -> TranslationService {
        let configuration = LearningTranslation.serviceConfiguration(beam: settings.learningBeamSize)
        // 英→中连续输入防抖 300ms（2026-11 用户反馈）：逐键请求改停顿后单发；
        // 提交替换走 requestImmediately 不受影响。
        let service = TranslationService(executable: configuration.executable, arguments: configuration.arguments,
                                         debounceInterval: 0.30)
        service.onResult = { [weak self] result in
            guard let self else { return }
            switch result.sourceID {
            case "commit":
                DispatchQueue.main.async { self.finishCommitSwap(result) }
            case "eager":
                DispatchQueue.main.async { self.applyEagerTranslation(result) }
            default:
                self.hub.async {
                    // quickmt 开发版豁免（2026-11 裁决）：成功且来源确为开发版 worker
                    // 的结果按 approved 进入候选；失败保留输入并提示原文上屏。
                    // 正式口径（approved 仅由审核资源清单决定）不变。
                    if result.error == nil {
                        self.hub.existingLearningSession?.receive(result, approved: result.resource == LearningTranslation.resourceID)
                    } else {
                        self.hub.existingLearningSession?.translationFailed(
                            result, message: Self.learningFailureMessage(result.error ?? ""))
                    }
                    self.publishLearning(generation: result.stamp.focus)
                }
            }
        }
        return service
    }

    /// 预译专用服务：独立实例，避免与提交／英→中请求互相顶掉在飞请求。
    private func makeEagerTranslator() -> TranslationService {
        let configuration = LearningTranslation.serviceConfiguration(beam: settings.learningBeamSize)
        let service = TranslationService(executable: configuration.executable, arguments: configuration.arguments)
        service.onResult = { [weak self] result in
            DispatchQueue.main.async { self?.applyEagerTranslation(result) }
        }
        return service
    }

    /// 译文缓存有界；溢出直接清空（预译很快重建）。
    private func storeTranslationMemory(_ source: String, _ target: String) {
        if translationMemory.count >= 256 { translationMemory.removeAll() }
        translationMemory[source] = target
    }

    /// 中→英连续输入防抖：停顿 0.25s 才泵预译（2026-11 用户反馈）。
    /// 结果链式续泵（applyEagerTranslation defer）不受防抖影响。
    private func scheduleEagerPump() {
        eagerDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pumpEagerBacklog() }
        eagerDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 顺序泵出预译队列：一次只一个在飞请求；结果回来后续泵下一个。
    /// 用 requestImmediately 逐个发，避免同一服务的 latest-wins 丢请求。
    private func pumpEagerBacklog() {
        guard mode == .learning, direction == .zhToEn, eagerInFlight == nil,
              let next = eagerBacklog.first(where: { translationMemory[$0] == nil }) else {
            NSLog("GogakuLearning: eager pump skip mode=%d dir=%d inflight=%d backlog=%d",
                  mode == .learning ? 1 : 0, direction == .zhToEn ? 1 : 0,
                  eagerInFlight != nil ? 1 : 0, eagerBacklog.count)
            return
        }
        eagerInFlight = next
        // 用当前组合 stamp 发起：applyEagerTranslation 以 stamp 匹配面板代次。
        let stamp = displayed?.stamp ?? InputStamp(mode: .learning, direction: .zhToEn)
        NSLog("GogakuLearning: eager fire backlog=%d len=%d", eagerBacklog.count, next.unicodeScalars.count)
        eagerTranslator.requestImmediately(TranslationRequest(stamp: stamp, sourceID: "eager", source: next,
                                                              resource: LearningTranslation.resourceID))
    }

    /// 预译结果：入译文缓存；刷新当前面板注释（注释＝真实提交文本）与
    /// 高亮项状态行预览；续泵下一个。
    private func applyEagerTranslation(_ result: TranslationResult) {
        let finished = eagerInFlight
        eagerInFlight = nil
        let stored = result.error == nil && result.target != nil && !result.target!.isEmpty && result.source == finished
        if stored, let translated = result.target {
            storeTranslationMemory(result.source, translated)
        }
        NSLog("GogakuLearning: eager done stored=%d err=%@ stampMatch=%d mem=%d",
              stored ? 1 : 0, result.error ?? "-",
              displayed?.stamp == result.stamp ? 1 : 0, translationMemory.count)
        defer { pumpEagerBacklog() }
        guard mode == .learning, direction == .zhToEn,
              var view = displayed, view.stamp == result.stamp, pendingEdits == 0,
              let rect = displayRect, let anchor = target else { return }
        // 只刷新高亮候选的注释（2026-11 用户裁决：其余行不显示英文）。
        let inPage = view.selected - view.page * CandidatePage.size
        view.candidates = view.candidates.enumerated().map { offset, candidate in
            let translated = translationMemory[candidate.target]
            if offset == inPage, let translated {
                if candidate.explanation == translated { return candidate }
                return Candidate(id: candidate.id, stamp: candidate.stamp, sourceID: candidate.sourceID,
                                 source: candidate.source, range: candidate.range, target: candidate.target,
                                 explanation: translated, resource: candidate.resource, engineIndex: candidate.engineIndex)
            }
            // 非高亮行不显示英文；残留注释（旧缓存）清空。
            if candidate.explanation.isEmpty { return candidate }
            return Candidate(id: candidate.id, stamp: candidate.stamp, sourceID: candidate.sourceID,
                             source: candidate.source, range: candidate.range, target: candidate.target,
                             explanation: "", resource: candidate.resource, engineIndex: candidate.engineIndex)
        }
        displayed = view
        panel.render(view, at: rect, targetWindowLevel:
                     GGPanelTargetLevel(anchor.windowLevel, anchor.windowLevelValid))
    }

    /// 提交替换（学习模式中→英）：中文提交文本换成 quickmt 译文上屏。
    /// 纯非 CJK 提交（原编码、英文候选）按普通语义原样上屏。
    /// 中→英译文上屏后补一个尾随空格（2026-11 用户裁决：便于继续输入英文）。
    private static func withTrailingSpace(_ text: String) -> String {
        text.hasSuffix(" ") ? text : text + " "
    }

    private func commitLearningSwap(_ text: String, at anchor: FocusTarget, preWriteCheck: FocusTarget?) {
        let hasCJK = text.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
        }
        guard hasCJK else { insertCommit(text, at: anchor, preWriteCheck: preWriteCheck); return }
        if let translated = translationMemory[text] {
            insertCommit(Self.withTrailingSpace(translated), at: anchor, preWriteCheck: preWriteCheck)
            return
        }
        pendingTranslatedCommit = PendingTranslatedCommit(source: text, anchor: anchor, buffer: [])
        translator.requestImmediately(TranslationRequest(stamp: InputStamp(mode: .learning, direction: .zhToEn),
                                                         sourceID: "commit", source: text,
                                                         resource: LearningTranslation.resourceID))
    }

    private func finishCommitSwap(_ result: TranslationResult) {
        guard let pending = pendingTranslatedCommit, pending.source == result.source else { return }
        pendingTranslatedCommit = nil
        let translated = result.error == nil && result.target != nil && !result.target!.isEmpty
        let text = translated ? Self.withTrailingSpace(result.target!) : pending.source
        if translated {
            storeTranslationMemory(pending.source, result.target!)
        } else {
            toast.show("译文失败，已上屏原文", anchor: freshToastAnchor())
        }
        insertLearningCommit(text, at: pending.anchor)
        // 重放缓冲按键（重放前已清 pending，避免再次入队）。
        for event in pending.buffer { _ = handleEvent(event) }
    }

    /// 异步译文上屏：仅核对同应用（缓冲期无新组合，选区仍在提交点）；
    /// 宿主不可写时按草稿保留。
    private func insertLearningCommit(_ text: String, at anchor: FocusTarget) {
        guard let c = client(), let current = currentTarget(),
              current.application == anchor.application, current.pid == anchor.pid else {
            DraftStore.shared.save(application: anchor.application, mode: .learning, direction: .zhToEn, raw: text, literal: true)
            return
        }
        markedShown = ""; markedCaret = -1
        if !gg_insert_text(c, text) {
            DraftStore.shared.save(application: anchor.application, mode: .learning, direction: .zhToEn, raw: text, literal: true)
            return
        }
        target = currentTarget()
    }

    private static func learningFailureMessage(_ error: String) -> String {
        switch error {
        case "model_missing":
            return "quickmt 模型未就绪：请在仓库检出目录运行 " + LearningTranslation.prepareCommand
                + "；输入已保留，可 ⌘Return 明确原文上屏"
        case "timeout":
            return "quickmt 翻译超时；输入已保留，可 ⌘Return 明确原文上屏"
        case "service_unavailable", "service_exited", "service_eof":
            return "quickmt 辅助进程不可用；输入已保留，可 ⌘Return 明确原文上屏"
        default:
            return "quickmt 开发版翻译失败（\(error)）；输入已保留，可 ⌘Return 明确原文上屏"
        }
    }

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        hub.async { [weak self] in
            guard let self else { return }
            _ = self.hub.engine(self.settings)
            DispatchQueue.main.async { self.engineAvailable = true }
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reloadSettings), name: Notification.Name("org.gogaku.settings.changed"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// 设置变更后热更新共享引擎参数（不重建会话，词库不重载）。
    private func applyEngineSettings() {
        let settings = self.settings
        hub.async { [weak self] in
            guard let self else { return }
            guard let normal = self.hub.engine(settings) else { return }
            normal.update(scheme: settings.inputScheme == .fullPinyin ? Int32(GC_SCHEME_FULLPINYIN.rawValue) : Int32(GC_SCHEME_XIAOHE.rawValue),
                          fuzzyMask: settings.fuzzyMask,
                          fullPinyinPreedit: settings.fullPinyinPreedit,
                          freqEnabled: settings.frequencyEnabled)
            normal.setAppDefaults(settings.enabledDefaultEnglishApps)
            normal.setExcludedApps(Array(settings.quickAddExcludedApplications))
            normal.reloadCustomWords()
        }
    }

    override func activateServer(_ sender: Any!) {
        active = true
        shiftPoller.start()
        panel.choose = { [weak self] row in self?.panelChoose(row: row) }
        settings = Settings.load()
        panel.updateTheme(settings.candidateTheme, fontSize: CGFloat(settings.candidateFontSize))
        application = gg_read_host(client())?.application ?? ""
        let preference = settings.applications[application] ?? AppPreference()
        // 开发版开关关闭时忽略历史偏好里的学习标记，普通模式始终可用。
        mode = learningDevEnabled ? preference.mode : .normal
        direction = preference.direction
        configure()
    }

    override func deactivateServer(_ sender: Any!) { shiftPoller.stop(); stopPositionRefresh(); suspend(); active = false }
    override func commitComposition(_ sender: Any!) { suspend() }
    override func inputControllerWillClose() { shiftPoller.stop(); suspend(); active = false }
    override func hidePalettes() { panel.dismiss(); toast.hide() }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue
            | NSEvent.EventTypeMask.leftMouseDown.rawValue | NSEvent.EventTypeMask.rightMouseDown.rawValue)
    }

    /// 读取宿主事实并按锚点规则判定目标。
    /// 浮层宿主（Spotlight／Raycast）：不用「前台应用＝输入目标」限制（浮层激活时
    /// 前台常常还是上一个应用，导致误判）；目标身份来自输入客户端自报的应用，
    /// 配合 IMK 激活／停用生命周期与插字前选区复查防串应用。
    /// 光标矩形三态：notRead（本次未读取）／valid／invalid；未读取不能被当成
    /// 当前有效位置，也不用鼠标位置或虚构屏幕尺寸回退（2026-11-02 二次确认：
    /// 曾试做鼠标/点击位置可信度校验，但 Orca 不转发 mouseDown 且锚点会在
    /// 真实位置与陈旧位置间跳变，无法可靠区分，裁决为完全信任宿主锚点；
    /// Orca 终端 TUI 偶发陈旧锚点属上游缺陷）。
    private enum RectState { case notRead, valid, invalid }

    private func hostFacts(readRectangle: Bool = false) -> (application: String, pid: pid_t, selection: NSRange,
                                                            markedRange: NSRange, rect: NSRect, rectState: RectState,
                                                            windowLevel: Int, windowLevelValid: Bool)? {
        #if GOGAKU_VALIDATION
        let readStart = DispatchTime.now().uptimeNanoseconds
        defer { ValidationMonitor.shared.phase("hostReadNs", duration: DispatchTime.now().uptimeNanoseconds - readStart) }
        #endif
        guard active else { return nil }
        guard !IsSecureEventInputEnabled() else { return nil }
        guard let c = client(), let snapshot = gg_read_host_state(c, readRectangle) else { return nil }
        // pid 仅能从工作区拿：前台应用与客户端自报一致时用真实 pid，否则置 0
        // （浮层宿主）；同框判定仍由应用标识与锚点区分。
        let frontmost = NSWorkspace.shared.frontmostApplication
        let pid = frontmost?.bundleIdentifier == snapshot.application ? frontmost!.processIdentifier : 0
        #if GOGAKU_VALIDATION
        ValidationMonitor.shared.selectionRead(snapshot.selection)
        #endif
        let state: RectState = !snapshot.rectangleRead ? .notRead : (snapshot.rectangleValid ? .valid : .invalid)
        return (snapshot.application, pid, snapshot.selection, snapshot.markedRange, snapshot.rectangle, state,
                Int(snapshot.windowLevel), snapshot.windowLevelValid)
    }

    private func currentTarget(readRectangle: Bool = false, strictComposition: Bool = true) -> FocusTarget? {
        guard let facts = hostFacts(readRectangle: readRectangle) else { return nil }
        let freshRect = facts.rectState == .valid ? facts.rect : .zero
        // 英→中学习组合无宿主侧 marked text，光标漂移不应使组合失效：
        // strictComposition=false 时只取宿主事实（调用方自行校验同应用同进程）。
        if strictComposition, let previous = target, displayed != nil || !markedShown.isEmpty {
            guard FocusRule.isSameField(application: facts.application, pid: facts.pid,
                                        selection: facts.selection, markedRange: facts.markedRange,
                                        composing: true,
                                        anchorApplication: previous.application, anchorPid: previous.pid,
                                        anchor: previous.anchor,
                                        expectsMarkedText: settings.inputLettersEnabled && !markedShown.isEmpty) else {
                return nil
            }
            return FocusTarget(application: facts.application, pid: facts.pid, anchor: previous.anchor,
                               selection: facts.selection, markedRange: facts.markedRange, rect: freshRect,
                               windowLevel: facts.windowLevel, windowLevelValid: facts.windowLevelValid)
        }
        return FocusTarget(application: facts.application, pid: facts.pid, anchor: facts.selection,
                           selection: facts.selection, markedRange: facts.markedRange, rect: freshRect,
                           windowLevel: facts.windowLevel, windowLevelValid: facts.windowLevelValid)
    }

    private func configure() {
        focus &+= 1; target = nil; displayed = nil; pendingEdits = 0
        displayRect = nil; anchorSuspectStreak = 0; stopPositionRefresh()
        markedShown = ""; markedCaret = -1
        panel.updateTheme(settings.candidateTheme, fontSize: CGFloat(settings.candidateFontSize))
        panel.dismiss(); translator.invalidate(); spelling.invalidate(); requestedSpellStamp = nil
        records.policy(recording: settings.recording, excludedApplications: settings.excludedApplications)
        let generation = focus, selectedMode = mode, selectedDirection = direction
        let field = currentFieldID(), app = application
        hub.async { [weak self] in
            guard let self else { return }
            self.hub.existingLearningSession?.configure(focus: generation, mode: selectedMode, direction: selectedDirection)
            // 焦点同步：核心按应用恢复默认英文状态并取消旧组合。
            _ = self.hub.engine(self.settings)?.handle(.focusSync, app: app, field: field, timeMs: Self.nowMs())
        }
    }

    private func currentFieldID() -> String { "\(target?.pid ?? 0):\(focus)" }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }


    /// 失焦／切换：先清空宿主字母再保存内存草稿（规格）；随后立即落盘调频数据，
    /// 缩小删除／学习记录被强杀丢失的窗口。
    /// clearMarked=false：宿主状态无法确认（如组合中宿主自行清空了文本）时，
    /// 对宿主的任何写入（含清除 marked text）都可能崩掉宿主，跳过写入。
    private func suspend(clearMarked: Bool = true, rawOverride: String? = nil) {
        let app = application, oldMode = mode, oldDirection = direction
        let raw = rawOverride ?? displayed?.raw ?? ""
        // 待插入译文未落地即失焦：原中文入草稿可恢复，缓冲丢弃。
        if let pending = pendingTranslatedCommit {
            pendingTranslatedCommit = nil
            DraftStore.shared.save(application: app, mode: .learning, direction: .zhToEn,
                                   raw: pending.source, literal: true)
        }
        eagerBacklog = []
        cancelEnToZhHide()
        // 先隐藏并使迟到渲染失效；宿主字母仅在仍有原字段证据时清除。
        stopPositionRefresh(); displayRect = nil; anchorSuspectStreak = 0
        panel.dismiss(); toast.hide()
        if clearMarked, !markedShown.isEmpty, let old = target, let facts = hostFacts(),
           facts.application == old.application, facts.pid == old.pid,
           facts.markedRange.length > 0, facts.markedRange.location != NSNotFound,
           (old.anchor.location == NSNotFound || facts.markedRange.location == old.anchor.location),
           let c = client() { _ = gg_clear_marked_text(c) }
        focus &+= 1; target = nil; displayed = nil; pendingEdits = 0
        markedShown = ""; markedCaret = -1
        translator.invalidate(); spelling.invalidate(); requestedSpellStamp = nil
        if !raw.isEmpty {
            DraftStore.shared.save(application: app, mode: oldMode, direction: oldDirection, raw: raw)
        }
        let generation = focus
        hub.async { [weak self] in
            guard let self else { return }
            self.hub.existingLearningSession?.configure(focus: generation, mode: oldMode, direction: oldDirection)
            if let normal = self.hub.engine(self.settings) {
                _ = normal.handle(.focusSync, app: app, field: "", timeMs: Self.nowMs())
                normal.flush()
            }
        }
    }

    @objc private func applicationChanged() { if active { suspend() } }

    /// 自身提交偏好触发的 settings.changed 会同步回到本进程（reloadSettings→
    /// suspend→toast.hide），刚显示的切换提示会被立即杀掉；切换后的短窗口内
    /// 忽略自源通知（外部设置变更仍靠后续通知处理）。
    private var suppressSettingsReloadUntil = Date.distantPast

    @objc private func reloadSettings() {
        guard Date() >= suppressSettingsReloadUntil else { return }
        let previous = settings
        suspend()
        settings = Settings.load()
        // 开发版开关关闭即回门禁态：学习组合已随 suspend 结束，模式回普通，
        // 共享学习会话释放（第二份词库内存一并回收）。
        if !settings.learningTranslationEnabled, mode == .learning { mode = .normal }
        rebuildLearningTranslatorIfNeeded(from: previous)
        applyEngineSettings()
        configure()
        if !settings.learningTranslationEnabled {
            hub.async { [weak self] in self?.hub.closeLearningSession() }
        }
    }

    /// 学习后端配置（启用／beam）变更时销毁重建辅助进程：旧进程由 deinit
    /// 终止，进行中的组合按现行失效规则处理（invalidate 丢弃迟到结果）。
    private func rebuildLearningTranslatorIfNeeded(from previous: Settings) {
        guard previous.learningTranslationEnabled != settings.learningTranslationEnabled
            || previous.learningBeamSize != settings.learningBeamSize else { return }
        translator.invalidate()
        translator = makeTranslator()
        eagerTranslator.invalidate()
        eagerTranslator = makeEagerTranslator()
    }

    private func match(_ shortcut: Shortcut, event: NSEvent) -> Bool {
        guard !shortcut.disabled, let combo = KeyCombo.from(event: event) else { return false }
        return combo.keyID == shortcut.key && combo.modifiers == shortcut.modifiers
    }

    /// 普通模式事件映射（按键 → NormalEvent）。
    private func normalEvent(for event: NSEvent) -> NormalEvent? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.control) {
            switch event.keyCode {
            case 51: return .deleteWord            // Control＋Backspace 删个人学习词
            case 36: return .enter                 // Ctrl+Enter 同 Enter（上屏原编码）
            default: break
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": return .ctrlA
            case "b": return .ctrlB
            case "e": return .ctrlE
            case "f": return .ctrlF
            case "n": return .ctrlN
            case "p": return .ctrlP
            default: return nil
            }
        }
        if flags.contains(.option) || flags.contains(.command) { return nil }  // 修饰组合交还宿主
        switch event.keyCode {
        case 36: return .enter
        case 49: return .space
        case 51: return .backspace
        case 53: return .esc
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: break
        }
        if let chars = event.characters, !chars.isEmpty,
           !chars.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .text(chars)
        }
        return nil
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { panel.dismiss(); return false }
        #if GOGAKU_VALIDATION
        let metricID = ValidationMonitor.shared.begin(type: UInt(event.type.rawValue), timestamp: event.timestamp, keyCode: Int(event.keyCode))
        #endif
        let consumed = handleEvent(event)
        #if GOGAKU_VALIDATION
        ValidationMonitor.shared.end(metricID, consumed: consumed)
        #endif
        return consumed
    }

    private func handleEvent(_ event: NSEvent) -> Bool {
        guard engineAvailable else {
            panel.dismiss()
            return false
        }
        // keyUp 不是新输入：一律透传（单字符原文提交竞态的历史修复）。
        if event.type == .keyUp { return false }
        if event.type == .flagsChanged {
            shiftPoller.noteFlagsEvent()   // 轮询兑底互斥：本轮窗口内有事件就不代发
            // Shift 单击判定；其他修饰键变化不挂起组合（规格）。
            // Hyper（fn／globe 修饰）不算 Shift 单击：fn 按住时 flags 含 .function，
            // 与 Command／Control／Option 一样取消单击资格；长按（≥600ms）与
            // 按住期间的其他按键已在 ShiftClickTracker 排除。
            // Orca（Chromium 系）每个修饰键过渡双投递 flagsChanged（2026-11-02
            // 侧车实测：同一边沿 2ms 内两条 raw 相同的事件）——重复的 Shift 按下
            // 必须幂等，不得清除单击资格（此前正是它把每次 Orca Shift 单击判死）。
            let flags = event.modifierFlags.intersection([.shift])
            let hasShift = flags.rawValue != 0
            let onlyShift = hasShift &&
                event.modifierFlags.intersection([.command, .control, .option, .function]).rawValue == 0
            if !hasShift {
                // 释放沿（Shift 已松开；raw 里可能仍带其他修饰键）。
                if shiftTracker.pressing {
                    if let side = shiftTracker.release(event) {
                        if mode == .learning {
                            handleShiftClickInLearning()
                        } else if let current = currentTarget() {
                            _ = handleNormalSync(.shiftClick(side: side), at: current, fieldChanged: target == nil)
                        } else { suspend() }
                    } else {
                        shiftTracker.markOtherKey(); shiftPoller.markOtherKey()
                    }
                } else if event.modifierFlags.intersection([.command, .control, .option, .function]).rawValue != 0 {
                    // 无按下上下文的纯修饰键变化（如 Ctrl 单独按下）。
                    shiftPoller.markOtherKey()
                }
            } else if onlyShift {
                // Shift 按下沿（重复投递幂等：已按下时保持单击资格不变）。
                if !shiftTracker.pressing { shiftTracker.press(event) }
            } else {
                // Shift＋其他修饰键：取消单击资格。
                shiftTracker.markOtherKey(); shiftPoller.markOtherKey()
            }
            return false   // 修饰键事件本身交还宿主
        }
        if event.type != .keyDown {
            suspend(); return false
        }
        if shiftTracker.pressing { shiftTracker.markOtherKey() }
        shiftPoller.markOtherKey()
        if match(settings.modeShortcut, event: event) { toggleMode(nil); return true }
        if match(settings.directionShortcut, event: event) { toggleDirection(nil); return true }
        if match(settings.quickAddShortcut, event: event) && mode == .normal, let current = currentTarget() {
            return handleNormalSync(.quickAdd, at: current, fieldChanged: false)
        }
        guard let current = currentTarget(readRectangle: displayed == nil && markedShown.isEmpty) else { suspend(); return false }
        let fieldChanged = target == nil || target?.application != current.application || target?.pid != current.pid
        target = current; application = current.application
        // 学习模式中→英与普通模式同一条核心路径（同键位、同候选、同上屏规则），
        // 仅提交时换译译文；英→中保留独立英语缓冲路径。
        if mode == .normal || (mode == .learning && direction == .zhToEn) {
            // 消费键期间的待插入译文：缓冲而非直通，防止译文与新组合交错。
            if event.type == .keyDown, pendingTranslatedCommit != nil {
                pendingTranslatedCommit?.buffer.append(event)
                return true
            }
            return handleNormalSync(event, at: current, fieldChanged: fieldChanged)
        }
        return handleLearning(event)
    }

    // MARK: - 普通模式（共享 C++ 核心）

    /// 同步路径：普通模式按键在共享引擎队列执行，按 consumed 决定 IMK 是否吞键。
    /// 状态由进程级串行队列保持有序；多控制器（多应用）共用同一队列与同一会话。
    private func handleNormalSync(_ event: NSEvent, at target: FocusTarget, fieldChanged: Bool) -> Bool {
        guard let normalEvent = normalEvent(for: event) else {
            // Command／Option 组合按宿主快捷键规则交还宿主（规格：普通模式
            // Command＋Enter 是宿主快捷键，不是原文上屏；仅未映射普通键在
            // 组合中先上屏原编码再交还宿主）。
            if event.modifierFlags.intersection([.command, .option]).rawValue != 0 {
                panel.dismiss()
                return false
            }
            // 未映射按键（Tab、F1…）：组合中先上屏原编码再交还宿主。
            if displayed != nil {
                _ = handleNormalSync(.enter, at: target, fieldChanged: false)
                refreshAfterEngine(at: target)
            }
            panel.dismiss()
            return false
        }
        return handleNormalSync(normalEvent, at: target, fieldChanged: fieldChanged)
    }

    private func handleNormalSync(_ normalEvent: NormalEvent, at target: FocusTarget, fieldChanged: Bool) -> Bool {
        self.target = target
        application = target.application
        let settings = self.settings
        // 学习模式中→英用应用哨兵：核心始终组中文，绕开按应用默认英文。
        let learningSwap = mode == .learning && direction == .zhToEn
        let app = learningSwap ? Self.learningCoreApp : target.application
        let field = currentFieldID(), time = Self.nowMs()
        #if GOGAKU_VALIDATION
        let coreStart = DispatchTime.now().uptimeNanoseconds
        let enqueueNs = coreStart
        var coreWaitNs: UInt64 = 0
        #endif
        let snapshot: NormalSnapshot? = hub.sync {
            #if GOGAKU_VALIDATION
            let innerStart = DispatchTime.now().uptimeNanoseconds
            coreWaitNs = innerStart > enqueueNs ? innerStart - enqueueNs : 0
            ValidationMonitor.shared.phase("queueWaitNs", duration: coreWaitNs)
            defer { ValidationMonitor.shared.phase("coreExecNs", duration: DispatchTime.now().uptimeNanoseconds - innerStart) }
            #endif
            guard let engine = self.hub.engine(settings) else { return nil }
            // 复查 B2：共享会话可能被其他控制器的 focusSync 切走；本控制器
            // 未察觉字段变化（如 Shift 单击、面板点击）时以 hub 记录为准补发。
            let stale = EngineHub.shared.lastAppField != (app, field)
            var isFocusSync = false
            if case .focusSync = normalEvent { isFocusSync = true }
            let needSync = fieldChanged || (stale && !isFocusSync)
            EngineHub.shared.lastAppField = (app, field)
            if needSync { _ = engine.handle(.focusSync, app: app, field: field, timeMs: time) }
            return engine.handle(normalEvent, app: app, field: field, timeMs: time)
        }
        #if GOGAKU_VALIDATION
        ValidationMonitor.shared.core(DispatchTime.now().uptimeNanoseconds - coreStart)
        #endif
        guard let snap = snapshot else { suspend(); return false }
        applyNormal(snap, target: target)
        if !snap.consumed {
            if snap.composing { suspend() } else { panel.dismiss() }
        }
        return snap.consumed
    }

    /// 把核心快照落到宿主（提交／字母）与面板。
    private func applyNormal(_ snap: NormalSnapshot, target: FocusTarget) {
        let learningSwap = mode == .learning && direction == .zhToEn
        guard active, let current = currentTarget(),
              current.application == target.application, current.pid == target.pid else {
            if !snap.commit.isEmpty {
                DraftStore.shared.save(application: target.application, mode: .normal, direction: direction,
                                       raw: snap.commit, literal: true)
            }
            suspend(clearMarked: false, rawOverride: snap.rawInput)
            return
        }
        if snap.beep { NSSound.beep() }
        if snap.toast != 0 { toast.show(snap.toast == 1 ? "中" : "英", anchor: freshToastAnchor()) }
        // 无组合的瞬态说明（如快速添加结果）用提示浮层；组合中状态走面板状态行。
        if !snap.composing && !snap.status.isEmpty { toast.show(snap.status, anchor: freshToastAnchor()) }
        if snap.candidates.contains(where: { $0.kind == GC_CAND_LEARNED }) {
            scheduleFlush()
        }
        if !snap.composing { panel.dismiss() }
        if !snap.commit.isEmpty {
            if learningSwap {
                commitLearningSwap(snap.commit, at: target, preWriteCheck: current)
            } else {
                insertCommit(snap.commit, at: target, preWriteCheck: current)
            }
        }
        let caret = PreeditCaret.utf16Offset(in: snap.preedit, utf8Offset: snap.preeditCaret)
        updateMarked(snap.marked, caret: caret, at: target)
        var view = CompositionView(stamp: InputStamp(mode: .normal, direction: .zhToEn))
        view.raw = snap.rawInput
        view.preedit = snap.preedit
        // 分色与光标分别取核心报告，UTF-8 字节偏移不能直接用作 AppKit 选区。
        view.typedPrefix = String(String.UnicodeScalarView(snap.preedit.unicodeScalars.prefix(snap.typedPrefixLen)))
        view.preeditCaretUTF16 = caret
        view.totalCandidates = snap.total
        view.page = snap.page
        view.selected = snap.selected
        view.candidates = snap.candidates.map { item in
            let isHighlighted = item.text == highlightedCandidateText(snap)
            return Candidate(stamp: view.stamp,
                      sourceID: "normal:\(item.kind)",
                      source: item.text,
                      range: RawRange(start: 0, length: 0),
                      target: item.text,
                      // 学习中→英：仅高亮候选显示真实提交文本（quickmt 译文，
                      // 2026-11 用户裁决：其余不显示）；历史缓存不外溢。
                      explanation: learningSwap
                          ? (isHighlighted ? (translationMemory[item.text] ?? "") : "")
                          : (settings.glossEnabled ? item.gloss : ""),
                      resource: "gogaku-core")
        }
        view.status = snap.status
        if snap.composing {
            // 学习中→英：只预译高亮候选（2026-11 用户裁决：仅第一个显示英文）。
            if learningSwap {
                let inPage = snap.selected - snap.page * CandidatePage.size
                if snap.candidates.indices.contains(inPage) {
                    let highlight = snap.candidates[inPage].text
                    eagerBacklog = translationMemory[highlight] == nil ? [highlight] : []
                    // 高亮候选已有缓存时注释即时就绪（缓存合并进候选人选，无需等预译）。
                }
            }
            // 显示位置用当前有效插入点：组合刚开始且本次读取到有效矩形时采用；
            // 否则等待 marked 更新后的合并刷新。无有效坐标时隐藏面板但保留组合
            //（不丢弃文字；恢复有效且字段一致后重新显示）。
            if displayRect == nil, target.rect != .zero { displayRect = target.rect }
            startPositionRefresh()
            #if GOGAKU_VALIDATION
            if displayed == nil { compositionStart = ValidationMonitor.shared.startTime(ValidationMonitor.shared.currentEvent) }
            let metricID = ValidationMonitor.shared.currentEvent, start = compositionStart
            let firstDisplay = !panel.contentVisible
            displayed = view
            if let rect = displayRect {
                panel.enqueue(view, at: rect, targetWindowLevel:
                              GGPanelTargetLevel(target.windowLevel, target.windowLevelValid)) {
                    ValidationMonitor.shared.rendered(metricID, compositionStart: start, first: firstDisplay)
                }
            } else {
                panel.dismiss()
                ValidationMonitor.shared.rendered(metricID, compositionStart: start, first: false)
            }
            #else
            displayed = view
            if let rect = displayRect {
                panel.enqueue(view, at: rect, targetWindowLevel:
                              GGPanelTargetLevel(target.windowLevel, target.windowLevelValid))
            } else {
                panel.dismiss()
            }
            #endif
            // marked text 更新后读取最新插入位置（合并刷新：同一事件内只读一次；
            // 额外宿主读取经 ValidationMonitor 的 hostReadNs 纳入性能测量）。
            refreshDisplayPosition()
            // displayed 已更新为当前视图后按防抖泵预译队列（stamp 匹配面板代次）。
            scheduleEagerPump()
        } else {
            displayed = nil
            displayRect = nil
            anchorSuspectStreak = 0
            stopPositionRefresh()
            panel.dismiss()
            eagerBacklog = []
            eagerDebounceWork?.cancel()
        }
    }

    // MARK: - 显示位置复查

    /// 组合存在时以 100ms 间隔复查宿主光标位置（滚动／窗口移动）。
    /// 同一坐标不重复布局；旧代次刷新由面板 generation 检查拒绝，不会使已
    /// 关闭面板复活。额外宿主读取在 hostFacts 中计入 hostReadNs。
    private func startPositionRefresh() {
        guard positionTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshDisplayPosition()
        }
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
    }

    private func stopPositionRefresh() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    /// 隐藏面板但保留组合与字母；坐标恢复有效且字段一致后由复查重新显示。
    private func hidePanelKeepComposition() {
        displayRect = nil
        anchorSuspectStreak = 0
        panel.dismiss()
    }

    /// 读取最新插入位置并更新面板位置；仅在显示层面生效，不改目标身份。
    private func refreshDisplayPosition() {
        guard active, displayed != nil, target != nil else { stopPositionRefresh(); return }
        guard let current = currentTarget(readRectangle: true), let anchor = target,
              current.application == anchor.application, current.pid == anchor.pid else {
            hidePanelKeepComposition()
            return
        }
        if current.rect == .zero {
            // Orca 1.4.246 实测（2026-11-02 诊断）：组合（marked range）覆盖插入点
            // 期间，宿主对插入点与组合起点的 attributes 查询都返回零矩形，组合结束
            // 才恢复有效。已有有效锚点时冻结在组合内最后测得的位置（不追逐、不
            // 隐藏，矩形恢复后重新跟随）；从未获得过锚点（含陈旧锚点被拒）才走
            // hidePanelKeepComposition 的隐藏保留组合路径。
            return
        }
        // 瞬移过滤器（2026-11-03 用户报告 Orca 打字中面板无规律跳到无关位置）：
        // 布局抖动／选择闪断时 Orca 会短暂回报非零但错误的矩形（控件原点、
        // 缓冲区首行），零矩形冻结拦不住。同一组合内新锚点若离上次有效锚点
        // 超过 teleportLimit 则先冻结在原位；连续 escapeAfter 拍仍报远处新
        // 位置才接受（窗口真实拖动／滚动的逃生门）。组合开始时 displayRect
        // 为空，第一拍直接采纳。
        let decision = AnchorPlausibility.classify(previous: displayRect,
                                                   next: current.rect,
                                                   suspectStreak: anchorSuspectStreak)
        switch decision {
        case .accept, .escapeAccept:
            anchorSuspectStreak = 0
        case .freeze:
            anchorSuspectStreak += 1
            return
        }
        let changed = displayRect != current.rect
        displayRect = current.rect
        if changed, let view = displayed {
            // 英→中无译文阶段只跟踪位置不显示面板（译文到达后由 publish 显示）。
            if view.stamp.mode == .learning, view.stamp.direction == .enToZh, view.candidates.isEmpty {
                return
            }
            panel.enqueue(view, at: current.rect, targetWindowLevel:
                          GGPanelTargetLevel(current.windowLevel, current.windowLevelValid))
        }
    }


    private func refreshAfterEngine(at target: FocusTarget) {
        // 未映射键上屏原编码后清理面板与字母（无快照可用）。
        displayed = nil
        panel.dismiss()
        if let c = client(), !markedShown.isEmpty { _ = gg_clear_marked_text(c) }
        markedShown = ""
    }

    private func updateMarked(_ marked: String, caret: Int, at target: FocusTarget) {
        guard settings.inputLettersEnabled else {
            if !markedShown.isEmpty, let c = client() { _ = gg_clear_marked_text(c) }
            markedShown = ""; markedCaret = -1
            return
        }
        guard marked != markedShown || (!marked.isEmpty && caret != markedCaret) else { return }
        guard let c = client() else { return }
        let needsReanchor = markedShown.isEmpty && !marked.isEmpty
        #if GOGAKU_VALIDATION
        let markedStart = DispatchTime.now().uptimeNanoseconds
        #endif
        let ok = marked.isEmpty ? gg_clear_marked_text(c) : gg_update_marked_text(c, marked, UInt(max(caret, 0)))
        #if GOGAKU_VALIDATION
        ValidationMonitor.shared.phase("markedWriteNs", duration: DispatchTime.now().uptimeNanoseconds - markedStart)
        #endif
        if ok {
            markedShown = marked; markedCaret = marked.isEmpty ? -1 : caret
            // 提交后首次读到的选区可能仍是旧值。以刚写入的宿主字母位置
            // 重锚，避免第二个字母因旧锚点而被误判为换框。
            #if GOGAKU_VALIDATION
            let anchorStart = DispatchTime.now().uptimeNanoseconds
            defer { ValidationMonitor.shared.phase("anchorReadNs", duration: DispatchTime.now().uptimeNanoseconds - anchorStart) }
            #endif
            if needsReanchor, let state = gg_read_host_state(c, false),
               state.application == target.application,
               state.markedRange.location != NSNotFound, state.markedRange.length == marked.utf16.count {
                self.target = FocusTarget(application: target.application, pid: target.pid,
                                          anchor: NSRange(location: state.markedRange.location, length: 0),
                                          selection: state.selection, markedRange: state.markedRange, rect: target.rect,
                                          windowLevel: target.windowLevel, windowLevelValid: target.windowLevelValid)
            }
        }
    }

    /// 提交上屏；下一组合按当前选区定位，字母写入后用实际 marked 位置重锚。
    private func insertCommit(_ text: String, at anchor: FocusTarget,
                              preWriteCheck: FocusTarget? = nil) {
        // 同一写入阶段的焦点核对合并：applyNormal 在 insertCommit 前刚读过宿主事实
        //（两者之间只有面板隐藏等本地操作，没有状态变化），复用该快照，避免同一
        // 事件内第三次跨进程读取；调用方未提供时（其他路径）仍自行读取。
        guard let current = preWriteCheck ?? currentTarget(),
              current.application == anchor.application, current.pid == anchor.pid else {
            DraftStore.shared.save(application: anchor.application, mode: .normal, direction: direction, raw: text, literal: true)
            return
        }
        guard let c = client() else {
            DraftStore.shared.save(application: anchor.application, mode: .normal, direction: direction, raw: text, literal: true)
            return
        }
        // 不先显式清除 marked：insertText(NSNotFound) 自动替换 marked 区间，
        // 一次 IMK 调用完成提交；额外的 setMarkedText(empty) 会 destabilize
        // 客户端会话（实测提交后 1–3 个按键绕过输入法直达宿主）。
        #if GOGAKU_VALIDATION
        let commitStart = DispatchTime.now().uptimeNanoseconds
        defer { ValidationMonitor.shared.commit(DispatchTime.now().uptimeNanoseconds - commitStart) }
        #endif
        markedShown = ""; markedCaret = -1
        if !gg_insert_text(c, text) {
            // IMK insertText 无成功回执；结果不明不自动重试，也不能重锚。
            DraftStore.shared.save(application: anchor.application, mode: .normal, direction: direction, raw: text, literal: true)
            return
        }
    }

    private func scheduleFlush() {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hub.async { self.hub.engine(self.settings)?.flush() }
        }
        flushWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: work)
    }

    // MARK: - 面板点击与学习模式（保持既有路径）

    private func panelChoose(row: Int) {
        // 学习中→英与普通模式同一套点击选词；英→中走学习候选直选。
        guard mode == .normal || (mode == .learning && direction == .zhToEn),
              let snapDisplayed = displayed, pendingEdits == 0 else {
            panelChooseLearning(row: row)
            return
        }
        let index = snapDisplayed.selected - (snapDisplayed.selected % CandidatePage.size) + row
        guard index < snapDisplayed.totalCandidates else { return }
        // 核心按「当前页内序号」选择：数字键路径与点击共用页内序号。
        let pageStart = snapDisplayed.page * CandidatePage.size
        let inPage = index - pageStart
        guard inPage >= 0, inPage < CandidatePage.size, let target = target else { return }
        _ = handleNormalSync(.text(String(inPage + 1)), at: target, fieldChanged: false)
    }

    private func panelChooseLearning(row: Int) {
        guard let view = displayed, hub.existingLearningSession != nil else { return }
        let pageStart = view.page * CandidatePage.size
        let index = pageStart + row
        if view.candidates.indices.contains(index) { choose(view.candidates[index]) }
    }

    /// 英→中专用按键（学习中→英走普通核心路径）。快捷键与普通模式一致
    /// （2026-11 用户裁决）：数字 1–9 直接选编号候选，不再用 ⌥数字；
    /// 空格保留为英文空格输入（英语短句需要），Enter/数字选中文译文。
    /// 英→中按键（学习中→英走普通核心路径）。返回是否消费。
    /// 无输入时不拦截任何按键（2026-11 用户裁决）：仅 a–z 开始英→中缓冲，
    /// 其余（空格、数字、标点、修饰组合、方向键…）全部透传宿主。
    /// 有输入后：数字 1–9 选词、Enter 选中文译文、空格保留英文空格、
    /// ⌘↩ 原文上屏、Esc 取消——与普通模式的偏差仅为输入内容含空格。
    private func handleLearning(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let composing = !(displayed?.raw.isEmpty ?? true)
        if !composing {
            if flags.intersection([.command, .control, .option]).rawValue != 0 { return false }
            guard let text = event.characters, !text.isEmpty,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  text.unicodeScalars.allSatisfy({ (97...122).contains($0.value) }) else { return false }
        } else {
            if flags.contains(.command) {
                if event.keyCode == 36, let view = displayed, !view.raw.isEmpty {
                    commitLearningOriginal()
                }
                return true
            }
            if flags.contains(.control) { return true }
        }
        if composing, let delta = pageDelta(for: event), let view = displayed, !view.raw.isEmpty {
            edit { try $0.page(delta) }
            return true
        }
        let text = event.characters ?? ""
        switch event.keyCode {
        case 53 where composing: cancelLearning(); return true
        case 51 where composing: edit { try $0.backspace() }; return true
        case 116 where composing: edit { try $0.page(-1) }; return true
        case 121 where composing: edit { try $0.page(1) }; return true
        case 125, 124 where composing: edit { $0.navigate(1) }; return true
        case 126, 123 where composing: edit { $0.navigate(-1) }; return true
        case 36 where composing: chooseCurrent(); return true
        default: break
        }
        // 数字 1–9 直接选编号候选；无对应候选并入源文（普通模式超页数字的简化）。
        if let n = Int(event.charactersIgnoringModifiers ?? text), (1...CandidatePage.size).contains(n), flags.isEmpty {
            if let view = displayed, pendingEdits == 0 {
                let index = view.page * CandidatePage.size + n - 1
                if view.candidates.indices.contains(index) { choose(view.candidates[index]); return true }
            }
            edit { try $0.type(text) }
            return true
        }
        if flags.contains(.option) { return true }
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return true }
        edit { try $0.type(text) }
        return true
    }

    private func pageDelta(for event: NSEvent) -> Int? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 116: return -1
        case 121: return 1
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case ",": return -1
        case ".": return 1
        default: return nil
        }
    }

    private func edit(_ body: @escaping (CompositionSession) throws -> Void) {
        let generation = focus
        pendingEdits += 1; displayed = nil
        hub.async { [weak self] in
            guard let self else { return }
            guard let session = self.hub.learningSession(self.settings) else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingEdits = 0; self.suspend()
                }
                return
            }
            // 共享会话按需同步代次／模式／方向（首次创建与切向后的安全网；
            // 已在组合中的会话不被重置）。
            let stamp = session.view.stamp
            if stamp.focus != generation || stamp.mode != self.mode || stamp.direction != self.direction {
                session.configure(focus: generation, mode: self.mode, direction: self.direction)
            }
            // quickmt 开发版翻译请求（2026-11 裁决）：sourceID／source 来自
            // publishLearning 的 source 表；resource 标记开发版豁免。
            session.translationNeeded = { [weak self] stamp, source in
                self?.translator.request(TranslationRequest(stamp: stamp, sourceID: source.id,
                                                            source: source.text,
                                                            resource: LearningTranslation.resourceID))
            }
            do { try body(session) } catch { session.viewError() }
            self.publishLearning(generation: generation, completesEdit: true)
        }
    }

    /// 英→中无译文时的延迟隐藏：防逐键显示/隐藏闪烁（2026-11 用户反馈）。
    /// 宽限期内译文到达（candidates 非空）即取消隐藏原地刷新。
    private func scheduleEnToZhHide() {
        enToZhHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .learning, self.direction == .enToZh,
                  self.displayed?.candidates.isEmpty != false else { return }
            self.panel.dismiss()
        }
        enToZhHideWork = work
        // 宽限 0.7s：须覆盖防抖 0.3s＋首译时延，否则宽限先到会复现闪烁
        //（2026-11-03 与防抖同轮调整）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
    private func cancelEnToZhHide() {
        enToZhHideWork?.cancel()
        enToZhHideWork = nil
    }

    private func publishLearning(generation: UInt64, completesEdit: Bool = false) {
        guard let value = hub.existingLearningSession?.view else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focus == generation else { return }
            if completesEdit { self.pendingEdits = max(0, self.pendingEdits - 1) }
            guard self.pendingEdits == 0 else { return }
            self.displayed = value
            if value.raw.isEmpty {
                self.panel.dismiss(); self.target = nil; return
            }
            // 英→中无宿主侧组合：只校验同应用同进程（与 applyNormal 口径一致），
            // 光标漂移跟随新插入点；组合起点全等会误杀组合（每键入一次即 suspend）。
            guard let current = self.currentTarget(strictComposition: false) else { self.suspend(); return }
            guard let previous = self.target else { self.suspend(); return }
            if current.application != previous.application || current.pid != previous.pid {
                // 诊断：无原文内容，仅失败原因与选区形状，供真机回归定位。
                NSLog("GogakuLearning: publish lost field app=%d pid=%d sel=%ld:%ld anchor=%ld:%ld",
                      current.application == previous.application ? 1 : 0,
                      current.pid == previous.pid ? 1 : 0,
                      current.selection.location, current.selection.length,
                      previous.anchor.location, previous.anchor.length)
                self.suspend(); return
            }
            self.target = current
            // 学习路径没有 applyNormal：首次显示用锚点矩形（组合首键
            // currentTarget(readRectangle: true) 已读取）；若首键未读到矩形，
            // 由位置复查在恢复后补上。后续由位置复查跟随插入点。
            if self.displayRect == nil, let anchor = self.target, anchor.rect != .zero {
                self.displayRect = anchor.rect
            }
            // 拼写检查仅英→中且开发版开关打开时走现有 --spell 通路。
            if self.learningDevEnabled, self.mode == .learning, self.direction == .enToZh, self.requestedSpellStamp != value.stamp {
                self.requestedSpellStamp = value.stamp
                self.spelling.request(TranslationRequest(stamp: value.stamp, sourceID: "spelling", source: value.raw,
                                                         resource: "NSSpellChecker:en_US", ignoredWords: Array(self.settings.ignoredWords)))
            }
            self.displayed = value
            startPositionRefresh()
            // 英→中无译文结果不立即隐藏（宽限 0.4s 防逐键闪烁，2026-11 用户裁决）；
            // 期间译文到达即原地刷新；停下且确实无译文才隐藏。
            if self.mode == .learning, self.direction == .enToZh, value.candidates.isEmpty {
                self.scheduleEnToZhHide()
                return
            }
            self.cancelEnToZhHide()
            guard let rect = self.displayRect else { self.panel.dismiss(); return }
            self.panel.render(value, at: rect, targetWindowLevel:
                              GGPanelTargetLevel(current.windowLevel, current.windowLevelValid))
        }
    }

    private func chooseCurrent() {
        guard pendingEdits == 0, let view = displayed, view.candidates.indices.contains(view.selected) else { NSSound.beep(); return }
        choose(view.candidates[view.selected])
    }

    private func choose(_ candidate: Candidate) {
        // 英→中无宿主侧组合：同应用同进程即可（与 publishLearning 口径一致）。
        guard pendingEdits == 0, displayed?.stamp == candidate.stamp, let anchor = target,
              let current = currentTarget(strictComposition: false),
              current.application == anchor.application, current.pid == anchor.pid else { suspend(); return }
        target = current
        let generation = focus
        pendingEdits += 1; displayed = nil
        hub.async { [weak self] in
            guard let self else { return }
            guard let session = self.hub.learningSession(self.settings) else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingEdits = max(0, self.pendingEdits - 1)
                    self.suspend()
                }
                return
            }
            let intent = try? session.choose(candidate)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let intent { self.insertLearning(intent, anchor: anchor, generation: generation) }
            }
            self.publishLearning(generation: generation, completesEdit: true)
        }
    }

    private func commitLearningOriginal() {
        guard let view = displayed, !view.raw.isEmpty, let anchor = target,
              let current = currentTarget(strictComposition: false),
              current.application == anchor.application, current.pid == anchor.pid, let c = client() else { return }
        let raw = view.raw, selectedMode = mode, selectedDirection = direction
        cancelLearning()
        func saveDraft() {
            DraftStore.shared.save(application: anchor.application, mode: selectedMode, direction: selectedDirection, raw: raw)
        }
        if raw.utf16.count == 1 {
            guard gg_mark_confirmed_text(c, raw), let markedTarget = currentTarget(strictComposition: false) else { saveDraft(); return }
            target = markedTarget
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.pendingEdits == 0, let nowTarget = self.currentTarget(strictComposition: false),
                      nowTarget.application == markedTarget.application, nowTarget.pid == markedTarget.pid else {
                    saveDraft(); return
                }
                if !gg_insert_text(c, raw) { saveDraft() }
                self.target = self.currentTarget()
            }
        } else {
            if !gg_insert_text(c, raw) { saveDraft() }
            target = currentTarget()
        }
    }

    private func insertLearning(_ intent: CommitIntent, anchor: FocusTarget, generation: UInt64) {
        guard !committed.contains(intent.id) else { return }
        committed.insert(intent.id)
        guard generation == focus, let current = currentTarget(strictComposition: false),
              current.application == anchor.application, current.pid == anchor.pid, let c = client() else {
            DraftStore.shared.save(application: anchor.application, mode: intent.stamp.mode, direction: intent.stamp.direction, raw: intent.recoveryRaw)
            suspend(); return
        }
        if !gg_insert_text(c, intent.text) {
            DraftStore.shared.save(application: anchor.application, mode: intent.stamp.mode, direction: intent.stamp.direction, raw: intent.recoveryRaw)
        }
        target = currentTarget()
    }

    private func cancelLearning() {
        focus &+= 1; let generation = focus
        pendingEdits = 0; displayed = nil
        cancelEnToZhHide()
        panel.dismiss(); translator.invalidate(); spelling.invalidate(); requestedSpellStamp = nil
        let m = mode, d = direction
        hub.async { [weak self] in self?.hub.existingLearningSession?.configure(focus: generation, mode: m, direction: d) }
    }

    private func persistPreference() {
        var p = AppPreference(); p.mode = mode; p.direction = direction
        settings.applications[application] = p
        // 磁盘操作不放入按键回调：串行协调器合并最新改动，失败保留待保存。
        SettingsStore.shared.submit(settings)
    }

    /// 当前高亮候选文本（页内索引换算；越界返回 nil）。
    private func highlightedCandidateText(_ snap: NormalSnapshot) -> String? {
        let inPage = snap.selected - snap.page * CandidatePage.size
        return snap.candidates.indices.contains(inPage) ? snap.candidates[inPage].text : nil
    }

    /// 切换提示的输入位置锚点：显示矩形／目标矩形，否则实时读宿主光标矩形（组合外也可用）。
    private func freshToastAnchor() -> NSRect? {
        if let rect = displayRect, rect != .zero { return rect }
        if let current = currentTarget(readRectangle: true, strictComposition: false), current.rect != .zero {
            return current.rect
        }
        if let rect = target?.rect, rect != .zero { return rect }
        return nil
    }

    @objc private func toggleMode(_ sender: Any?) {
        // quickmt 开发版裁决：开关打开时学习模式可切换；关闭保持门禁态（蜂鸣）。
        guard learningDevEnabled else { NSSound.beep(); return }
        let anchor = freshToastAnchor()   // 在 suspend 清理前读当前插入点
        suppressSettingsReloadUntil = Date().addingTimeInterval(0.5)
        suspend()
        mode = mode == .normal ? .learning : .normal
        persistPreference()
        toast.show(mode == .learning ? "学习" : "普通", anchor: anchor)
        configure()
    }

    @objc private func toggleDirection(_ sender: Any?) {
        guard learningDevEnabled else { NSSound.beep(); return }
        let anchor = freshToastAnchor()
        suppressSettingsReloadUntil = Date().addingTimeInterval(0.5)
        suspend()
        direction = direction == .zhToEn ? .enToZh : .zhToEn
        persistPreference()
        toast.show(direction == .zhToEn ? "中→英" : "英→中", anchor: anchor)
        configure()
    }

    @objc private func openSettings(_ sender: Any?) {
        suspend()
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Gogaku Settings.app"))
    }

    @objc private func restoreDraft(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let draft = DraftStore.shared.drafts.first(where: { $0.id == id }),
              draft.application == application, draft.mode == mode, draft.direction == direction,
              let current = currentTarget() else { return }
        suspend(); configure(); target = current
        if draft.literal {
            guard let c = client(), gg_insert_text(c, draft.raw) else { return }
            _ = DraftStore.shared.take(id: id)
            return
        }
        if draft.mode == .normal || (draft.mode == .learning && draft.direction == .zhToEn) {
            // 普通模式与学习中→英同一条核心路径；学习中→英用应用哨兵恢复组合。
            let settings = self.settings
            let app = draft.mode == .learning ? Self.learningCoreApp : current.application
            let field = currentFieldID()
            let snapshot: NormalSnapshot? = hub.sync {
                guard let engine = self.hub.engine(settings) else { return nil }
                EngineHub.shared.lastAppField = (app, field)
                return engine.restoreRawInput(draft.raw, app: app, field: field, timeMs: Self.nowMs())
            }
            guard let snapshot else { return }
            _ = DraftStore.shared.take(id: id)
            applyNormal(snapshot, target: current)
            return
        }
        _ = DraftStore.shared.take(id: id)
        edit { try $0.restore(draft.raw) }
    }

    @objc private func clearDrafts(_ sender: Any?) { DraftStore.shared.clear() }

    override func menu() -> NSMenu! {
        // 菜单（quickmt 开发版裁决后）：学习模式／学习方向两项按设置开关解除
        // 置灰（Ctrl+Shift+K／Ctrl+Shift+J 同款动作）；草稿恢复（仅有草稿时）
        // ＋清空＋设置。开关关闭时学习两项置灰并说明，不再只留在设置页说明。
        let menu = NSMenu()
        let learning = NSMenuItem(title: learningDevEnabled
            ? (mode == .learning ? "返回普通模式" : "进入学习模式")
            : "学习模式（开发版未启用）",
            action: #selector(toggleMode(_:)), keyEquivalent: "k")
        learning.keyEquivalentModifierMask = [.control, .shift]
        learning.target = self
        menu.addItem(learning)
        let directionItem = NSMenuItem(title: direction == .zhToEn ? "学习方向：中→英" : "学习方向：英→中",
                                       action: #selector(toggleDirection(_:)), keyEquivalent: "j")
        directionItem.keyEquivalentModifierMask = [.control, .shift]
        directionItem.target = self
        menu.addItem(directionItem)
        menu.addItem(.separator())
        let drafts = DraftStore.shared.drafts.filter { $0.application == application && $0.mode == mode && $0.direction == direction }
        if !drafts.isEmpty {
            for (index, draft) in drafts.enumerated() {
                let label = draft.literal ? "恢复未发出文字" : "恢复未完成输入"
                let i = NSMenuItem(title: "\(label) \(index + 1)（\(draft.raw.count) 字符）", action: #selector(restoreDraft(_:)), keyEquivalent: "")
                i.target = self; i.representedObject = draft.id; menu.addItem(i)
            }
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "清空未完成输入", action: #selector(clearDrafts(_:)), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
            menu.addItem(.separator())
        }
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    /// 菜单项可用性：学习两项仅在开发版开关打开时可操作，其余保持可用。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleMode(_:)), #selector(toggleDirection(_:)):
            return learningDevEnabled
        default:
            return true
        }
    }
}

/// 「中／英」等模式切换提示浮层：深色圆角背景（音量 HUD 风格，深浅外观均
/// 可读），2 秒自动隐藏；位置跟随输入插入点（优先锚点上方，复用
/// PanelPlacement 几何），无有效锚点时不显示。
final class ToastWindow: NSPanel {
    private let box = NSView()
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 44, height: 36),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // 深色圆角背景：白字在任何宿主背景上都可读（用户反馈：加背景）。
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        box.layer?.cornerRadius = 9
        box.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 22, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        box.frame = NSRect(x: 0, y: 0, width: 44, height: 36)
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        contentView = box
    }

    func show(_ text: String, anchor: NSRect? = nil) {
        hideWork?.cancel()
        // 按文本自适应尺寸（固定 44×36 会截断「中→英」等提示）。
        let textSize = text.size(withAttributes: [.font: label.font!])
        let size = NSSize(width: max(44, ceil(textSize.width) + 24), height: 40)
        // 用户裁决：提示必须在输入附近；无有效锚点时不显示（不放固定角落）。
        guard let caret = anchor, caret != .zero,
              let origin = PanelPlacement.toastOrigin(
                  anchor: caret, panelSize: size,
                  screens: NSScreen.screens.map { ScreenFrame(frame: $0.frame, visibleFrame: $0.visibleFrame) }) else { return }
        label.stringValue = text
        label.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        setContentSize(size)
        setFrameOrigin(origin)
        orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        // 2026-11 用户反馈：时长 2s → 1s。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        orderOut(nil)
    }
}
