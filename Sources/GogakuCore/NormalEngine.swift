import Foundation
import CGogakuCore

/// 共享 C++ 普通模式核心的 Swift 薄封装。
/// 会话由一个串行队列拥有（输入法主队列）；不向 UI 暴露 C 指针。
public struct NormalCandidate: Equatable, Sendable {
    public let text: String
    public let gloss: String
    public let kind: Int32
    public let deletable: Bool
    public let completes: Bool
    init(_ raw: GcCandidate) {
        text = String(cString: raw.text)
        gloss = String(cString: raw.gloss)
        kind = raw.kind
        deletable = raw.deletable != 0
        completes = raw.completes != 0
    }
}

public struct NormalSnapshot: Sendable {
    public let rawInput: String        // 原始编码；草稿恢复不用展开拼音
    public let commit: String          // 一次上屏文本；空 = 无提交
    public let marked: String          // 宿主 marked text；空 = 清除
    public let preedit: String         // 候选窗预编辑行
    public let preeditCaret: Int       // 字节偏移；-1 无
    public let typedPrefixLen: Int     // 预编辑开头已暂存中文的标量个数；0 = 无
    public let consumed: Bool          // false = 平台交给宿主
    public let composing: Bool
    public let english: Int            // 0 中文 1 手动临时英文 2 按应用默认英文
    public let toast: Int              // 0 无 1 中 2 英
    public let beep: Bool
    public let status: String
    public let candidates: [NormalCandidate]
    public let selected: Int
    public let page: Int
    public let pageCount: Int
    public let total: Int
}

/// 普通模式会话配置；字段与 GcNormalConfig 一一对应。
public struct NormalEngineConfig: Sendable {
    public var dictPath: String
    public var modelPath: String
    public var userDir: String?
    public var customWordsPath: String?
    public var englishWordsPath: String?
    public var glossPath: String?
    public var scheme: Int32 = Int32(GC_SCHEME_XIAOHE.rawValue)
    public var fuzzyMask: UInt32 = 0
    public var fullPinyinPreedit: Bool = true
    public var freqEnabled: Bool = true
    public var englishEnabled: Bool = true
    public init(dictPath: String, modelPath: String) {
        self.dictPath = dictPath
        self.modelPath = modelPath
    }
}

public enum NormalEvent {
    case text(String)
    case space, enter, esc
    case backspace, deleteWord
    case left, right, up, down, home, end, pageUp, pageDown
    case ctrlA, ctrlB, ctrlE, ctrlF, ctrlN, ctrlP
    case shiftClick(side: Int64)
    case quickAdd
    case focusSync
}

public final class NormalEngine {
    private var session: OpaquePointer?
    public let creationError: String?   // 创建时的非致命问题（如词库损坏已备份）

    public init?(config: NormalEngineConfig) {
        var c = GcNormalConfig()
        let dictCopy = config.dictPath.unsafeConstUTF8Copy()
        let modelCopy = config.modelPath.unsafeConstUTF8Copy()
        let userCopy = config.userDir?.unsafeConstUTF8Copy()
        let customCopy = config.customWordsPath?.unsafeConstUTF8Copy()
        let englishCopy = config.englishWordsPath?.unsafeConstUTF8Copy()
        let glossCopy = config.glossPath?.unsafeConstUTF8Copy()
        var err = [CChar](repeating: 0, count: 256)
        defer {
            freeConst(dictCopy); freeConst(modelCopy); freeConst(userCopy)
            freeConst(customCopy); freeConst(englishCopy); freeConst(glossCopy)
        }
        c.dict_path = dictCopy
        c.model_path = modelCopy
        c.user_dir = userCopy
        c.custom_words_path = customCopy
        c.english_words_path = englishCopy
        c.gloss_path = glossCopy
        c.scheme = Int32(config.scheme)
        c.fuzzy_mask = config.fuzzyMask
        c.full_pinyin_preedit = config.fullPinyinPreedit ? 1 : 0
        c.freq_enabled = config.freqEnabled ? 1 : 0
        c.english_enabled = config.englishEnabled ? 1 : 0
        var session: OpaquePointer?
        let rc = gc_normal_session_create(&c, &session, &err, err.count)
        guard rc == 0, let session else { return nil }
        self.session = session
        let message = String(cString: err)
        creationError = message.isEmpty ? nil : message
    }

