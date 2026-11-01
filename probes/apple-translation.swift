import Foundation
import Translation

struct TranslationCase: Encodable {
    let source: String
    let target: String?
    let error: String?
}

struct DirectionResult: Encodable {
    let direction: String
    let availability: String
    let cases: [TranslationCase]
}

@main
struct TranslationProbe {
    static func main() async throws {
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        let pairs = [("en", "zh-Hans", ["meeting", "metting", "I have a meeting tomorrow."]), ("zh-Hans", "en", ["会议", "开会", "我明天有个会。"])]
        var results: [DirectionResult] = []
        for (from, to, samples) in pairs {
            let source = Locale.Language(identifier: from)
            let target = Locale.Language(identifier: to)
            let status = await availability.status(from: source, to: target)
            var cases: [TranslationCase] = []
            if status == .installed {
                let session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
                for sample in samples {
                    do {
                        let response = try await session.translate(sample)
                        cases.append(TranslationCase(source: sample, target: response.targetText, error: nil))
                    } catch {
                        cases.append(TranslationCase(source: sample, target: nil, error: String(describing: error)))
                    }
                }
            }
            results.append(DirectionResult(direction: "\(from)->\(to)", availability: String(describing: status), cases: cases))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(results), as: UTF8.self))
    }
}
