import AppKit
import GogakuCore
import GogakuHost
import XCTest

final class HostTests: XCTestCase {
    private final class MetadataClient: NSObject {
        var selection = NSRange(location: 0, length: 0)
        var rectangle = NSRect.zero
        var geometryReads = 0
        var windowLevelValue: Int = 0
        @objc var windowLevel: Int { windowLevelValue }
        @objc func supportsUnicode() -> Bool { true }
        @objc func selectedRange() -> NSRange { selection }
        @objc func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
        @objc func uniqueClientIdentifierString() -> String { "test-client" }
        @objc func bundleIdentifier() -> String { "org.gogaku.validation.host" }
        @objc func attributes(forCharacterIndex index: Int, lineHeightRectangle rect: UnsafeMutablePointer<NSRect>) -> NSDictionary {
            geometryReads += 1
            rect.pointee = rectangle
            return [:]
        }
    }

    /// 不实现 windowLevel 的宿主：属性读取抛异常时快照回退为无效层级。
    private final class LevellessClient: NSObject {
        @objc func supportsUnicode() -> Bool { true }
        @objc func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
        @objc func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
        @objc func bundleIdentifier() -> String { "org.gogaku.validation.host" }
    }

    func testWindowLevelReadFromClient() {
        let client = MetadataClient()
        client.windowLevelValue = 2000
        let snapshot = gg_read_host(client)
        XCTAssertEqual(snapshot?.windowLevel, 2000)
        XCTAssertEqual(snapshot?.windowLevelValid, true)
    }

    func testWindowLevelExceptionFallsBackToInvalid() {
        let client = LevellessClient()
        let snapshot = gg_read_host(client)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.windowLevel, 0, "层级异常时值恒为 0")
        XCTAssertEqual(snapshot?.windowLevelValid, false)
    }

    func testUnknownSelectionDoesNotReadCaretRectangle() {
        let client = MetadataClient()
        client.selection = NSRange(location: NSNotFound, length: 0)
        client.rectangle = NSRect(x: 10, y: 10, width: 1, height: 15)
        let snapshot = gg_read_host(client)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(client.geometryReads, 0, "选区未知不读任何字符索引的矩形，不用索引 0 冒充光标")
        XCTAssertEqual(snapshot?.rectangleRead, true, "带矩形读取调用发生过：读过但不可信")
        XCTAssertEqual(snapshot?.rectangleValid, false)
        XCTAssertEqual(snapshot?.rectangle, NSZeroRect)
    }

    func testIdentityRecheckSkipsGeometryIPC() {
        let client = MetadataClient()
        client.rectangle = NSRect(x: 10, y: 10, width: 1, height: 15)
        let state = gg_read_host_state(client, false)
        XCTAssertEqual(state?.application, "org.gogaku.validation.host")
        XCTAssertEqual(client.geometryReads, 0)
        XCTAssertFalse(state?.rectangleValid ?? true)
        XCTAssertTrue(gg_read_host(client)?.rectangleValid ?? false)
        XCTAssertEqual(client.geometryReads, 1)
    }

    func testMissingCaretGeometryKeepsHostIdentity() {
        let client = MetadataClient()
        XCTAssertNotNil(gg_read_host(client), "无光标矩形不能使首键交还宿主")
    }

    func testUnavailableSelectionKeepsHostIdentity() {
        let client = MetadataClient()
        client.selection = NSRange(location: NSNotFound, length: 0)
        client.rectangle = NSRect(x: 10, y: 10, width: 1, height: 15)
        XCTAssertNotNil(gg_read_host(client))
    }
    // Chromium's terminal input only accepts an insertion at its current
    // selection. The visible buffer and the hidden input do not share offsets.
    private final class TerminalClient: NSObject {
        var received: [String] = []
        var replacement: NSRange?
        var staged: String?
        var markedSelection: NSRange?
        @objc func setMarkedText(_ text: Any, selectionRange: NSRange, replacementRange: NSRange) {
            // 宿主桥现在传 NSAttributedString（保留拼音光标；纯 NSString 会被宿主端
            // IMK 机制改写选区），测试替身同样接受两种形态。
            staged = (text as? String) ?? (text as? NSAttributedString)?.string
            markedSelection = selectionRange
        }
        @objc func insertText(_ text: Any, replacementRange: NSRange) {
            replacement = replacementRange
            if replacementRange.location == NSNotFound {
                received.append(text as! String)
            }
        }
    }

    func testCommitUsesClientSelection() {
        let client = TerminalClient()
        XCTAssertTrue(gg_insert_text(client, "你好"))
        XCTAssertEqual(client.received, ["你好"])
        XCTAssertEqual(client.replacement, NSRange(location: NSNotFound, length: 0))
    }

    func testConfirmedTextHandoffDoesNotCommitBeforeInsertion() {
        let client = TerminalClient()
        XCTAssertTrue(gg_mark_confirmed_text(client, "m"))
        XCTAssertEqual(client.staged, "m")
        XCTAssertEqual(client.received, [])
        XCTAssertTrue(gg_insert_text(client, "m"))
        XCTAssertEqual(client.received, ["m"])
    }

    @MainActor func testNativeSelectedTextIsReplaced() {
        let client = NSTextView(frame: .zero)
        client.string = "a旧文z"
        client.setSelectedRange(NSRange(location: 1, length: 2))
        XCTAssertTrue(gg_insert_text(client, "你好"))
        XCTAssertEqual(client.string, "a你好z")
        XCTAssertEqual(client.selectedRange(), NSRange(location: 3, length: 0))
    }

    func testMarkedSelectionFollowsCaretEvenWhenTextUnchanged() {
        let client = TerminalClient()
        XCTAssertTrue(gg_update_marked_text(client, "我jin'tian", 9))
        XCTAssertEqual(client.markedSelection, NSRange(location: 9, length: 0))
        XCTAssertTrue(gg_update_marked_text(client, "我jin'tian", 1))
        XCTAssertEqual(client.markedSelection, NSRange(location: 1, length: 0))
        XCTAssertTrue(gg_update_marked_text(client, "我jin'tian", 99))
        XCTAssertEqual(client.markedSelection, NSRange(location: 9, length: 0))
    }

    func testPreeditByteOffsetsBecomeUTF16() {
        XCTAssertEqual(PreeditCaret.utf16Offset(in: "ni'hao", utf8Offset: 6), 6)
        XCTAssertEqual(PreeditCaret.utf16Offset(in: "我jin", utf8Offset: 6), 4)
        XCTAssertEqual(PreeditCaret.utf16Offset(in: "😀我jin", utf8Offset: 7), 3)
        XCTAssertEqual(PreeditCaret.utf16Offset(in: "😀我jin", utf8Offset: 5), 2)
        XCTAssertEqual(PreeditCaret.utf16Offset(in: "我", utf8Offset: -1), 0)
    }

    func testMissingClientDoesNotReportIssuedCommit() {
        XCTAssertFalse(gg_insert_text(nil, "你好"))
        XCTAssertFalse(gg_mark_confirmed_text(nil, "m"))
    }
}
