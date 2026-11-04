import SwiftUI
import AppKit
import GogakuCore

/// 快捷键编辑器：键帽显示（.kcap）、窗口内事件捕获录制、清除、恢复默认。
/// 所有写回（录制成功／清除／恢复默认）统一走 `shortcut` Binding——
/// 一次操作恰好一次提交、一次保存；不存在可选回调旁路。
/// 录制裁决出冲突时不写回绑定（保留最后有效绑定），通过 `onConflictDraft`
/// 把冲突草稿上报给页面统一展示与筛选；`onEditingStart` 在开始录制时上报，
/// 页面据此清除其他命令的旧草稿。
struct ShortcutEditor: View {
    /// 展示形态：快捷键表格行（键帽列 210＋来源列 90＋操作列 104，列宽由
    /// SettingsPalette 统一常量驱动）。
    enum Layout {
        case tableRow(source: String)
    }

    let command: ConfigurableCommand
    @Binding var shortcut: Shortcut
    let settings: GogakuCore.Settings
    let layout: Layout
    /// 页面计算的冲突展示文本（含冲突草稿）；空表示无冲突。
    var conflictName: String = ""
    /// 录制裁决冲突时上报（尝试的组合、冲突对象名）；不写回绑定。
    var onConflictDraft: ((Shortcut, String) -> Void)? = nil
    /// 开始录制时上报该命令；页面据此清除其他命令的冲突草稿。
    var onEditingStart: ((ConfigurableCommand) -> Void)? = nil
    /// 表格形态下操作按钮是否可见（行悬停／录制中显示，对应原型 hover 行为）。
    var actionsVisible: Bool = true

    @State private var recording = false
    @State private var recordingModifiers: UInt = 0
    @State private var hint = ""
    /// 本次录制裁决出的冲突对象名（页面草稿缺失时的行内提示来源）。
    @State private var internalClash = ""
    @State private var monitor: Any?

    var body: some View {
        switch layout {
        case .tableRow(let source):
            tableRowBody(source: source)
        }
    }

    // MARK: 冲突展示（页面草稿优先，内联裁决兜底，避免重复显示）

    private var conflictDisplay: String? {
        if !conflictName.isEmpty { return conflictName }
        if !internalClash.isEmpty { return "未写入：与「\(internalClash)」冲突" }
        return nil
    }

    // MARK: 表格行形态：键帽列 | 来源列 | 操作列（与固定行共用同一列宽）

    private func tableRowBody(source: String) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                if recording {
                    recordingCapsule
                } else {
                    keycaps
                }
                if let conflict = conflictDisplay {
                    Text(conflict).font(.system(size: 10.5))
                        .foregroundStyle(SettingsPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !hint.isEmpty {
                    Text(hint).font(.system(size: 10.5))
                        .foregroundStyle(SettingsPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: SettingsPalette.keyColumnWidth, alignment: .leading)
            .padding(.horizontal, 12)
            Text(source)
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsPalette.secondaryText)
                .frame(width: SettingsPalette.sourceColumnWidth, alignment: .leading)
            actions
                .font(.system(size: 13))
                .frame(width: SettingsPalette.actionColumnWidth, alignment: .trailing)
                .padding(.trailing, 12)
                .opacity(actionsVisible || recording ? 1 : 0)
        }
        // 行被筛选移除／页面切换时结束录制并移除事件监视器，避免按键持续被吞。
        .onDisappear { stopRecording() }
        .accessibilityElement(children: .contain)
    }

    // MARK: 键帽与录制态

    @ViewBuilder private var keycaps: some View {
        if !shortcut.isValid {
            // 原型 .ksnone：未设置显示「—」。
            Text("—").font(.system(size: 12))
                .foregroundStyle(SettingsPalette.tertiaryText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(command.displayName)快捷键未设置")
        } else {
            HStack(spacing: 5) {
                ForEach(caps, id: \.self) { cap in
                    SettingsKeycap(label: cap)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(command.displayName)快捷键：\(shortcutDisplay)")
        }
    }

    /// 录制态胶囊（.keyrec.is-rec：accent 描边、accent-soft 底、accent-text 文字）。
    private var recordingCapsule: some View {
        HStack(spacing: 6) {
            Text(KeyCombo.modifierSymbols(recordingModifiers).isEmpty
                 ? "请按下快捷键…" : KeyCombo.modifierSymbols(recordingModifiers))
                .font(.system(size: 12, design: .monospaced))
        }
        .foregroundStyle(SettingsPalette.accentText)
        .padding(.horizontal, 9)
        .frame(minHeight: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(SettingsPalette.accentSoft)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(SettingsPalette.accent, lineWidth: 1)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在录制\(command.displayName)快捷键；按 Escape 取消，Delete 清除")
        .accessibilityValue(KeyCombo.modifierSymbols(recordingModifiers).isEmpty
                            ? "等待按键" : KeyCombo.modifierSymbols(recordingModifiers))
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

    // MARK: 表格行操作（编辑 ✎／清除 −／恢复默认 ↺）

    private var actions: some View {
        HStack(spacing: 2) {
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Image(systemName: recording ? "xmark" : "pencil")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(SettingsPalette.secondaryText)
            .accessibilityLabel(recording ? "取消录制\(command.displayName)快捷键" : "编辑「\(command.displayName)」的快捷键")

            Button {
                clear()
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(SettingsPalette.secondaryText)
            .accessibilityLabel("清除「\(command.displayName)」的快捷键")

            Button {
                shortcut = command.defaultShortcut
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(SettingsPalette.secondaryText)
            // 已是默认时不可恢复；清除（disabled）后恢复可用。
            .disabled(shortcut == command.defaultShortcut)
            .accessibilityLabel("恢复「\(command.displayName)」的默认快捷键")
        }
    }

    // MARK: - 录制（设置窗口内事件捕获）

    private func startRecording() {
        hint = ""
        internalClash = ""
        recording = true
        recordingModifiers = 0
        onEditingStart?(command)
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
        let attempted = Shortcut(key: combo.keyID, modifiers: combo.modifiers, disabled: false)
        if let clash = KeyCombo.conflict(target: command, keyID: combo.keyID, modifiers: combo.modifiers, settings: settings) {
            // 冲突草稿：不写入绑定（保留最后有效绑定），上报页面统一展示与筛选。
            stopRecording()
            hint = ""
            internalClash = clash
            onConflictDraft?(attempted, clash)
            return
        }
        stopRecording()
        hint = ""
        internalClash = ""
        shortcut = attempted
    }

    /// 清除：写回明确禁用状态（重启不会自动恢复旧绑定），一次提交。
    private func clear() {
        stopRecording()
        hint = ""
        internalClash = ""
        shortcut = Shortcut(key: "", modifiers: 0, disabled: true)
    }
}