    deinit {
        if let session { gc_normal_session_destroy(session) }
    }

    public func handle(_ event: NormalEvent, app: String, field: String, timeMs: Int64) -> NormalSnapshot? {
        guard let session else { return nil }
        var ev = GcKeyEvent()
        let appCopy = app.unsafeConstUTF8Copy()
        let fieldCopy = field.unsafeConstUTF8Copy()
        var textCopy: UnsafePointer<CChar>!
        defer {
            freeConst(appCopy); freeConst(fieldCopy); freeConst(textCopy)
        }
        ev.app = appCopy
        ev.field = fieldCopy
        ev.time_ms = timeMs
        switch event {
        case .text(let value):
            textCopy = value.unsafeConstUTF8Copy()
            ev.text = textCopy
            ev.kind = Int32(GC_EV_TEXT.rawValue)
        case .space: ev.kind = Int32(GC_EV_SPACE.rawValue)
        case .enter: ev.kind = Int32(GC_EV_ENTER.rawValue)
        case .esc: ev.kind = Int32(GC_EV_ESC.rawValue)
        case .backspace: ev.kind = Int32(GC_EV_BACKSPACE.rawValue)
        case .deleteWord: ev.kind = Int32(GC_EV_DELETE_WORD.rawValue)
        case .left: ev.kind = Int32(GC_EV_LEFT.rawValue)
        case .right: ev.kind = Int32(GC_EV_RIGHT.rawValue)
        case .up: ev.kind = Int32(GC_EV_UP.rawValue)
        case .down: ev.kind = Int32(GC_EV_DOWN.rawValue)
        case .home: ev.kind = Int32(GC_EV_HOME.rawValue)
        case .end: ev.kind = Int32(GC_EV_END.rawValue)
        case .pageUp: ev.kind = Int32(GC_EV_PAGE_UP.rawValue)
        case .pageDown: ev.kind = Int32(GC_EV_PAGE_DOWN.rawValue)
        case .ctrlA: ev.kind = Int32(GC_EV_CTRL_A.rawValue)
        case .ctrlB: ev.kind = Int32(GC_EV_CTRL_B.rawValue)
        case .ctrlE: ev.kind = Int32(GC_EV_CTRL_E.rawValue)
        case .ctrlF: ev.kind = Int32(GC_EV_CTRL_F.rawValue)
        case .ctrlN: ev.kind = Int32(GC_EV_CTRL_N.rawValue)
        case .ctrlP: ev.kind = Int32(GC_EV_CTRL_P.rawValue)
        case .shiftClick(let side):
            ev.kind = Int32(GC_EV_SHIFT_CLICK.rawValue)
            ev.arg = Int64(side)
        case .quickAdd: ev.kind = Int32(GC_EV_QUICK_ADD.rawValue)
        case .focusSync: ev.kind = Int32(GC_EV_FOCUS_SYNC.rawValue)
        }
        var snapshot: UnsafeMutablePointer<GcSnapshot>?
        guard gc_normal_handle(session, &ev, &snapshot) == 0, let snapshot else { return nil }
        defer { gc_snapshot_free(snapshot) }
        let raw = snapshot.pointee
        var candidates: [NormalCandidate] = []
        if let items = raw.candidates {
            for i in 0..<raw.count {
                candidates.append(NormalCandidate(items[i]))
            }
        }
        let commit = raw.commit != nil ? String(cString: raw.commit) : ""
        let marked = raw.marked != nil ? String(cString: raw.marked) : ""
        let preedit = raw.preedit != nil ? String(cString: raw.preedit) : ""
        let status = raw.status != nil ? String(cString: raw.status) : ""
        var input = [CChar](repeating: 0, count: 128)
        let required = gc_normal_copy_raw(session, &input, input.count)
        if required > input.count {
            input = [CChar](repeating: 0, count: required)
            _ = gc_normal_copy_raw(session, &input, input.count)
        }
        return NormalSnapshot(
            rawInput: required > 0 ? String(cString: input) : "",
            commit: commit,
            marked: marked,
            preedit: preedit,
            preeditCaret: Int(raw.preedit_caret),
            typedPrefixLen: Int(raw.typed_prefix_len),
            consumed: raw.consumed != 0,
            composing: raw.composing != 0,
            english: Int(raw.english),
            toast: Int(raw.toast),
            beep: raw.beep != 0,
            status: status,
            candidates: candidates,
            selected: Int(raw.selected),
            page: Int(raw.page),
            pageCount: Int(raw.page_count),
            total: Int(raw.total))
    }

