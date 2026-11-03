import XCTest
import AppKit
@testable import GogakuCore

/// 锚点瞬移过滤器（2026-11-03 Orca 打字中候选窗无规律跳到无关位置的修复）。
/// 光标轨迹有结构：同行只能向右／小幅回退；相邻行＝换行（dx 任意）；
/// 跨多行只可能是瞬移或真实滚动。覆盖各档判定与逃生门。
final class AnchorPlausibilityTests: XCTestCase {
    private let line: CGFloat = 17
    /// 行内光标（零宽，高度＝行高）。
    private func caret(x: CGFloat, y: CGFloat) -> NSRect {
        NSRect(x: x, y: y, width: 0, height: line)
    }
    private let onLine1 = NSRect(x: 800, y: 700, width: 0, height: 17)
    /// 控件原点类误报：第一行行首（同行大左跳）。
    private let fieldOrigin = NSRect(x: 12, y: 700, width: 640, height: 17)
    /// 控件首行误报（打字在第三行时）：跨多行跳变。
    private let bufferStart = NSRect(x: 12, y: 734, width: 640, height: 17)

    func testFirstAnchorOfCompositionAlwaysAccepted() {
        XCTAssertEqual(AnchorPlausibility.classify(previous: nil, next: fieldOrigin, suspectStreak: 0),
                       .accept, "组合起点必须信任宿主（无处可比较）")
    }

    func testSameLineTypingAccepted() {
        // 逐键右移、拼音删字母小幅回退（≤100pt）：同行正常路径。
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: caret(x: 812, y: 700), suspectStreak: 0),
                       .accept, "打字右移采纳")
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: caret(x: 740, y: 700), suspectStreak: 0),
                       .accept, "同行小幅回退（删字母）采纳")
    }

    func testWrapToNextLineAcceptedRegardlessOfDx() {
        // 换行：y 降一个行高、x 跳到行首（大左跳）——正常路径，必须采纳。
        let wrapped = caret(x: 12, y: 700 - 17)
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: wrapped, suspectStreak: 0),
                       .accept, "换行回行首是正常跟随")
        // 终端逐行滚动：y 升一个行高。
        let scrolled = caret(x: 800, y: 700 + 17)
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: scrolled, suspectStreak: 0),
                       .accept, "逐行滚动采纳")
    }

    func testSameLineLargeLeftJumpFreezes() {
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: fieldOrigin, suspectStreak: 0),
                       .freeze, "同行跳回行首原点＝选择闪断特征")
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: fieldOrigin, suspectStreak: 6),
                       .freeze, "未到逃生门次数持续冻结")
    }

    func testMultiLineTeleportFreezes() {
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: bufferStart, suspectStreak: 0),
                       .freeze, "跨多行跳到缓冲区首行＝误报")
    }

    func testPersistentTeleportEscapes() {
        // 连续可疑达到 escapeAfter：接受（窗口真实拖动/滚动的逃生门）。
        let streak = AnchorPlausibility.escapeAfter - 1
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: bufferStart, suspectStreak: streak),
                       .escapeAccept)
    }

    func testRecoveryAfterEscapeResetsStreak() {
        // 逃生门接受后，同位置重复读取恒采纳（计数已复位）。
        XCTAssertEqual(AnchorPlausibility.classify(previous: bufferStart, next: bufferStart, suspectStreak: 0),
                       .accept)
    }
}
