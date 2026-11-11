import AppKit
import SwiftUI
import GogakuKit

/// 窗口关闭与应用退出分别由 AppKit 回调；不替换或吞掉原窗口代理的其他行为。
final class SettingsAppDelegate: NSObject, NSApplicationDelegate {
    static weak var editor: SkinEditorSession?
    /// 已在等落盘完成；期间再次请求退出时继续等待，不重复启动落盘。
    private var awaitingFlush = false
    /// 兜底：落盘回调或超时后只回复一次，不重复 reply。
    private var replySent = false

    /// 设置应用只服务设置窗口：最后一个窗口关闭即退出，不在 Dock 常驻
    /// （曾是长时间挂 Dock 的缺陷来源，2026-11-11 修复）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let editor = Self.editor, !editor.mayLeave() { return .terminateCancel }
        guard !awaitingFlush else { return .terminateLater }
        // 关窗到退出之间仍可能有 300ms 合并中的文本改动：先落盘再终止，
        // 落盘完成前不退出，避免最后几个字丢失；2 秒兜底保证退出不会卡死。
        awaitingFlush = true
        SettingsStore.shared.flushForTermination { [weak self] in
            self?.replyTermination(sender)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.replyTermination(sender)
        }
        return .terminateLater
    }

    private func replyTermination(_ sender: NSApplication) {
        guard !replySent else { return }
        replySent = true
        Self.editor?.discard()
        sender.reply(toApplicationShouldTerminate: true)
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