    /// 显式恢复中文编码：默认英文或临时英文先转回中文，再按同一字段重放。
    public func restoreRawInput(_ raw: String, app: String, field: String, timeMs: Int64) -> NormalSnapshot? {
        guard var snapshot = handle(.focusSync, app: app, field: field, timeMs: timeMs) else { return nil }
        for _ in 0..<2 {
            if snapshot.english == 0 { break }
            guard let chinese = handle(.shiftClick(side: 0), app: app, field: field, timeMs: timeMs) else { return nil }
            snapshot = chinese
        }
        guard snapshot.english == 0 else { return nil }
        for scalar in raw.unicodeScalars {
            guard let next = handle(.text(String(scalar)), app: app, field: field, timeMs: timeMs) else { return nil }
            snapshot = next
        }
        return snapshot
    }

    public func setAppDefaults(_ apps: [String]) {
        // 复查 F1：空数组＝清空列表，必须下发（否则共享引擎残留旧列表）。
        guard let session else { return }
        if apps.isEmpty {
            var dummy: [UnsafePointer<CChar>?] = [nil]
            gc_normal_set_app_defaults(session, &dummy, 0)
            return
        }
        let copies = apps.map { $0.unsafeConstUTF8Copy() }
        defer { copies.forEach { freeConst($0) } }
        var pointers: [UnsafePointer<CChar>?] = copies.map { $0 }
        gc_normal_set_app_defaults(session, &pointers, apps.count)
    }

    public func setExcludedApps(_ apps: [String]) {
        guard let session else { return }
        if apps.isEmpty {
            var dummy: [UnsafePointer<CChar>?] = [nil]
            gc_normal_set_excluded_apps(session, &dummy, 0)
            return
        }
        let copies = apps.map { $0.unsafeConstUTF8Copy() }
        defer { copies.forEach { freeConst($0) } }
        var pointers: [UnsafePointer<CChar>?] = copies.map { $0 }
        gc_normal_set_excluded_apps(session, &pointers, apps.count)
    }

    public func update(scheme: Int32, fuzzyMask: UInt32, fullPinyinPreedit: Bool, freqEnabled: Bool) {
        guard let session else { return }
        gc_normal_update(session, scheme, fuzzyMask, fullPinyinPreedit ? 1 : 0, freqEnabled ? 1 : 0)
    }

    @discardableResult
    public func reloadCustomWords() -> Bool {
        guard let session else { return false }
        return gc_normal_reload_custom_words(session) == 0
    }

    @discardableResult
    public func flush() -> Bool {
        guard let session else { return false }
        return gc_normal_flush(session) == 0
    }

    public var quickAddAvailable: Bool {
        guard let session else { return false }
        return gc_normal_quick_add_available(session) != 0
    }
}

/// 设置进程使用的自定义词语管理（读写 custom-words.tsv 与自动读音）。
public struct CustomWord: Equatable, Sendable {
    public var kind: Int32      // GC_WORD_SHORTCODE / GC_WORD_PINYIN
    public var enabled: Bool
    public var code: String
    public var pinyin: String
    public var content: String
    public init(kind: Int32, enabled: Bool, code: String, pinyin: String, content: String) {
        self.kind = kind
        self.enabled = enabled
        self.code = code
        self.pinyin = pinyin
        self.content = content
    }
}

