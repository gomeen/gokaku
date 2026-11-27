import AppKit
import XCTest
@testable import GogakuInput

final class ShiftHeldEnglishKeyTests: XCTestCase {
    func testTwoUppercaseKeyDownsWhileShiftIsHeldPassThroughWithoutComposition() throws {
        let events = [keyDown("A", keyCode: 0), keyDown("B", keyCode: 11)]
        var hostText = ""
        var chineseCompositionInputs: [String] = []

        for event in events {
            if let text = ShiftHeldEnglishKey.textToPassThrough(event, composing: false) {
                hostText += text
            } else {
                chineseCompositionInputs.append(event.characters ?? "")
            }
        }

        XCTAssertEqual(hostText, "AB")
        XCTAssertTrue(chineseCompositionInputs.isEmpty)
    }

    func testShiftedEnglishPassThroughRequiresBareShiftAndNoComposition() {
        XCTAssertNil(ShiftHeldEnglishKey.textToPassThrough(keyDown("A", keyCode: 0, flags: []), composing: false))
        XCTAssertNil(ShiftHeldEnglishKey.textToPassThrough(keyDown("A", keyCode: 0), composing: true))
        XCTAssertNil(ShiftHeldEnglishKey.textToPassThrough(keyDown("a", keyCode: 0), composing: false))
        XCTAssertNil(ShiftHeldEnglishKey.textToPassThrough(keyDown("A", keyCode: 0, flags: [.shift, .command]), composing: false))
    }

    func testShiftClickRecoversAfterHostDropsRelease() {
        var tracker = ShiftClickTracker()
        tracker.press(at: 1, side: 0)
        tracker.press(at: 2, side: 1)
        XCTAssertEqual(tracker.release(at: 2.1, side: 1), 1)
        XCTAssertNil(tracker.release(at: 2.101, side: 1))
    }

    func testRepeatedShiftDownDoesNotExtendClickWindow() {
        var tracker = ShiftClickTracker()
        tracker.press(at: 1, side: 0)
        tracker.press(at: 1.002, side: 0)
        XCTAssertNil(tracker.release(at: 1.601, side: 0))
    }

    func testTwoShiftsHeldTogetherDoNotCountAsATap() {
        var tracker = ShiftClickTracker()
        tracker.press(at: 1, side: 0)
        tracker.press(at: 1.1, side: 1)
        XCTAssertNil(tracker.release(at: 1.2, side: 0))
    }

    func testDelayedReleaseAfterPollingFallbackCannotToggleAgain() {
        var tracker = ShiftClickTracker()
        tracker.press(at: 1, side: 0)
        tracker.expirePress()
        XCTAssertNil(tracker.release(at: 1.25, side: 0))
    }

    private func keyDown(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [.shift]) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters.lowercased(), isARepeat: false,
                         keyCode: keyCode)!
    }
}
