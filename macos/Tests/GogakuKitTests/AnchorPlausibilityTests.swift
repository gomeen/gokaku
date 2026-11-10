import XCTest
import AppKit
@testable import GogakuKit

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
        // 常规窗龄（超出宽限窗）：未到 escapeAfter 持续冻结。
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: fieldOrigin, suspectStreak: 6,
                                                   anchorAge: AnchorPlausibility.graceReads),
                       .freeze, "未到逃生门次数持续冻结")
    }

    func testMultiLineTeleportFreezes() {
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: bufferStart, suspectStreak: 0),
                       .freeze, "跨多行跳到缓冲区首行＝误报")
    }

    func testPersistentTeleportEscapes() {
        // 常规窗龄下连续可疑达到 escapeAfter：接受（窗口真实拖动/滚动的逃生门）。
        let streak = AnchorPlausibility.escapeAfter - 1
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: bufferStart, suspectStreak: streak,
                                                   anchorAge: AnchorPlausibility.graceReads),
                       .escapeAccept)
    }

    // MARK: 宽限窗（首入错位优化 2026-11-05）

    func testGraceWindowEscapesFasterAtCompositionStart() {
        // 首锚（pre-read）陈旧时，真实新位置是持续 far-jump：宽限窗内第 3 拍
        // 即采纳（约 0.2–0.3s），不再等满 8 拍。
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: bufferStart, suspectStreak: 2,
                                                   anchorAge: 0),
                       .escapeAccept, "宽限窗内连续 3 拍真实位置应被采纳")
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: fieldOrigin, suspectStreak: 2,
                                                   anchorAge: 1),
                       .escapeAccept, "同行原点误报持续到第 3 拍同样视为真实移动")
    }

    func testTransientMisreportWithinGraceStillFrozen() {
        // Orca 瞬时误报一两拍内消失：宽限窗内不满 3 连拍仍冻结。
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: bufferStart, suspectStreak: 0,
                                                   anchorAge: 0),
                       .freeze)
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: bufferStart, suspectStreak: 1,
                                                   anchorAge: 1),
                       .freeze)
    }

    func testGraceWindowExpiresByAge() {
        // 窗龄推进到 graceReads 后恢复常规阈值：同样 2 连拍不再放行。
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: bufferStart, suspectStreak: 2,
                                                   anchorAge: AnchorPlausibility.graceReads),
                       .freeze, "宽限窗结束后恢复 escapeAfter 阈值")
        // 窗界内最后一拍仍在宽限内（序号 0 起计）。
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: bufferStart, suspectStreak: 2,
                                                   anchorAge: AnchorPlausibility.graceReads - 1),
                       .escapeAccept)
    }

    func testGraceStreakCarriesAcrossWindowBoundary() {
        // 跨窗界沿用已累积 streak：误报从宽限窗存活到窗后，累计到 8 连拍仍能
        // 走常规逃生门（不应因换档清零而永远冻住）。
        XCTAssertEqual(AnchorPlausibility.classify(previous: onLine1, next: bufferStart, suspectStreak: 7,
                                                   anchorAge: AnchorPlausibility.graceReads),
                       .escapeAccept)
    }

    func testRecoveryAfterEscapeResetsStreak() {
        // 逃生门接受后，同位置重复读取恒采纳（计数已复位）。
        XCTAssertEqual(AnchorPlausibility.classify(previous: bufferStart, next: bufferStart, suspectStreak: 0),
                       .accept)
    }

    func testProvisionalPreReadReplacedByFirstCompositionReading() {
        // 2026-11-10 Orca 终端：首键 pre-read 是 pi 启动前 shell 行的陈旧矩形
        // （屏幕顶部），组合内索引 0 才是底部输入行。临时锚点不受瞬移保护。
        let staleShellLine = caret(x: 359, y: 1318), realEditorLine = caret(x: 326, y: 145)
        XCTAssertEqual(AnchorPlausibility.classify(previous: staleShellLine, next: realEditorLine,
                                                   suspectStreak: 0, previousProvisional: true),
                       .accept, "临时锚点被组合内首个有效读数直接取代")
        XCTAssertEqual(AnchorPlausibility.classify(previous: staleShellLine, next: realEditorLine,
                                                   suspectStreak: 0),
                       .freeze, "已被组合内读数印证的锚点仍受瞬移保护")
    }
}
