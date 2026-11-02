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

@objc(GogakuInputController)
final class GogakuInputController: IMKInputController {
    /// 共享引擎（词库只加载一次）；本控制器只是调用方。
    private let hub = EngineHub.shared
    private var session: CompositionSession?   // 学习路径（验收门禁关闭，保持 nil）
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
    private var flushWork: DispatchWorkItem?
    /// 当前有效显示位置（宿主光标矩形）；nil＝面板隐藏但组合保留。
    /// 与目标身份锚点分离：位置变化不改变目标身份。
    private var displayRect: NSRect?
    /// 组合中的位置复查定时器（100ms；处理滚动／窗口移动；无组合或失焦立即停止）。
    private var positionTimer: Timer?
    // 真实宿主安全矩阵未通过前，不启用学习辅助或采集。
    private let learningHostValidated = false

    private lazy var spelling: TranslationService = {
        let service = TranslationService(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/GogakuTranslator"), arguments: ["--spell"])
        service.onResult = { [weak self] result in
            DispatchQueue.main.async {
                guard let self, var view = self.displayed, view.stamp == result.stamp,
                      self.pendingEdits == 0,
                      let current = self.currentTarget(), current == self.target,
                      let rect = self.displayRect else { return }
                view.issues = result.issues ?? []; self.displayed = view
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
    private lazy var translator: TranslationService = {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/GogakuTranslator")
        let service = TranslationService(executable: path)
        service.onResult = { [weak self] result in
            guard let self else { return }
            self.hub.async {
                // 真实语言资源未经质量确认，不能成为可提交默认结果。
                self.session?.receive(result, approved: false)
                self.publishLearning(generation: result.stamp.focus)
            }
        }
        return service
    }()

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
        panel.choose = { [weak self] row in self?.panelChoose(row: row) }
        settings = Settings.load()
        panel.updateTheme(settings.candidateTheme, fontSize: CGFloat(settings.candidateFontSize))
        application = gg_read_host(client())?.application ?? ""
        let preference = settings.applications[application] ?? AppPreference()
        // 学习模式门禁关闭时忽略历史偏好里的学习标记，普通模式始终可用。
        mode = learningHostValidated ? preference.mode : .normal
        direction = preference.direction
        configure()
    }

    override func deactivateServer(_ sender: Any!) { stopPositionRefresh(); suspend(); active = false }
    override func commitComposition(_ sender: Any!) { suspend() }
    override func inputControllerWillClose() { suspend(); active = false }
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
    /// 当前有效位置，也不再用鼠标位置或虚构屏幕尺寸回退。
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

    private func currentTarget(readRectangle: Bool = false) -> FocusTarget? {
        guard let facts = hostFacts(readRectangle: readRectangle) else { return nil }
        let freshRect = facts.rectState == .valid ? facts.rect : .zero
        if let previous = target, displayed != nil || !markedShown.isEmpty {
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
        displayRect = nil; stopPositionRefresh()
        markedShown = ""; markedCaret = -1
        panel.updateTheme(settings.candidateTheme, fontSize: CGFloat(settings.candidateFontSize))
        panel.dismiss(); translator.invalidate(); spelling.invalidate(); requestedSpellStamp = nil
        records.policy(recording: settings.recording, excludedApplications: settings.excludedApplications)
        let generation = focus, selectedMode = mode, selectedDirection = direction
        let field = currentFieldID(), app = application
        hub.async { [weak self] in
            guard let self else { return }
            self.session?.configure(focus: generation, mode: selectedMode, direction: selectedDirection)
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
        // 先隐藏并使迟到渲染失效；宿主字母仅在仍有原字段证据时清除。
        stopPositionRefresh(); displayRect = nil
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
            self.session?.configure(focus: generation, mode: oldMode, direction: oldDirection)
            if let normal = self.hub.engine(self.settings) {
                _ = normal.handle(.focusSync, app: app, field: "", timeMs: Self.nowMs())
                normal.flush()
            }
        }
    }

    @objc private func applicationChanged() { if active { suspend() } }

    @objc private func reloadSettings() {
        suspend()
        settings = Settings.load()
        applyEngineSettings()
        configure()
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
            // Shift 单击判定；其他修饰键变化不挂起组合（规格）。
            // Hyper（fn／globe 修饰）不算 Shift 单击：fn 按住时 flags 含 .function，
            // 与 Command／Control／Option 一样取消单击资格；长按（≥600ms）与
            // 按住期间的其他按键已在 ShiftClickTracker 排除。
            let flags = event.modifierFlags.intersection([.shift])
            let onlyShift = flags.rawValue != 0 &&
                event.modifierFlags.intersection([.command, .control, .option, .function]).rawValue == 0
            if onlyShift && !shiftTracker.pressing {
                shiftTracker.press(event)
            } else if shiftTracker.pressing {
                if !flags.contains(.shift), let side = shiftTracker.release(event) {
                    if let current = currentTarget() {
                        _ = handleNormalSync(.shiftClick(side: side), at: current, fieldChanged: target == nil)
                    } else { suspend() }
                } else { shiftTracker.markOtherKey() }
            }
            return false   // 修饰键事件本身交还宿主
        }
        if event.type != .keyDown {
            suspend(); return false
        }
        if shiftTracker.pressing { shiftTracker.markOtherKey() }
        if match(settings.modeShortcut, event: event) { toggleMode(nil); return true }
        if match(settings.directionShortcut, event: event) { toggleDirection(nil); return true }
        if match(settings.quickAddShortcut, event: event) && mode == .normal, let current = currentTarget() {
            return handleNormalSync(.quickAdd, at: current, fieldChanged: false)
        }
        guard let current = currentTarget(readRectangle: displayed == nil && markedShown.isEmpty) else { suspend(); return false }
        let fieldChanged = target == nil || target?.application != current.application || target?.pid != current.pid
        target = current; application = current.application
        if mode == .normal {
            // 普通模式同步完成核心处理与宿主写入；面板布局排到下一轮。
            // consumed=false 时透传宿主，保证英文直输等透传语义正确。
            return handleNormalSync(event, at: current, fieldChanged: fieldChanged)
        }
        handleLearning(event)
        return true
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
        let app = target.application, field = currentFieldID(), time = Self.nowMs()
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
        if snap.toast != 0 { toast.show(snap.toast == 1 ? "中" : "英") }
        // 无组合的瞬态说明（如快速添加结果）用提示浮层；组合中状态走面板状态行。
        if !snap.composing && !snap.status.isEmpty { toast.show(snap.status) }
        if snap.candidates.contains(where: { $0.kind == GC_CAND_LEARNED }) {
            scheduleFlush()
        }
        if !snap.composing { panel.dismiss() }
        if !snap.commit.isEmpty {
            insertCommit(snap.commit, at: target, preWriteCheck: current)
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
            Candidate(stamp: view.stamp,
                      sourceID: "normal:\(item.kind)",
                      source: item.text,
                      range: RawRange(start: 0, length: 0),
                      target: item.text,
                      explanation: settings.glossEnabled ? item.gloss : "",
                      resource: "gogaku-core")
        }
        view.status = snap.status
        if snap.composing {
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
        } else {
            displayed = nil
            displayRect = nil
            stopPositionRefresh()
            panel.dismiss()
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
            // 隐藏，矩形恢复后重新跟随）；从未获得过锚点（如 Bob 输入弹窗）才走
            // hidePanelKeepComposition 的隐藏保留组合路径。
            return
        }
        let changed = displayRect != current.rect
        displayRect = current.rect
        if changed, let view = displayed {
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
        guard mode == .normal, let snapDisplayed = displayed, pendingEdits == 0 else {
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
        guard let view = displayed, session != nil else { return }
        let pageStart = view.page * CandidatePage.size
        let index = pageStart + row
        if view.candidates.indices.contains(index) { choose(view.candidates[index]) }
    }

    private func handleLearning(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command) {
            if event.keyCode == 36, mode == .learning, let view = displayed, !view.raw.isEmpty {
                commitLearningOriginal()
            }
            return
        }
        if flags.contains(.control) { return }
        let pageDelta = pageDelta(for: event)
        if let delta = pageDelta, let view = displayed, !view.raw.isEmpty {
            edit { try $0.page(delta) }
            return
        }
        let text = event.characters ?? ""
        if (displayed?.raw.isEmpty ?? true) {
            if !(text.count == 1 && text.unicodeScalars.allSatisfy({ (97...122).contains($0.value) })) { return }
            if flags.contains(.option) || [36, 48, 51, 53, 115, 119, 123, 124, 125, 126, 116, 121].contains(event.keyCode) { return }
        }
        switch event.keyCode {
        case 53: cancelLearning(); return
        case 51: edit { try $0.backspace() }; return
        case 116: edit { try $0.page(-1) }; return
        case 121: edit { try $0.page(1) }; return
        case 125, 124: edit { $0.navigate(1) }; return
        case 126, 123: edit { $0.navigate(-1) }; return
        case 48: suspend(); return
        case 36:
            if mode == .normal { commitLearningOriginal() } else { chooseCurrent() }
            return
        case 49:
            if direction == .zhToEn { chooseCurrent(); return }
        default: break
        }
        if let n = Int(event.charactersIgnoringModifiers ?? text), (1...CandidatePage.size).contains(n), flags.contains(.option) {
            if let view = displayed, pendingEdits == 0 {
                let index = view.page * CandidatePage.size + n - 1
                if view.candidates.indices.contains(index) { choose(view.candidates[index]) }
            }
            return
        }
        if flags.contains(.option) { return }
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return }
        edit { try $0.type(text) }
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
            do { try body(session) } catch { session.viewError() }
            self.publishLearning(generation: generation, completesEdit: true)
        }
    }

    private func publishLearning(generation: UInt64, completesEdit: Bool = false) {
        guard let value = session?.view else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focus == generation else { return }
            if completesEdit { self.pendingEdits = max(0, self.pendingEdits - 1) }
            guard self.pendingEdits == 0 else { return }
            self.displayed = value
            if value.raw.isEmpty {
                self.panel.dismiss(); self.target = nil; return
            }
            guard let current = self.currentTarget(), current == self.target else { self.suspend(); return }
            var shown = value
            if self.mode == .learning, !self.learningHostValidated {
                shown.status = "当前宿主的学习安全路径尚未验收；不执行翻译、拼写辅助或记录。可明确原文上屏。"
            }
            if self.learningHostValidated, self.mode == .learning, self.direction == .enToZh, self.requestedSpellStamp != value.stamp {
                self.requestedSpellStamp = value.stamp
                self.spelling.request(TranslationRequest(stamp: value.stamp, sourceID: "spelling", source: value.raw,
                                                         resource: "NSSpellChecker:en_US", ignoredWords: Array(self.settings.ignoredWords)))
            }
            self.displayed = shown
            guard let rect = self.displayRect else { self.panel.dismiss(); return }
            self.panel.render(shown, at: rect, targetWindowLevel:
                              GGPanelTargetLevel(current.windowLevel, current.windowLevelValid))
        }
    }

    private func chooseCurrent() {
        guard pendingEdits == 0, let view = displayed, view.candidates.indices.contains(view.selected) else { NSSound.beep(); return }
        choose(view.candidates[view.selected])
    }

    private func choose(_ candidate: Candidate) {
        guard pendingEdits == 0, displayed?.stamp == candidate.stamp, let anchor = target, currentTarget() == anchor else { suspend(); return }
        let generation = focus
        pendingEdits += 1; displayed = nil
        hub.async { [weak self] in
            guard let self, let session = self.hub.learningSession(self.settings) else { return }
            let intent = try? session.choose(candidate)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let intent { self.insertLearning(intent, anchor: anchor, generation: generation) }
            }
            self.publishLearning(generation: generation, completesEdit: true)
        }
    }

