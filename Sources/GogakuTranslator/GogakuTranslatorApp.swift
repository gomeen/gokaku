import Foundation
import Translation
import GogakuCore

@main struct Translator {
    static func pair(_ direction: Direction) -> (Locale.Language, Locale.Language) {
        direction == .zhToEn ? (Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en")) : (Locale.Language(identifier: "en"), Locale.Language(identifier: "zh-Hans"))
    }
    static func main() async {
        if CommandLine.arguments.contains("--spell") {
            while let data = readMessage() {
                guard let r = try? JSONDecoder().decode(TranslationRequest.self, from: data) else { continue }
                let valid = r.protocolVersion == 1 && r.stamp.mode == .learning && r.stamp.direction == .enToZh && r.source.unicodeScalars.count <= 512
                let issues = valid ? Spelling.check(r.source, ignored: Set(r.ignoredWords ?? [])) : []
                let result = TranslationResult(request: r, error: valid ? nil : "invalid_request", issues: issues)
                if let output = try? JSONEncoder().encode(result), output.count < 65_536 { FileHandle.standardOutput.write(output + Data([10])) }
            }
            return
        }
        let availability = LanguageAvailability()
        if CommandLine.arguments.contains("--status") {
            var status: [String: String] = ["os": ProcessInfo.processInfo.operatingSystemVersionString, "strategy": "systemDefault", "quality": "unreviewed"]
            for direction in Direction.allCases {
                let (source, target) = pair(direction)
                status[direction.rawValue] = String(describing: await availability.status(from: source, to: target))
            }
            if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) { FileHandle.standardOutput.write(data + Data([10])) }
            return
        }
        // 一次只运行一项；超时由父进程负责终止本进程，不持有宿主权限。
        while let data = readMessage() {
            guard let r = try? JSONDecoder().decode(TranslationRequest.self, from: data) else { continue }
            let start = ContinuousClock.now
            var result: TranslationResult
            if r.protocolVersion != 1 || r.source.isEmpty || r.source.unicodeScalars.count > 512 {
                result = TranslationResult(request: r, error: "invalid_request")
            } else {
                let (source, target) = pair(r.stamp.direction)
                let status = await availability.status(from: source, to: target)
                if status != .installed {
                    result = TranslationResult(request: r, error: "language_resources_not_installed")
                } else {
                    do {
                        // installedSource 不弹下载 UI；仅设置应用可以发起系统资源授权。
                        let session = TranslationSession(installedSource: source, target: target)
                        let translated = try await session.translate(r.source)
                        let duration = start.duration(to: .now)
                        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
                        result = TranslationResult(request: r, target: translated.targetText.isEmpty ? nil : translated.targetText, error: translated.targetText.isEmpty ? "empty_output" : nil, milliseconds: ms)
                    } catch { result = TranslationResult(request: r, error: "translation_failed") }
                }
            }
            if let output = try? JSONEncoder().encode(result), output.count < 65_536 { FileHandle.standardOutput.write(output + Data([10])) }
        }
    }
    static func readMessage() -> Data? {
        var data = Data(), oversized = false
        while let byte = try? FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 {
                if oversized { return Data() }
                return data
            }
            if data.count >= 65_535 { oversized = true } else if !oversized { data.append(byte) }
        }
        return nil
    }
}