public enum CustomWordStore {
    public static func read(path: String) -> (words: [CustomWord], corrupt: Bool)? {
        var list: UnsafeMutablePointer<GcCustomWordList>?
        guard gc_custom_words_read(path, &list) == 0, let list else { return nil }
        defer { gc_custom_word_list_free(list) }
        let raw = list.pointee
        var words: [CustomWord] = []
        if let items = raw.words {
            for i in 0..<raw.count {
                let w = items[i]
                words.append(CustomWord(kind: w.kind, enabled: w.enabled != 0,
                                        code: String(cString: w.code),
                                        pinyin: String(cString: w.pinyin),
                                        content: String(cString: w.content)))
            }
        }
        return (words, raw.corrupt != 0)
    }

    /// 修复损坏标记：损坏时用 .corrupt 备份的内容继续（设置页提示后可保存回主文件）。
    public static func readRecoveringCorrupt(path: String) -> (words: [CustomWord], corrupt: Bool) {
        if let result = read(path: path) {
            if !result.corrupt { return result }
            // 损坏主文件已被核心备份为 .corrupt 并置空；尝试从备份恢复可读内容。
            if let backup = read(path: path + ".corrupt"), !backup.corrupt {
                return (backup.words, true)
            }
        }
        return ([], false)
    }

    public static func write(path: String, words: [CustomWord]) -> Bool {
        var items: [GcCustomWord] = words.map { w in
            var item = GcCustomWord()
            item.kind = w.kind
            item.enabled = w.enabled ? 1 : 0
            item.code = w.code.unsafeUTF8Copy()
            item.pinyin = w.pinyin.unsafeUTF8Copy()
            item.content = w.content.unsafeUTF8Copy()
            return item
        }
        defer { for i in items.indices { items[i].freeStrings() } }
        return items.withUnsafeMutableBufferPointer { buffer in
            var list = GcCustomWordList()
            list.words = buffer.baseAddress
            list.count = buffer.count
            return gc_custom_words_write(path, &list) == 0
        }
    }

    /// 校验单条词条；返回 nil 表示合法，否则为具体原因。
    public static func validate(kind: Int32, code: String, pinyin: String, content: String) -> String? {
        var err = [CChar](repeating: 0, count: 128)
        let rc = gc_custom_words_validate(kind, code, pinyin, content, &err, err.count)
        guard rc != 0 else { return nil }
        return String(cString: err)
    }

    /// 用 libime 出厂词典给出每字常用读音（撇号分隔全拼）。
    public static func autoPinyin(dictPath: String, hanzi: String) -> String? {
        var out: UnsafeMutablePointer<CChar>?
        guard gc_custom_pinyin_lookup(dictPath, hanzi, &out) == 0, let out else { return nil }
        defer { free(out) }
        return String(cString: out)
    }
}

extension String {
    /// malloc 一份以 NUL 结尾的 UTF-8 拷贝（供 C 结构体持有）。
    func unsafeUTF8Copy() -> UnsafeMutablePointer<CChar>! {
        let bytes = Array(utf8CString)
        let count = bytes.count
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: count)
        bytes.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                memcpy(buffer, base, count)
            } else {
                buffer.pointee = 0
            }
        }
        return buffer
    }

    /// const 字段用拷贝；释放仍由调用方对同一指针 free。
    func unsafeConstUTF8Copy() -> UnsafePointer<CChar>! {
        UnsafePointer(unsafeUTF8Copy())
    }
}

func freeConst(_ p: UnsafePointer<CChar>!) {
    free(UnsafeMutablePointer(mutating: p))
}

extension GcCustomWord {
    mutating func freeStrings() {
        free(code); free(pinyin); free(content)
        code = nil; pinyin = nil; content = nil
    }
}
