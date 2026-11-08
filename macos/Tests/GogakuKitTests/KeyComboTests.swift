import XCTest
import AppKit
@testable import GogakuKit

/// 快捷键规范模型：录制、存储与事件匹配共用同一转换逻辑（2026-11-03 定稿）。
final class KeyComboTests: XCTestCase {
    /// 构造按键事件：显式给出 charactersIgnoringModifiers，避免依赖键盘布局。
    private func keyDown(_ chars: String, ignoring: String, flags: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: NSPoint(x: 0, y: 0), modifierFlags: flags,
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: ignoring,
                         isARepeat: false, keyCode: keyCode)!
    }

    private let ctrlShift = NSEvent.ModifierFlags([.control, .shift])

    func testLetterMatchesAcrossShiftAndCase() {
        let combo = KeyCombo.from(event: keyDown("K", ignoring: "k", flags: ctrlShift, keyCode: 40))
        XCTAssertEqual(combo, KeyCombo(keyID: "k", modifiers: ctrlShift.rawValue))
    }

    func testPunctuationWithShiftKeepsShiftedCharacter() {
        // Shift＋1 → `!`：带修饰键的标点保留移位后字符，存储与匹配一致。
        let combo = KeyCombo.from(event: keyDown("!", ignoring: "!", flags: [.control, .shift], keyCode: 18))
        XCTAssertEqual(combo, KeyCombo(keyID: "!", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue))
    }

    func testFunctionKeyUsesKeyCodeMap() {
        // F2 的 charactersIgnoringModifiers 是私用区字符；必须按 keyCode 判定。
        let combo = KeyCombo.from(event: keyDown("\u{F704}", ignoring: "\u{F704}", flags: .control, keyCode: 120))
        XCTAssertEqual(combo, KeyCombo(keyID: "f2", modifiers: NSEvent.ModifierFlags.control.rawValue))
        XCTAssertEqual(combo?.displayText, "⌃F2")
    }

    func testUnknownPrivateUseAndControlCharactersUnbindable() {
        XCTAssertNil(KeyCombo.from(event: keyDown("\u{F718}", ignoring: "\u{F718}", flags: .control, keyCode: 999)))
        // keyCode 不在表内且字符为控制字符：不可绑定。
        XCTAssertNil(KeyCombo.from(event: keyDown("\u{3}", ignoring: "\u{3}", flags: .control, keyCode: 999)))
    }

    func testRecordingRulesRejectBarePrintableAndAcceptFunctionKeys() {
        XCTAssertEqual(KeyCombo.recordingRejection(keyID: "k", modifiers: 0),
                       "请加上修饰键（Control／Option／Shift／Command），或改用 F1–F15")
        XCTAssertNil(KeyCombo.recordingRejection(keyID: "f2", modifiers: 0), "F 键无修饰键可绑定")
        XCTAssertNil(KeyCombo.recordingRejection(keyID: "!", modifiers: ctrlShift.rawValue))
        XCTAssertNotNil(KeyCombo.recordingRejection(keyID: "esc", modifiers: 0),
                        "单独 Esc 被录制层拦截取消，不是可绑定快捷键")
        XCTAssertNotNil(KeyCombo.recordingRejection(keyID: "return", modifiers: 0),
                        "无修饰键的导航键不绑定")
    }

    func testShortcutValidationRoundTrip() {
        let shortcut = Shortcut(key: "f3", modifiers: NSEvent.ModifierFlags.control.rawValue, disabled: false)
        XCTAssertEqual(KeyCombo(shortcut: shortcut)?.keyID, "f3")
        let cleared = Shortcut(key: "", modifiers: 0, disabled: true)
        XCTAssertNil(KeyCombo(shortcut: cleared), "明确禁用的绑定不构成可匹配组合")
        let bare = Shortcut(key: "k", modifiers: 0, disabled: false)
        XCTAssertNil(KeyCombo(shortcut: bare), "无修饰键的可打印字符不可绑定")
    }

    func testClearedBindingDoesNotMatchEvents() {
        // 明确清除后的绑定不能在重启时自动恢复（旧格式缺省 disabled ≠ 清除，
        // 由 SettingsMigrationTests 覆盖；此处确认匹配层忽略禁用绑定）。
        let cleared = Shortcut(key: "k", modifiers: ctrlShift.rawValue, disabled: true)
        let event = keyDown("k", ignoring: "k", flags: ctrlShift, keyCode: 40)
        let combo = KeyCombo.from(event: event)
        XCTAssertFalse(!cleared.disabled && combo?.keyID == cleared.key && combo?.modifiers == cleared.modifiers)
    }

    func testConflictBetweenConfigurableCommands() {
        var settings = Settings()
        let mode = ConfigurableCommand.modeSwitch
        XCTAssertEqual(KeyCombo.conflict(target: .directionSwitch, keyID: "k",
                                         modifiers: ctrlShift.rawValue, settings: settings),
                       "普通／学习", "与其他可配置命令同组合即冲突")
        XCTAssertNil(KeyCombo.conflict(target: .modeSwitch, keyID: "k",
                                       modifiers: ctrlShift.rawValue, settings: settings))
    }

    func testConflictWithFixedOperations() {
        let ctrl = NSEvent.ModifierFlags.control.rawValue
        // 与固定输入操作相同组合（普通模式 Ctrl＋N 下一候选）即冲突。
        XCTAssertTrue(KeyCombo.conflict(target: .modeSwitch, keyID: "n", modifiers: ctrl,
                                        settings: Settings())?.contains("固定") == true)
        // 学习模式固定原文上屏 ⌘Return 也计入冲突检查。
        XCTAssertTrue(KeyCombo.conflict(target: .modeSwitch, keyID: "return", modifiers: NSEvent.ModifierFlags.command.rawValue,
                                        settings: Settings()) != nil)
        XCTAssertNil(KeyCombo.conflict(target: .modeSwitch, keyID: "x", modifiers: ctrl,
                                       settings: Settings()))
    }

    func testFixedOperationsCoverCancelAndCommit() {
        let names = KeyCombo.fixedOperations().map(\.name)
        XCTAssertTrue(names.contains("取消组合"))
        XCTAssertTrue(names.contains("原文上屏"))
        // 每条固定操作都标注真实适用状态。
        XCTAssertTrue(KeyCombo.fixedOperations().allSatisfy { !$0.modes.isEmpty })
    }
}
