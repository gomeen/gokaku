import SwiftUI
import AppKit
import GogakuCore

/// VS Code 式快捷键表格的单行编辑器：按键帽显示、窗口内事件捕获录制、
/// 清除、恢复默认。冲突草稿只在界面上提示，不替换最后有效绑定。
struct ShortcutEditor: View {
    let command: ConfigurableCommand
    @Binding var shortcut: Shortcut
    let settings: GogakuCore.Settings
    /// 提交回调（父级负责立即保存与冲突筛选状态刷新；绑定 set 已提交时可省略）。
    var onChange: ((Shortcut) -> Void)? = nil
    /// 冲突提示（父级由当前设置计算；录制产生的冲突仅提示不写入）。
    var conflictName: String = ""

    @State private var recording = false
    @State private var recordingModifiers: UInt = 0
    @State private var hint = ""
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            if recording {
                recordingView
            } else {
                keycaps
                if !conflictName.isEmpty {
                    Text("与「\(conflictName)」冲突").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            if !hint.isEmpty {
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .onDisappear { stopRecording() }
    }

    @ViewBuilder private var keycaps: some View {
        if !shortcut.isValid {
            Text("—").foregroundStyle(.tertiary).font(.system(size: 12))
                .accessibilityLabel("\(command.displayName)快捷键未设置")
        } else {
            HStack(spacing: 3) {
                ForEach(caps, id: \.self) { cap in
                    Text(cap).font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(command.displayName)快捷键：\(shortcutDisplay)")
        }
    }

    private var shortcutDisplay: String { shortcut.isValid ? KeyCombo(shortcut: shortcut)?.displayText ?? "" : "未设置" }

    private var caps: [String] {
        guard let combo = KeyCombo(shortcut: shortcut) else { return [] }
        var result: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: combo.modifiers)
        if flags.contains(.control) { result.append("⌃") }
        if flags.contains(.option) { result.append("⌥") }
        if flags.contains(.shift) { result.append("⇧") }
        if flags.contains(.command) { result.append("⌘") }
        let label = KeyCombo.keyLabels[combo.keyID]
            ?? (combo.keyID.count == 1 ? combo.keyID.uppercased() : combo.keyID)
        result.append(label)
        return result
    }

    @ViewBuilder private var recordingView: some View {
        HStack(spacing: 3) {
            Text(KeyCombo.modifierSymbols(recordingModifiers).isEmpty ? "请按下快捷键…" : KeyCombo.modifierSymbols(recordingModifiers))
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(SettingsPalette.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在录制\(command.displayName)快捷键；按 Escape 取消，Delete 清除")
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 4) {
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Image(systemName: recording ? "xmark" : "pencil").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(recording ? "取消录制\(command.displayName)快捷键" : "编辑「\(command.displayName)」的快捷键")
            Button {
                clear()
            } label: {
                Image(systemName: "minus").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("清除「\(command.displayName)」的快捷键")
            Button {
                onChange?(command.defaultShortcut)
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(shortcut == command.defaultShortcut)
            .accessibilityLabel("恢复「\(command.displayName)」的默认快捷键")
        }
    }

    // MARK: - 录制（设置窗口内事件捕获）

    private func startRecording() {
        hint = ""
        recording = true
        recordingModifiers = 0
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handleRecordEvent(event)
            return nil   // 录制期间吞掉按键，不进入任何控件
        }
    }

    private func stopRecording() {
        recording = false
        recordingModifiers = 0
        if let monitor { NSEvent.removeMonitor(monitor) }
        self.monitor = nil
    }

    private func handleRecordEvent(_ event: NSEvent) {
        let bare = event.modifierFlags.intersection(NSEvent.ModifierFlags(rawValue: KeyCombo.modifierMask)).rawValue == 0
        if event.type == .flagsChanged {
            if bare {
                // 所有修饰键都松开：重置显示；单独修饰键不构成快捷键。
                recordingModifiers = 0
            } else {
                recordingModifiers = event.modifierFlags.intersection(NSEvent.ModifierFlags(rawValue: KeyCombo.modifierMask)).rawValue
            }
            return
        }
        if event.keyCode == 53, bare { stopRecording(); return }              // Esc 取消
        if event.keyCode == 51 || event.keyCode == 117, bare { clear(); return } // Delete／Backspace 清除
        guard let combo = KeyCombo.from(event: event) else {
            hint = "这个键不支持，请换一个"
            return
        }
        if let rejection = KeyCombo.recordingRejection(keyID: combo.keyID, modifiers: combo.modifiers) {
            hint = rejection
            return
        }
        stopRecording()
        hint = ""
        if let clash = KeyCombo.conflict(target: command, keyID: combo.keyID, modifiers: combo.modifiers, settings: settings) {
            // 冲突草稿不写入：保留最后有效绑定。
            hint = "未写入：与「\(clash)」冲突"
            return
        }
        onChange?(Shortcut(key: combo.keyID, modifiers: combo.modifiers, disabled: false))
    }

    private func clear() {
        stopRecording()
        hint = ""
        // 明确禁用状态：重启不会自动恢复旧绑定。
        onChange?(Shortcut(key: "", modifiers: 0, disabled: true))
    }
}
