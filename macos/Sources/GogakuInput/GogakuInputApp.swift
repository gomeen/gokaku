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
        server = IMKServer(name: "Gogaku_Connection", bundleIdentifier: Bundle.main.bundleIdentifier)
        DispatchQueue.main.async {
            CandidatePanel.shared.prime()
            #if GOGAKU_VALIDATION
            ValidationMonitor.shared.start()
            #endif
        }
        app.run()
    }
}
