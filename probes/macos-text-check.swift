import AppKit
import Foundation

struct TextCheckResult: Encodable {
    let text: String
    let spellingFlags: [String]
    let grammarSentence: String?
    let grammarDetails: String
}

struct ProbeReport: Encodable {
    let platform: String
    let language: String
    let cases: [TextCheckResult]
    let nativeSpellingAttributeVerified: Bool
    let limitations: [String]
}

let checker = NSSpellChecker.shared
let tag = NSSpellChecker.uniqueSpellDocumentTag()
let texts = [
    "meeting", "metting", "meeetingg", "tomorrow", "Gogaku", "OpenAI",
    "I have a meeting tomorrow.", "I have a metting tomorrow.",
    "He go to work.", "He goes to work.", "She have a meeting.",
    "I has an apple.", "https://example.com", "foo@example.com"
]
var results: [TextCheckResult] = []
for text in texts {
    let string = text as NSString
    var flags: [String] = []
    var offset = 0
    while offset < string.length {
        let range = checker.checkSpelling(of: text, startingAt: offset, language: "en_US", wrap: false, inSpellDocumentWithTag: tag, wordCount: nil)
        if range.location == NSNotFound || range.length == 0 { break }
        flags.append(string.substring(with: range))
        offset = NSMaxRange(range)
    }
    var details: NSArray?
    let grammar = checker.checkGrammar(of: text, startingAt: 0, language: "en_US", wrap: false, inSpellDocumentWithTag: tag, details: &details)
    results.append(TextCheckResult(text: text, spellingFlags: flags, grammarSentence: grammar.location == NSNotFound ? nil : string.substring(with: grammar), grammarDetails: details.map { String(describing: $0) } ?? "none"))
}
checker.closeSpellDocument(withTag: tag)

let storage = NSTextStorage()
let layout = NSLayoutManager()
storage.addLayoutManager(layout)
let container = NSTextContainer(size: NSSize(width: 400, height: 100))
layout.addTextContainer(container)
let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100), textContainer: container)
view.isAutomaticSpellingCorrectionEnabled = false
view.isContinuousSpellCheckingEnabled = false
view.string = "I have a metting tomorrow."
let wordRange = (view.string as NSString).range(of: "metting")
view.setSpellingState(1, range: wordRange)
let flag = view.layoutManager?.temporaryAttribute(.spellingState, atCharacterIndex: wordRange.location, effectiveRange: nil) as? Int
let report = ProbeReport(platform: ProcessInfo.processInfo.operatingSystemVersionString, language: "en_US", cases: results, nativeSpellingAttributeVerified: flag == 1, limitations: [
    "Uses synthetic text only; does not learn words or edit input-method settings.",
    "No whole-machine network disconnection was performed; this is not proof of an offline distribution contract.",
    "The text-view probe verifies the spelling attribute, not on-screen rendering or host-application compatibility.",
    "Spelling and grammar flags do not establish translation quality."
])
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(decoding: try encoder.encode(report), as: UTF8.self))
