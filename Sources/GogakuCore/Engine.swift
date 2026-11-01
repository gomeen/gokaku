import Foundation
import CGogakuEngine

public struct RawRange: Equatable, Codable, Sendable {
    public let start: Int
    public let length: Int
    public init(start: Int, length: Int) { self.start = start; self.length = length }
}
public struct EngineCandidate: Equatable, Sendable {
    public let index: Int
    public let text: String
    public let range: RawRange
    public let completes: Bool
}
public struct EngineSnapshot: Sendable {
    public var raw = "", preedit = "", selected = "", commit = ""
    public var candidates: [EngineCandidate] = []
    public var page = 0, total = 0, selectedLength = 0
    public var composing = false
}
public enum EngineCommand {
    case peek, type(UInt32), backspace, select(Int), cancel, page(Int), cursor(Int)
}
public enum EngineError: Error { case resourceUnavailable, invalidCommand, engineFailure }
/// 由一个串行队列拥有；不向 UI 暴露 C 指针，不读个人词库，不调用 learn。
public final class ChineseEngine {
    private var handle: OpaquePointer?
    public init(directory: URL) throws {
        let code = ge_create(directory.appendingPathComponent("sc.dict").path, directory.appendingPathComponent("zh_CN.lm").path, &handle)
        guard code == 0, handle != nil else { throw EngineError.resourceUnavailable }
    }
    deinit { ge_destroy(handle) }
    public func apply(_ command: EngineCommand) throws -> EngineSnapshot {
        let op: Int32, arg: Int64
        switch command {
        case .peek: (op, arg) = (0, 0)
        case .type(let c): (op, arg) = (1, Int64(c))
        case .backspace: (op, arg) = (2, 0)
        case .select(let n): (op, arg) = (3, Int64(n))
        case .cancel: (op, arg) = (4, 0)
        case .page(let n): (op, arg) = (5, Int64(n))
        case .cursor(let n): (op, arg) = (6, Int64(n))
        }
        var pointer: UnsafeMutablePointer<GESnapshot>?
        let code = ge_command(handle, op, arg, &pointer)
        guard code == 0, let pointer else { throw code == 1 ? EngineError.invalidCommand : EngineError.engineFailure }
        defer { ge_snapshot_free(pointer) }
        let s = pointer.pointee
        var result = EngineSnapshot()
        result.raw = String(cString: s.raw); result.preedit = String(cString: s.preedit)
        result.selected = String(cString: s.selected); result.commit = String(cString: s.commit)
        result.page = s.page; result.total = s.total; result.selectedLength = s.selected_length
        result.composing = s.composing != 0
        if let items = s.candidates {
            result.candidates = (0..<s.count).map { i in
                let item = items[i]
                return EngineCandidate(index: item.index, text: String(cString: item.text), range: RawRange(start: item.raw_start, length: item.raw_length), completes: item.completes != 0)
            }
        }
        return result
    }
}

public enum InputMode: String, Codable, Sendable { case normal, learning }
public enum Direction: String, Codable, CaseIterable, Sendable { case zhToEn, enToZh }
public struct InputStamp: Hashable, Codable, Sendable {
    public var session: UUID
    public var focus: UInt64
    public var composition: UUID
    public var revision: UInt64
    public var mode: InputMode
    public var direction: Direction
    public init(session: UUID = UUID(), focus: UInt64 = 0, composition: UUID = UUID(), revision: UInt64 = 0, mode: InputMode = .normal, direction: Direction = .zhToEn) {
        self.session = session; self.focus = focus; self.composition = composition
        self.revision = revision; self.mode = mode; self.direction = direction
    }
}
public struct Candidate: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let stamp: InputStamp
    public let sourceID: String
    public let source: String
    public let range: RawRange
    public let target: String
    public let explanation: String
    public let resource: String
    public let engineIndex: Int?
    public init(id: UUID = UUID(), stamp: InputStamp, sourceID: String, source: String, range: RawRange, target: String, explanation: String, resource: String, engineIndex: Int? = nil) {
        self.id = id; self.stamp = stamp; self.sourceID = sourceID; self.source = source
        self.range = range; self.target = target; self.explanation = explanation; self.resource = resource; self.engineIndex = engineIndex
    }
}
public struct CommitIntent: Sendable {
    public let id: UUID
    public let stamp: InputStamp
    public let text: String
    public let source: String
    public let resource: String
    public let original: Bool
    public let recoveryRaw: String
}
public struct CompositionView: Sendable {
    public var stamp: InputStamp
    public var raw = "", preedit = "", status = ""
    public var candidates: [Candidate] = []
    public var page = 0
    public var selected = 0
    public var issues: [SpellingIssue] = []
    /// 已暂存中文前缀只用于分色。
    public var typedPrefix = ""
    /// 预编辑插入点的 UTF-16 偏移；nil 时默认位于末尾。
    public var preeditCaretUTF16: Int?
    /// 候选总数（含后续页），用于页码指示。
    public var totalCandidates = 0
    public init(stamp: InputStamp) { self.stamp = stamp }
}
public struct Draft: Identifiable, Sendable {
    public let id: UUID
    public let application: String
    public let mode: InputMode
    public let direction: Direction
    public let raw: String
    /// 已选中但未发出的文字须原样恢复，不能再当编码重放。
    public let literal: Bool
}
/// 仅进程内，不以 app/mode/direction 为字典键覆盖已有草稿。
public final class DraftStore {
    public static let shared = DraftStore()
    public private(set) var drafts: [Draft] = []
    public func save(application: String, mode: InputMode, direction: Direction, raw: String, literal: Bool = false) {
        guard !raw.isEmpty else { return }
        drafts.append(Draft(id: UUID(), application: application, mode: mode, direction: direction, raw: raw, literal: literal))
    }
    public func take(id: UUID) -> Draft? {
        guard let i = drafts.firstIndex(where: { $0.id == id }) else { return nil }
        return drafts.remove(at: i)
    }
    public func clear() { drafts.removeAll() }
}
public enum Paths {
    public static var support: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Gogaku", isDirectory: true) }
    public static var engineData: URL {
        if let path = ProcessInfo.processInfo.environment["GOGAKU_ENGINE_DATA"] { return URL(fileURLWithPath: path) }
        return Bundle.main.resourceURL!.appendingPathComponent("EngineData")
    }
}
