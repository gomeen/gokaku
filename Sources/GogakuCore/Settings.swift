import Foundation
import AppKit

/// 可配置快捷键的规范绑定。
/// - `key` 是规范键标识（小写字母、数字、`f1`…`f19`、`return`、标点等），
///   平台层负责与 keyCode／生成字符互转，不进入共享核心 C ABI。
/// - `modifiers` 用 NSEvent.ModifierFlags rawValue，只取四修饰位。
/// - `disabled == true` 表示用户明确清除；旧格式缺省该字段时不等于清除。
public struct Shortcut: Codable, Equatable {
    public var key: String
    public var modifiers: UInt
    public var disabled: Bool

    public init(key: String, modifiers: UInt, disabled: Bool = false) {
        self.key = key
        self.modifiers = modifiers
        self.disabled = disabled
    }

    private enum CodingKeys: String, CodingKey { case key, modifiers, disabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        modifiers = try c.decode(UInt.self, forKey: .modifiers)
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(modifiers, forKey: .modifiers)
        // 默认不写 disabled 字段：旧二进制（无该字段解码）仍可读取。
        if disabled { try c.encode(true, forKey: .disabled) }
    }

    public var isValid: Bool { !disabled && !key.isEmpty && modifiers != 0 }
}

/// 按应用默认英文列表项：旧格式是 `[String]`（bundle id，全部启用），
/// 新格式带每项启用状态；关闭后仍保留该行。
public struct EnglishAppEntry: Codable, Equatable {
    public var id: String
    public var enabled: Bool
    public init(id: String, enabled: Bool = true) {
        self.id = id
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case id, enabled }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let legacy = try? container.decode(String.self) {
            self.init(id: legacy, enabled: true)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true)
    }

    public func encode(to encoder: Encoder) throws {
        // 启用中的条目输出旧格式纯字符串；只有停用条目才写对象形式，
        // 保证随包同建的旧二进制在未使用停用功能时仍可整文件解码。
        if enabled {
            var c = encoder.singleValueContainer()
            try c.encode(id)
        } else {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(enabled, forKey: .enabled)
        }
    }
}

public struct SpellingIssue: Equatable, Codable, Sendable {
    public let location: Int
    public let length: Int
    public let explanation: String
    public init(location: Int, length: Int, explanation: String) { self.location = location; self.length = length; self.explanation = explanation }
}
public enum Spelling {
    /// 在专用辅助进程调用，避免系统同步词典检查阻塞按键/UI。
    public static func check(_ text: String, ignored: Set<String>) -> [SpellingIssue] {
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"\S+"#) else { return [] }
        var result: [SpellingIssue] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range, token = ns.substring(with: range)
            let end = NSMaxRange(range)
            // 尾部纯字母仍在输入，不在每个字母上重复判错。
            if end == ns.length, token.last?.isLetter == true { continue }
            if token.contains("@") || token.contains("://") || token.contains("www.") || token.contains("_") || token.contains("/") || token.contains("=") || token.contains("`") || token.contains(".") && token.dropLast().contains(".") { continue }
            let cleaned = token.trimmingCharacters(in: .punctuationCharacters)
            if ignored.contains(cleaned.lowercased()) || cleaned.count <= 1 || cleaned.contains(where: { $0.isNumber }) { continue }
            // 专名/品牌/缩写采取保守免标记。
            if cleaned.first?.isUppercase == true || cleaned != cleaned.lowercased() { continue }
            let local = NSSpellChecker.shared.checkSpelling(of: cleaned, startingAt: 0, language: "en_US", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            guard local.location != NSNotFound else { continue }
            let offset = (token as NSString).range(of: cleaned).location
            if offset != NSNotFound {
                result.append(SpellingIssue(location: range.location + offset + local.location, length: local.length,
                                            explanation: "疑似拼写问题；词典未识别此表达，不代表一定错误。可继续输入或加入忽略词。"))
            }
        }
        return result
    }
}
public struct AppPreference: Codable {
    public var mode: InputMode = .normal
    public var direction: Direction = .zhToEn
    public init() {}
}

/// 快捷键配置命令。固定操作不在此列，仅用于冲突检查与展示。
public enum ConfigurableCommand: String, CaseIterable, Sendable {
    case modeSwitch = "gogaku.mode"
    case directionSwitch = "gogaku.direction"
    case quickAdd = "gogaku.quickAdd"

    public var displayName: String {
        switch self {
        case .modeSwitch: return "普通／学习"
        case .directionSwitch: return "学习方向"
        case .quickAdd: return "快速添加"
        }
    }

