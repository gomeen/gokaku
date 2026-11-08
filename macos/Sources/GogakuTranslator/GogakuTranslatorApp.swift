import Foundation
import GogakuKit
import Darwin

/// 随包辅助进程：拼写检查与火山翻译。两者都只通过 stdio JSON 行协议与父进程
/// 通信；无端口、无文本日志、不持有宿主写入权限。
///
/// 2026-11-06 起移除 Apple Translation 与本地模型路径：设置页不再安装语言包，
/// 学习翻译只经火山 NMT（`--volcengine --credentials <path>`）。
@main struct Translator {
    static func main() async {
        if CommandLine.arguments.contains("--spell") {
            spellLoop()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--volcengine") {
            let arguments = CommandLine.arguments
            guard let credentialsIndex = arguments.firstIndex(of: "--credentials"),
                  arguments.index(after: credentialsIndex) < arguments.endIndex else {
                FileHandle.standardError.write(Data("missing --credentials\n".utf8))
                return
            }
            let credentials = URL(fileURLWithPath: arguments[arguments.index(after: credentialsIndex)])
            _ = index
            await volcengineLoop(credentials: credentials)
            return
        }
        // 没有已知模式时不以退出码 0 假装成功；父进程按 service_exited 处理。
        FileHandle.standardError.write(Data("unknown mode\n".utf8))
        exit(2)
    }

    // MARK: - 拼写（NSSpellChecker，独立进程避免阻塞按键/UI）

    static func spellLoop() {
        while let data = readMessage() {
            guard let r = try? JSONDecoder().decode(TranslationRequest.self, from: data) else { continue }
            let valid = r.protocolVersion == 1 && r.stamp.mode == .learning
                && r.stamp.direction == .enToZh && r.source.unicodeScalars.count <= 512
            let issues = valid ? Spelling.check(r.source, ignored: Set(r.ignoredWords ?? [])) : []
            let result = TranslationResult(request: r, error: valid ? nil : "invalid_request", issues: issues)
            emit(result)
        }
    }

    // MARK: - 火山翻译（签名＋TLS 全部在辅助进程内）

    static func volcengineLoop(credentials: URL) async {
        let client = VolcengineClient(credentialsPath: credentials)
        while let data = readMessage() {
            guard let request = try? JSONDecoder().decode(TranslationRequest.self, from: data) else {
                continue
            }
            let started = DispatchTime.now().uptimeNanoseconds
            guard request.protocolVersion == 1,
                  request.stamp.mode == .learning,
                  !request.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  request.source.unicodeScalars.count <= 512 else {
                emit(TranslationResult(request: request, error: "invalid_request"))
                continue
            }
            do {
                let translated = try await client.translate(source: request.source,
                                                            direction: request.stamp.direction)
                emit(TranslationResult(request: request,
                                       target: translated.target,
                                       milliseconds: translated.milliseconds,
                                       characters: translated.characters))
            } catch {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
                emit(TranslationResult(request: request,
                                       error: LearningTranslation.errorCode(for: error),
                                       milliseconds: elapsed))
            }
        }
    }

    static func emit(_ result: TranslationResult) {
        guard let output = try? JSONEncoder().encode(result), output.count < 65_536 else { return }
        FileHandle.standardOutput.write(output + Data([10]))
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