    private func commitLearningOriginal() {
        guard let view = displayed, !view.raw.isEmpty, let anchor = target, currentTarget() == anchor, let c = client() else { return }
        let raw = view.raw, selectedMode = mode, selectedDirection = direction
        cancelLearning()
        func saveDraft() {
            DraftStore.shared.save(application: anchor.application, mode: selectedMode, direction: selectedDirection, raw: raw)
        }
        if raw.utf16.count == 1 {
            guard gg_mark_confirmed_text(c, raw), let markedTarget = currentTarget() else { saveDraft(); return }
            target = markedTarget
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.pendingEdits == 0, let nowTarget = self.currentTarget(), nowTarget == markedTarget else {
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
        guard generation == focus, currentTarget() == anchor, let c = client() else {
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
        panel.dismiss(); translator.invalidate(); spelling.invalidate(); requestedSpellStamp = nil
        let m = mode, d = direction
        hub.async { [weak self] in self?.session?.configure(focus: generation, mode: m, direction: d) }
    }

    private func persistPreference() {
        var p = AppPreference(); p.mode = mode; p.direction = direction
        settings.applications[application] = p
        // 磁盘操作不放入按键回调：串行协调器合并最新改动，失败保留待保存。
        SettingsStore.shared.submit(settings)
    }

    @objc private func toggleMode(_ sender: Any?) {
        // 正式翻译模型未过质量门槛：学习模式保持关闭（菜单置灰并说明原因）。
        NSSound.beep()
    }

    @objc private func toggleDirection(_ sender: Any?) {
        NSSound.beep()
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
        if draft.mode == .normal {
            let settings = self.settings, app = current.application, field = currentFieldID()
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
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.isEnabled = enabled
            menu.addItem(i)
        }
        item("切换为学习模式（正式翻译模型未过质量门槛，保持关闭）", #selector(toggleMode(_:)), enabled: false)
        item("切换学习方向（学习功能关闭）", #selector(toggleDirection(_:)), enabled: false)
        menu.addItem(.separator())
        for (index, draft) in DraftStore.shared.drafts.enumerated() where draft.application == application && draft.mode == mode && draft.direction == direction {
            let label = draft.literal ? "恢复未发出文字" : "恢复未完成输入"
            let i = NSMenuItem(title: "\(label) \(index + 1)（\(draft.raw.count) 字符）", action: #selector(restoreDraft(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = draft.id; menu.addItem(i)
        }
        item("清空内存草稿", #selector(clearDrafts(_:)))
        item("设置与学习片段…", #selector(openSettings(_:)))
        return menu
    }
}

/// 「中／英」提示浮层：无边框小面板，0.8 秒自动隐藏。
final class ToastWindow: NSPanel {
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
        label.font = .systemFont(ofSize: 22, weight: .medium)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 0, width: 44, height: 36)
        contentView = label
    }

    func show(_ text: String) {
        hideWork?.cancel()
        label.stringValue = text
        label.textColor = NSColor.white
        // 右上角固定示意位置（真实锚点在真实宿主验证时核对）。
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            setFrameTopLeftPoint(NSPoint(x: visible.maxX - 60, y: visible.maxY - 48))
        }
        orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        orderOut(nil)
    }
}
