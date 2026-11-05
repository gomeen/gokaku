import Foundation
import CGogakuCore

extension GcIssue {
    mutating func freeStrings() {
        free(explanation)
        explanation = nil
    }
}

public struct SourceExpression: Equatable, Sendable {
    public let id: String
    public let text: String
    public let range: RawRange
}
/// 每页候选数：引擎桥、会话分页、候选窗与数字选择共用一个值。
public enum CandidatePage {
    public static let size = 9
}

/// 学习组合会话：共享 C++ 学习核心（ABI v3）的 Swift 薄封装。
///
/// 学习组合状态机、三状态按键语义与翻译调度合同全部在共享核心
/// （`native/GogakuCore/learning_session.cpp`，轨迹见 tests/learning_session_test.cpp）；
/// 本类只做事件编组、身份映射（核心 epoch → 平台组合 UUID）与翻译请求回调
/// 触发。翻译传输（TranslationService／worker 进程）仍在平台侧。
/// 所有变更顺序执行；异步结果只发布候选，绝不创建提交。
public final class CompositionSession {
    /// 快照报告 translation_needed 时触发（发布语义：TYPE/BACKSPACE/RESTORE/
    /// CHOOSE 后源非空，或 REQUEST_SOURCE）。
    public var translationNeeded: ((InputStamp, SourceExpression) -> Void)?
    public private(set) var view: CompositionView

    public struct Config: Sendable {
        public let dictPath: String
        public let modelPath: String
        public init(dictPath: String, modelPath: String) {
            self.dictPath = dictPath
            self.modelPath = modelPath
        }
    }

    private let sessionID = UUID()
    /// 核心 epoch（configure/cancel 递增）→ 平台组合标识；stamp 不把 UUID 交给核心。
    private var compositionIDs: [UInt64: UUID] = [:]
    /// 候选稳定 ID：候选追加不重编号（迟到结果不得替换已显示编号）。
    private var candidateIDs: [String: UUID] = [:]
    private var sources: [SourceExpression] = []
    private let handle: OpaquePointer?

    public init(config: Config) throws {
        let dictCopy = config.dictPath.unsafeConstUTF8Copy()
        let modelCopy = config.modelPath.unsafeConstUTF8Copy()
        defer { freeConst(dictCopy); freeConst(modelCopy) }
        var c = GcLearningConfig()
        c.dict_path = dictCopy
        c.model_path = modelCopy
        var err = [CChar](repeating: 0, count: 256)
        var pointer: OpaquePointer?
        let code = gc_learning_session_create(&c, &pointer, &err, err.count)
        guard code == 0, let pointer else {
            throw code == 1 ? EngineError.invalidCommand : EngineError.resourceUnavailable
        }
        handle = pointer
        view = CompositionView(stamp: InputStamp(session: sessionID))
    }

    deinit {
        if let handle { gc_learning_session_destroy(handle) }
    }

    // MARK: - 事件编组

    /// 发送事件并落地快照。返回是否产生有效快照；rc=1（无效请求）静默保留
    /// 旧视图；rc=2（引擎错误，与历史 try 序列同源）抛出。
    @discardableResult
    private func perform(_ kind: Int32,
                         arg0: Int64 = 0, arg1: Int64 = 0, arg2: Int64 = 0,
                         text: String? = nil,
                         stamp: InputStamp? = nil,
                         sourceID: String? = nil, source: String? = nil,
                         target: String? = nil, resource: String? = nil,
                         approved: Bool = false, message: String? = nil,
                         issues: [SpellingIssue]? = nil,
                         invalid: @autoclosure () -> Error? = nil) throws -> Bool {
        guard let handle else { throw EngineError.engineFailure }
        var ev = GcLearningEvent()
        ev.kind = kind
        ev.arg0 = arg0
        ev.arg1 = arg1
        ev.arg2 = arg2
        let textCopy = text?.unsafeConstUTF8Copy()
        let sourceIDCopy = sourceID?.unsafeConstUTF8Copy()
        let sourceCopy = source?.unsafeConstUTF8Copy()
        let targetCopy = target?.unsafeConstUTF8Copy()
        let resourceCopy = resource?.unsafeConstUTF8Copy()
        let messageCopy = message?.unsafeConstUTF8Copy()
        var issueItems: [GcIssue] = []
        defer {
            freeConst(textCopy); freeConst(sourceIDCopy); freeConst(sourceCopy)
            freeConst(targetCopy); freeConst(resourceCopy); freeConst(messageCopy)
            for i in issueItems.indices { issueItems[i].freeStrings() }
        }
        if let text { ev.text = textCopy }
        if let stamp {
            ev.stamp_focus = stamp.focus
            ev.stamp_epoch = epoch(of: stamp.composition)
            ev.stamp_revision = stamp.revision
            ev.stamp_mode = stamp.mode == .learning ? Int32(GC_LEARN_MODE_LEARNING) : Int32(GC_LEARN_MODE_NORMAL)
            ev.stamp_direction = stamp.direction == .enToZh ? Int32(GC_LEARN_DIR_EN_TO_ZH) : Int32(GC_LEARN_DIR_ZH_TO_EN)
        }
        if let sourceID { ev.source_id = sourceIDCopy }
        if let source { ev.source = sourceCopy }
        if let target { ev.target = targetCopy }
        if let resource { ev.resource = resourceCopy }
        ev.approved = approved ? 1 : 0
        if let message { ev.message = messageCopy }
        if let issues {
            issueItems = issues.map {
                var item = GcIssue()
                item.location = Int64($0.location)
                item.length = Int64($0.length)
                item.explanation = $0.explanation.unsafeUTF8Copy()
                return item
            }
            issueItems.withUnsafeMutableBufferPointer { buffer in
                ev.issues = UnsafePointer(buffer.baseAddress)
                ev.issue_count = buffer.count
            }
        }
        var pointer: UnsafeMutablePointer<GcLearningSnapshot>?
        let code = gc_learning_handle(handle, &ev, &pointer)
        switch code {
        case 0:
            guard let pointer else { throw EngineError.engineFailure }
            defer { gc_learning_snapshot_free(pointer) }
            ingest(pointer.pointee)
            return true
        case 1:
            // 无效请求：状态不变；与历史返回 nil/无操作同源。
            if let error = invalid() { throw error }
            return false
        default:
            throw EngineError.engineFailure
        }
    }