    public var detail: String {
        switch self {
        case .modeSwitch: return "切换中文输入与语言学习模式"
        case .directionSwitch: return "切换中文到英语、英语到中文"
        case .quickAdd: return "把最近上屏的中文存为拼音词"
        }
    }

    public func shortcut(in settings: Settings) -> Shortcut {
        switch self {
        case .modeSwitch: return settings.modeShortcut
        case .directionSwitch: return settings.directionShortcut
        case .quickAdd: return settings.quickAddShortcut
        }
    }

    public func setShortcut(_ shortcut: Shortcut, in settings: inout Settings) {
        switch self {
        case .modeSwitch: settings.modeShortcut = shortcut
        case .directionSwitch: settings.directionShortcut = shortcut
        case .quickAdd: settings.quickAddShortcut = shortcut
        }
    }

    public var defaultShortcut: Shortcut {
        switch self {
        case .modeSwitch: return Shortcut(key: "k", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
        case .directionSwitch: return Shortcut(key: "j", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
        case .quickAdd: return Shortcut(key: "a", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
        }
    }
}
public enum CandidateThemeID: String, Codable, Sendable {
    case rimeMacOSLike = "rime-macos-like"
}
/// 普通模式输入方案（共享核心 GcScheme）。
public enum InputScheme: String, Codable, Sendable {
    case xiaohe
    case fullPinyin
    /// 模糊音对，按共享核心 GC_FUZZY_* 位标志。
    public static let fuzzyPairs: [(id: String, mask: UInt32)] = [
        ("z-zh", 1 << 0), ("c-ch", 1 << 1), ("s-sh", 1 << 2),
        ("n-l", 1 << 3), ("f-h", 1 << 4), ("l-r", 1 << 5),
        ("an-ang", 1 << 6), ("en-eng", 1 << 7), ("in-ing", 1 << 8),
    ]
}
/// 按应用默认英文的出厂列表（规格表，2026-10-31 裁决）。
public let defaultEnglishApps = [
    "com.raycast.macos", "com.microsoft.VSCode", "md.obsidian",
    "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.mitchellh.ghostty",
    "dev.warp.Warp-Stable", "com.cmux.cmux", "app.otter.otty",
]

public struct Settings: Codable {
    public var recording = true
    public var excludedApplications: Set<String> = []
    public var ignoredWords: Set<String> = []
    public var applications: [String: AppPreference] = [:]
    public var modeShortcut = Shortcut(key: "k", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
    public var directionShortcut = Shortcut(key: "j", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
    /// A stable ID leaves the rendering layer open for user-selectable themes.
    public var candidateTheme: CandidateThemeID = .rimeMacOSLike
    // 普通模式（2026-10-31 输入习惯裁决）。
    public var inputScheme: InputScheme = .xiaohe
    public var fuzzyPinyin: Set<String> = []                       // 默认全关
    public var candidateFontSize: Int = 14                         // 12–16
    public var glossEnabled = true                                 // 英文释义注释
    public var inputLettersEnabled = true                          // 输入区字母（marked text）
    public var fullPinyinPreedit = true                            // ni'hao / nihc
    public var frequencyEnabled = true                             // 中文调频
    public var englishCandidatesEnabled = true
    /// 按应用默认英文：新格式带启用状态；计算属性输出启用中的 bundle id。
    public var appDefaultEnglish: [EnglishAppEntry] = defaultEnglishApps.map { EnglishAppEntry(id: $0) }
    public var quickAddShortcut = Shortcut(key: "a", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
    public var quickAddExcludedApplications: Set<String> = []
    /// 学习翻译（quickmt 开发版，2026-11 裁决 docs/learning-quickmt-dev-decision.md）：
    /// 默认开启；关闭即回门禁态（菜单置灰、会话释放、正式口径不变）。
    public var learningTranslationEnabled = true
    /// quickmt beam（1–10，默认 1）；变更销毁重建辅助进程后生效。
    public var learningBeamSize = LearningTranslation.defaultBeam
    /// 学习翻译后端（"quickmt" 默认｜"small100"）；仅换模型，功能层不变。
    public var learningTranslationBackend = LearningTranslation.defaultBackend

    private enum CodingKeys: String, CodingKey {
        case recording, excludedApplications, ignoredWords, applications
        case modeShortcut, directionShortcut, candidateTheme
        case inputScheme, fuzzyPinyin, candidateFontSize, glossEnabled
        case inputLettersEnabled, fullPinyinPreedit, frequencyEnabled
        case englishCandidatesEnabled, appDefaultEnglish, quickAddShortcut
        case quickAddExcludedApplications
        case learningTranslationEnabled, learningBeamSize, learningTranslationBackend
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recording = try container.decodeIfPresent(Bool.self, forKey: .recording) ?? true
        excludedApplications = try container.decodeIfPresent(Set<String>.self, forKey: .excludedApplications) ?? []
        ignoredWords = try container.decodeIfPresent(Set<String>.self, forKey: .ignoredWords) ?? []
        applications = try container.decodeIfPresent([String: AppPreference].self, forKey: .applications) ?? [:]
        modeShortcut = try container.decodeIfPresent(Shortcut.self, forKey: .modeShortcut)
            ?? Shortcut(key: "k", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
        directionShortcut = try container.decodeIfPresent(Shortcut.self, forKey: .directionShortcut)
            ?? Shortcut(key: "j", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
        // Unknown theme IDs (renamed or removed) fall back to the default
        // instead of invalidating the whole settings file.
        let themeRaw = try container.decodeIfPresent(String.self, forKey: .candidateTheme)
        candidateTheme = themeRaw.flatMap(CandidateThemeID.init(rawValue:)) ?? .rimeMacOSLike
        inputScheme = try container.decodeIfPresent(InputScheme.self, forKey: .inputScheme) ?? .xiaohe
        fuzzyPinyin = try container.decodeIfPresent(Set<String>.self, forKey: .fuzzyPinyin) ?? []
        candidateFontSize = min(16, max(12, try container.decodeIfPresent(Int.self, forKey: .candidateFontSize) ?? 14))
        glossEnabled = try container.decodeIfPresent(Bool.self, forKey: .glossEnabled) ?? true
        inputLettersEnabled = try container.decodeIfPresent(Bool.self, forKey: .inputLettersEnabled) ?? true
        fullPinyinPreedit = try container.decodeIfPresent(Bool.self, forKey: .fullPinyinPreedit) ?? true
        frequencyEnabled = try container.decodeIfPresent(Bool.self, forKey: .frequencyEnabled) ?? true
        englishCandidatesEnabled = try container.decodeIfPresent(Bool.self, forKey: .englishCandidatesEnabled) ?? true
        if let legacy = try? container.decode([String].self, forKey: .appDefaultEnglish) {
            appDefaultEnglish = legacy.map { EnglishAppEntry(id: $0, enabled: true) }
        } else {
            appDefaultEnglish = try container.decodeIfPresent([EnglishAppEntry].self, forKey: .appDefaultEnglish)
                ?? defaultEnglishApps.map { EnglishAppEntry(id: $0) }
        }
        quickAddShortcut = try container.decodeIfPresent(Shortcut.self, forKey: .quickAddShortcut)
            ?? Shortcut(key: "a", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
        quickAddExcludedApplications = try container.decodeIfPresent(Set<String>.self, forKey: .quickAddExcludedApplications) ?? []
        learningTranslationEnabled = try container.decodeIfPresent(Bool.self, forKey: .learningTranslationEnabled) ?? true
        learningBeamSize = LearningTranslation.clampedBeam(
            try container.decodeIfPresent(Int.self, forKey: .learningBeamSize) ?? LearningTranslation.defaultBeam)
        learningTranslationBackend = LearningTranslation.normalizedBackend(
            try container.decodeIfPresent(String.self, forKey: .learningTranslationBackend))
    }

    /// 输入法使用的启用中的按应用默认英文 bundle id 列表。
    public var enabledDefaultEnglishApps: [String] {
        appDefaultEnglish.filter(\.enabled).map(\.id)
    }

    /// 模糊音位标志（与共享核心 GC_FUZZY_* 一致）。
    public var fuzzyMask: UInt32 {
        var mask: UInt32 = 0
        for (id, bit) in InputScheme.fuzzyPairs where fuzzyPinyin.contains(id) { mask |= bit }
        return mask
    }

    /// 共享核心用户数据目录（调频与已学习词）。
    public static var chineseDirectory: URL { Paths.support.appendingPathComponent("chinese", isDirectory: true) }
    public static var customWordsPath: URL { Paths.support.appendingPathComponent("custom-words.tsv") }

    public static func load(at directory: URL = Paths.support) -> Settings {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")), let value = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return value
    }

    /// 原子写入，不发送变更通知（通知由 SettingsStore 在成功落盘后发送，
    /// 避免失败时伪报成功）。文件权限仅当前用户可读写。
    public func save(at directory: URL = Paths.support) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("settings.json"), options: .atomic)
    }
}
