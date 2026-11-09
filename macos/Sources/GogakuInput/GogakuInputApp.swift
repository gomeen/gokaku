import AppKit
import InputMethodKit

@main struct GogakuInput {
    private static var server: IMKServer?
    #if GOGAKU_VALIDATION
    /// 验收诊断：直接追加写 /tmp/gogaku-diag.log（系统日志会脱敏 NSLog 内容）。
    static func diag(_ line: String) {
        let path = "/tmp/gogaku-diag.log"
        if let h = FileHandle(forWritingAtPath: path) {
            defer { h.closeFile() }
            h.seekToEndOfFile()
            h.write((line + "\n").data(using: .utf8)!)
        } else {
            try? (line + "\n").write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        }
    }
    #endif
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Registration belongs to installation; enabling belongs to the user's
        // system input-source settings. Re-enabling on every launch prompts for
        // permission again and can interrupt the active input context.
        // 连接名按 bundle ID 派生（2026-11-09 企业微信兼容发布中发现）：双通道
        // 安装共用硬编码名时，后启动的通道会被 imklaunchagent 以
        // “Refusing connection name for bundle: unrecognized
        // 'InputMethodConnectionName' value”拒绝——dev 选中即回弹、进程拉不起。
        let bundleID = Bundle.main.bundleIdentifier ?? "org.gogaku.inputmethod"
        server = IMKServer(name: bundleID + "_connection", bundleIdentifier: bundleID)
        #if GOGAKU_VALIDATION
        GogakuInput.diag("=== session start \(Date()) pid=\(ProcessInfo.processInfo.processIdentifier)")
        #endif
        DispatchQueue.main.async {
            CandidatePanel.shared.prime()
            #if GOGAKU_VALIDATION
            ValidationMonitor.shared.start()
            #endif
        }
        app.run()
    }
}
