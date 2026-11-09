import AppKit
import InputMethodKit

@main struct GogakuInput {
    private static var server: IMKServer?
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
        DispatchQueue.main.async {
            CandidatePanel.shared.prime()
            #if GOGAKU_VALIDATION
            ValidationMonitor.shared.start()
            #endif
        }
        app.run()
    }
}
