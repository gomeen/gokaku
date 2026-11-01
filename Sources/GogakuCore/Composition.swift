import Foundation

public struct SourceExpression: Equatable, Sendable {
    public let id: String
    public let text: String
    public let range: RawRange
}
/// 每页候选数：引擎桥、会话分页、候选窗与数字选择共用一个值。
public enum CandidatePage {
    public static let size = 9
}
/// 所有变更顺序执行；异步结果只发布候选，绝不创建提交。
public final class CompositionSession {
    public private(set) var view: CompositionView
    private let engine: ChineseEngine
    private var normal = EngineSnapshot()
    private var sources: [SourceExpression] = []
    private var frozen = false
    public var translationNeeded: ((InputStamp, SourceExpression) -> Void)?
    public init(engine: ChineseEngine) {
        self.engine = engine; view = CompositionView(stamp: InputStamp())
    }
    public func configure(focus: UInt64, mode: InputMode, direction: Direction) {
        _ = try? engine.apply(.cancel)
        view = CompositionView(stamp: InputStamp(session: view.stamp.session, focus: focus, mode: mode, direction: direction))
        normal = EngineSnapshot(); sources = []; frozen = false
    }
    private func revise() {
        view.stamp.revision &+= 1; view.candidates = []; view.selected = 0; view.page = 0
        view.issues = []; view.status = ""; frozen = false
    }
    public func type(_ text: String) throws {
        guard view.raw.unicodeScalars.count + text.unicodeScalars.count <= 512 else {
            view.status = "输入上限 512 个 Unicode 标量；已保留全部现有输入"; return
        }
        if view.stamp.mode == .normal {
            for scalar in text.unicodeScalars { normal = try engine.apply(.type(scalar.value)) }
            revise(); publishNormal()
        } else {
            view.raw += text; revise(); try publishLearning()
        }
    }
    public func backspace() throws {
        if view.stamp.mode == .normal {
            normal = try engine.apply(.backspace); revise(); publishNormal()
        } else if !view.raw.isEmpty {
            view.raw.removeLast(); revise(); try publishLearning()
        }
    }
    public func viewError() { view.status = "引擎操作失败；输入已保留，请取消或保存草稿" }
    public func cancel() {
        _ = try? engine.apply(.cancel)
        let old = view.stamp
        view = CompositionView(stamp: InputStamp(session: old.session, focus: old.focus, mode: old.mode, direction: old.direction))
        normal = EngineSnapshot(); sources = []; frozen = false
    }
    public func restore(_ raw: String) throws { cancel(); try type(raw) }
    private func publishNormal() {
        view.raw = normal.raw; view.preedit = normal.preedit; view.page = normal.page
        view.typedPrefix = normal.selected; view.totalCandidates = normal.total
        view.candidates = normal.candidates.map { item in
            Candidate(stamp: view.stamp, sourceID: "libime:\(item.index)", source: normal.selected + item.text,
                      range: item.range, target: item.text, explanation: "", resource: "libime-1.1.17", engineIndex: item.index)
        }
    }
    public func page(_ delta: Int) throws {
        if view.stamp.mode == .normal {
            normal = try engine.apply(.page(delta)); revise(); publishNormal()
        } else {
            frozen = true
            let last = max(0, (view.candidates.count - 1) / CandidatePage.size)
            view.page = max(0, min(last, view.page + delta)); view.selected = view.page * CandidatePage.size
        }
    }
    public func navigate(_ delta: Int) {
        frozen = true
        guard !view.candidates.isEmpty else { return }
        view.selected = max(0, min(view.candidates.count - 1, view.selected + delta))
        view.page = view.selected / CandidatePage.size
    }
    public func choose(_ candidate: Candidate) throws -> CommitIntent? {
        guard candidate.stamp == view.stamp, view.candidates.contains(candidate) else { return nil }
        frozen = true
        if view.stamp.mode == .normal, let index = candidate.engineIndex {
            let recoveryRaw = view.raw
            normal = try engine.apply(.select(index)); revise()
            if !normal.commit.isEmpty {
                let intent = CommitIntent(id: UUID(), stamp: candidate.stamp, text: normal.commit, source: candidate.source, resource: candidate.resource, original: false, recoveryRaw: recoveryRaw)
                cancel(); return intent
            }
            publishNormal(); return nil
        }
        // 学习候选只消费它明确覆盖的源范围；当前实现只允许从组合起点消费。
        guard candidate.range.start == 0, candidate.range.length <= view.raw.unicodeScalars.count else { return nil }
        let intent = CommitIntent(id: UUID(), stamp: view.stamp, text: candidate.target, source: candidate.source, resource: candidate.resource, original: false, recoveryRaw: view.raw)
        view.raw = String(String.UnicodeScalarView(view.raw.unicodeScalars.dropFirst(candidate.range.length)))
        revise(); try publishLearning()
        return intent
    }
    public func original() -> CommitIntent? {
        guard !view.raw.isEmpty else { return nil }
        let intent = CommitIntent(id: UUID(), stamp: view.stamp, text: view.raw, source: view.raw, resource: "original", original: true, recoveryRaw: view.raw)
        cancel(); return intent
    }
    private func decode(_ keys: String) throws -> EngineSnapshot {
        _ = try engine.apply(.cancel)
        var result = EngineSnapshot()
        for scalar in keys.unicodeScalars { result = try engine.apply(.type(scalar.value)) }
        return result
    }
    private func publishLearning() throws {
        sources = []; view.preedit = view.raw
        guard !view.raw.isEmpty else { return }
        if view.stamp.direction == .enToZh {
            sources = [SourceExpression(id: "english:full", text: view.raw, range: RawRange(start: 0, length: view.raw.unicodeScalars.count))]
        } else {
            // 编码与字面片段分别解码；数字、标点、emoji 永不作为拼音送入 libime。
            let scalars = Array(view.raw.unicodeScalars)
            var start = 0, decoded = "", alternatives: [SourceExpression] = []
            while start < scalars.count {
                let encoded = Self.isEncoding(scalars[start])
                var end = start + 1
                while end < scalars.count && Self.isEncoding(scalars[end]) == encoded { end += 1 }
                let text = String(String.UnicodeScalarView(scalars[start..<end]))
                if encoded {
                    let state = try decode(text)
                    guard let first = state.candidates.first, first.completes else {
                        view.status = "当前小鹤片段尚无完整中文来源"; return
                    }
                    if alternatives.isEmpty {
                        alternatives = state.candidates.filter { $0.range.start == 0 }.map { candidate in
                            SourceExpression(id: "chinese:\(start):\(candidate.index)", text: decoded + candidate.text,
                                             range: RawRange(start: 0, length: start + candidate.range.length))
                        }
                    }
                    decoded += first.text
                } else { decoded += text }
                start = end
            }
            sources = [SourceExpression(id: "chinese:full", text: decoded, range: RawRange(start: 0, length: scalars.count))]
            sources += alternatives.filter { $0.text != decoded }
            view.preedit = decoded
        }
        view.status = "本地语言资源尚未通过质量验收；输入已保留，可明确原文上屏"
        if let first = sources.first { translationNeeded?(view.stamp, first) }
    }
    public func sourceExpressions() -> [SourceExpression] { sources }
    public func requestSource(_ index: Int) {
        guard sources.indices.contains(index) else { return }
        translationNeeded?(view.stamp, sources[index])
    }
    /// approved 由经过用户质量确认的独立资源清单决定，不能由翻译成功推导。
    public func receive(_ result: TranslationResult, approved: Bool) {
        guard approved, result.stamp == view.stamp, !frozen, result.error == nil,
              let target = result.target, !target.isEmpty,
              let source = sources.first(where: { $0.id == result.sourceID && $0.text == result.source }) else { return }
        guard !view.candidates.contains(where: { $0.sourceID == source.id }) else { return }
        view.candidates.append(Candidate(stamp: view.stamp, sourceID: source.id, source: source.text, range: source.range,
                                         target: target, explanation: source.text, resource: result.resource))
        view.status = ""
    }
    public func setIssues(_ issues: [SpellingIssue], stamp: InputStamp) {
        guard stamp == view.stamp, stamp.mode == .learning, stamp.direction == .enToZh else { return }
        view.issues = issues
    }
    private static func isEncoding(_ c: Unicode.Scalar) -> Bool { (97...122).contains(c.value) || c == "'" }
}