    private func epoch(of composition: UUID) -> UInt64 {
        compositionIDs.first(where: { $0.value == composition })?.key ?? UInt64.max
    }

    private func stamp(focus: UInt64, epoch: UInt64, revision: UInt64,
                       mode: Int32, direction: Int32) -> InputStamp {
        let composition: UUID
        if let known = compositionIDs[epoch] {
            composition = known
        } else {
            composition = UUID()
            compositionIDs[epoch] = composition
        }
        return InputStamp(session: sessionID, focus: focus, composition: composition, revision: revision,
                          mode: mode == Int32(GC_LEARN_MODE_LEARNING) ? .learning : .normal,
                          direction: direction == Int32(GC_LEARN_DIR_EN_TO_ZH) ? .enToZh : .zhToEn)
    }

    /// 快照 → 视图落地；发布旗标触发翻译请求回调。
    private func ingest(_ snap: GcLearningSnapshot) {
        let stamp = self.stamp(focus: snap.focus, epoch: snap.epoch, revision: snap.revision,
                               mode: snap.mode, direction: snap.direction)
        var raw = "", preedit = "", status = "", typedPrefix = ""
        if snap.raw != nil { raw = String(cString: snap.raw) }
        if snap.preedit != nil { preedit = String(cString: snap.preedit) }
        if snap.status != nil { status = String(cString: snap.status) }
        if snap.typed_prefix != nil { typedPrefix = String(cString: snap.typed_prefix) }
        var candidates: [Candidate] = []
        if let items = snap.candidates {
            for i in 0..<snap.candidate_count {
                let item = items[i]
                let sourceID = String(cString: item.source_id)
                let source = String(cString: item.source)
                let target = String(cString: item.target)
                let resource = String(cString: item.resource)
                let start = Int(item.start), length = Int(item.length)
                let engineIndex = item.engine_index >= 0 ? Int(item.engine_index) : nil
                let key = "\(sourceID)\u{0}\(source)\u{0}\(target)\u{0}\(resource)\u{0}\(start):\(length):\(engineIndex ?? -1)"
                let id: UUID
                if let known = candidateIDs[key] {
                    id = known
                } else {
                    id = UUID()
                    candidateIDs[key] = id
                }
                candidates.append(Candidate(id: id, stamp: stamp, sourceID: sourceID, source: source,
                                            range: RawRange(start: start, length: length),
                                            target: target, explanation: "", resource: resource,
                                            engineIndex: engineIndex))
            }
        }
        var issues: [SpellingIssue] = []
        if let items = snap.issues {
            for i in 0..<snap.issue_count {
                issues.append(SpellingIssue(location: Int(items[i].location), length: Int(items[i].length),
                                            explanation: String(cString: items[i].explanation)))
            }
        }
        sources = []
        if let items = snap.sources {
            for i in 0..<snap.source_count {
                sources.append(SourceExpression(id: String(cString: items[i].id),
                                                text: String(cString: items[i].text),
                                                range: RawRange(start: Int(items[i].start), length: Int(items[i].length))))
            }
        }
        view = CompositionView(stamp: stamp)
        view.raw = raw
        view.preedit = preedit
        view.status = status
        // 已暂存中文前缀只用于分色（普通态；学习态为空串）。
        view.typedPrefix = typedPrefix
        view.candidates = candidates
        view.page = Int(snap.page)
        view.selected = Int(snap.selected)
        view.issues = issues
        view.totalCandidates = Int(snap.total_candidates)
        // 提交意图（choose/original 成功时非空）；id 由平台生成。
        if let commitText = snap.commit_text.map({ String(cString: $0) }) {
            let commitStamp = self.stamp(focus: snap.commit_focus, epoch: snap.commit_epoch,
                                         revision: snap.commit_revision, mode: snap.commit_mode,
                                         direction: snap.commit_direction)
            cachedCommit = CommitIntent(id: UUID(), stamp: commitStamp,
                                        text: commitText,
                                        source: snap.commit_source.map { String(cString: $0) } ?? "",
                                        resource: snap.commit_resource.map { String(cString: $0) } ?? "",
                                        original: snap.commit_original != 0,
                                        recoveryRaw: snap.commit_recovery_raw.map { String(cString: $0) } ?? "")
        } else {
            cachedCommit = nil
        }
        if snap.translation_needed != 0,
           sources.indices.contains(Int(snap.translation_source_index)) {
            translationNeeded?(stamp, sources[Int(snap.translation_source_index)])
        }
    }

