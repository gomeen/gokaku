import Foundation
import AppKit

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
public struct Shortcut: Codable, Equatable {
    public var key: String
    public var modifiers: UInt
    public init(key: String, modifiers: UInt) { self.key = key; self.modifiers = modifiers }
}
public struct AppPreference: Codable {
    public var mode: InputMode = .normal
    public var direction: Direction = .zhToEn
    public init() {}
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
    public var appDefaultEnglish: [String] = defaultEnglishApps
    public var quickAddShortcut = Shortcut(key: "a", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
    public var quickAddExcludedApplications: Set<String> = []

    private enum CodingKeys: String, CodingKey {
        case recording, excludedApplications, ignoredWords, applications
        case modeShortcut, directionShortcut, candidateTheme
        case inputScheme, fuzzyPinyin, candidateFontSize, glossEnabled
        case inputLettersEnabled, fullPinyinPreedit, frequencyEnabled
        case englishCandidatesEnabled, appDefaultEnglish, quickAddShortcut
        case quickAddExcludedApplications
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
        appDefaultEnglish = try container.decodeIfPresent([String].self, forKey: .appDefaultEnglish) ?? defaultEnglishApps
        quickAddShortcut = try container.decodeIfPresent(Shortcut.self, forKey: .quickAddShortcut)
            ?? Shortcut(key: "a", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
        quickAddExcludedApplications = try container.decodeIfPresent(Set<String>.self, forKey: .quickAddExcludedApplications) ?? []
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
    public func save(at directory: URL = Paths.support) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("settings.json"), options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("org.gogaku.settings.changed"), object: nil, userInfo: nil, deliverImmediately: true)
    }
}
