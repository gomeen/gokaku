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

    private func keyDown(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [.shift]) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters.lowercased(), isARepeat: false,
                         keyCode: keyCode)!
    }
}