    private static func modeCode(_ mode: InputMode) -> Int64 {
        mode == .learning ? Int64(GC_LEARN_MODE_LEARNING) : Int64(GC_LEARN_MODE_NORMAL)
    }
    private static func directionCode(_ direction: Direction) -> Int64 {
        direction == .enToZh ? Int64(GC_LEARN_DIR_EN_TO_ZH) : Int64(GC_LEARN_DIR_ZH_TO_EN)
    }

    // MARK: - 会话 API（与历史 CompositionSession 同签名）

    public func configure(focus: UInt64, mode: InputMode, direction: Direction) {
        _ = try? perform(Int32(GC_LEV_CONFIGURE), arg0: Int64(focus),
                     arg1: Self.modeCode(mode), arg2: Self.directionCode(direction))
    }

    public func type(_ text: String) throws {
        try perform(Int32(GC_LEV_TYPE), text: text,
                    invalid: EngineError.invalidCommand)
    }

    public func backspace() throws {
        try perform(Int32(GC_LEV_BACKSPACE), invalid: EngineError.invalidCommand)
    }

    public func viewError() {
        _ = try? perform(Int32(GC_LEV_VIEW_ERROR))
    }

    public func cancel() {
        _ = try? perform(Int32(GC_LEV_CANCEL))
    }

    public func restore(_ raw: String) throws {
        try perform(Int32(GC_LEV_RESTORE), text: raw, invalid: EngineError.invalidCommand)
    }

    public func page(_ delta: Int) throws {
        try perform(Int32(GC_LEV_PAGE), arg0: Int64(delta), invalid: EngineError.invalidCommand)
    }

    public func navigate(_ delta: Int) {
        _ = try? perform(Int32(GC_LEV_NAVIGATE), arg0: Int64(delta))
    }

    public func choose(_ candidate: Candidate) throws -> CommitIntent? {
        guard candidate.stamp == view.stamp, let index = view.candidates.firstIndex(of: candidate) else {
            return nil
        }
        guard try perform(Int32(GC_LEV_CHOOSE), arg0: Int64(index)) else { return nil }
        return pendingCommit()
    }

    public func original() -> CommitIntent? {
        guard (try? perform(Int32(GC_LEV_ORIGINAL))) == true else { return nil }
        return pendingCommit()
    }

    /// 最近一次快照携带的提交意图（ingest 缓存；choose/original 专用）。
    private func pendingCommit() -> CommitIntent? { cachedCommit }

    private var cachedCommit: CommitIntent?

    public func sourceExpressions() -> [SourceExpression] { sources }
    public func requestSource(_ index: Int) {
        _ = try? perform(Int32(GC_LEV_REQUEST_SOURCE), arg0: Int64(index))
    }

    /// quickmt 成功结果进入候选；approved 由调用方按裁决传入：开发版豁免
    /// （resource == quickmt-ct2-dev）之外的资源仍只接受经审核资源清单批准的结果。
    public func receive(_ result: TranslationResult, approved: Bool) {
        guard result.stamp.session == sessionID else { return }
        _ = try? perform(Int32(GC_LEV_RECEIVE),
                     stamp: result.stamp,
                     sourceID: result.sourceID, source: result.source,
                     target: result.target, resource: result.resource, approved: approved)
    }

    /// 开发版失败路径：不创建候选、不清输入；状态行提示保留输入与原文上屏。
    public func translationFailed(_ result: TranslationResult, message: String) {
        guard result.stamp.session == sessionID else { return }
        _ = try? perform(Int32(GC_LEV_TRANSLATION_FAILED), stamp: result.stamp, message: message)
    }

    public func setIssues(_ issues: [SpellingIssue], stamp: InputStamp) {
        guard stamp.session == sessionID else { return }
        _ = try? perform(Int32(GC_LEV_SET_ISSUES), stamp: stamp, issues: issues)
    }
}
