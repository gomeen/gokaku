import AppKit
import SwiftUI

/// 窗口关闭与应用退出分别由 AppKit 回调；不替换或吞掉原窗口代理的其他行为。
final class SettingsAppDelegate: NSObject, NSApplicationDelegate {
    static weak var editor: SkinEditorSession?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let editor = Self.editor else { return .terminateNow }
        guard editor.mayLeave() else { return .terminateCancel }
        editor.discard()
        return .terminateNow
    }
}

struct SkinWindowGuard: NSViewRepresentable {
    let editor: SkinEditorSession
    func makeNSView(context: Context) -> GuardView { GuardView(editor: editor) }
    func updateNSView(_ view: GuardView, context: Context) { view.install() }
    static func dismantleNSView(_ view: GuardView, coordinator: ()) { view.uninstall() }

    final class GuardView: NSView {
        let proxy: WindowDelegate
        weak var installedWindow: NSWindow?
        init(editor: SkinEditorSession) { proxy = WindowDelegate(editor: editor); super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        func install() {
            guard let window, installedWindow !== window || window.delegate !== proxy else { return }
            uninstall()
            proxy.previous = window.delegate
            installedWindow = window
            window.delegate = proxy
        }
        func uninstall() {
            if let window = installedWindow, window.delegate === proxy { window.delegate = proxy.previous }
            installedWindow = nil
        }
    }
    final class WindowDelegate: NSObject, NSWindowDelegate {
        weak var previous: NSWindowDelegate?
        let editor: SkinEditorSession
        init(editor: SkinEditorSession) { self.editor = editor }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard previous?.windowShouldClose?(sender) ?? true, editor.mayLeave() else { return false }
            editor.discard()
            return true
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (previous?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previous?.responds(to: selector) == true { return previous }
            return super.forwardingTarget(for: selector)
        }
    }
}
