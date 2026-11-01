import XCTest
@testable import GogakuCore

/// 焦点锚定规则回归：组合中字母移动宿主选区不得误判换框；
/// 用户点击别处、切字段、切应用必须判为异框。
final class FocusRuleTests: XCTestCase {
    let app = "com.example.editor"
    let otherApp = "com.apple.Safari"
    let anchor = NSRange(location: 5, length: 0)

    func testSelectionUnchanged_sameField() {
        // 非组合状态：选区＝锚点即同框。
        XCTAssertTrue(FocusRule.isSameField(application: app, pid: 100, selection: anchor,
                                            markedRange: FocusRule.noMarkedRange, composing: false,
                                            anchorApplication: app, anchorPid: 100, anchor: anchor))
    }

    func testComposingWithoutLettersAtAnchor_selectionAloneInsufficient() {
        // 复查 A1：组合中同应用两个空字段选区都是 (0,0)——仅凭选区＝锚点不得判同框。
        XCTAssertFalse(FocusRule.isSameField(application: app, pid: 100, selection: anchor,
                                             markedRange: FocusRule.noMarkedRange, composing: true,
                                             anchorApplication: app, anchorPid: 100, anchor: anchor))
    }

    func testComposingLettersAtAnchor_sameField() {
        let marked = NSRange(location: 5, length: 4)
        XCTAssertTrue(FocusRule.isSameField(application: app, pid: 100, selection: NSRange(location: 9, length: 0),
                                            markedRange: marked, composing: true,
                                            anchorApplication: app, anchorPid: 100, anchor: anchor))
    }

    func testLettersPushSelection_sameFieldViaMarkedRange() {
        // 四个字母显示后：选区被推到字母之后，字母范围起始于锚点。
        let moved = NSRange(location: 9, length: 0)
        let marked = NSRange(location: 5, length: 4)
        XCTAssertTrue(FocusRule.isSameField(application: app, pid: 100, selection: moved,
                                            markedRange: marked, composing: true,
                                            anchorApplication: app, anchorPid: 100, anchor: anchor))
    }

    func testAnchorAtZeroLettersAtZero_sameField() {
        // 锚点在 0、字母在 0：仍判定同框（长度区分「有字母」与宿主 {0,0} 报告）。
        let moved = NSRange(location: 4, length: 0)
        XCTAssertTrue(FocusRule.isSameField(application: app, pid: 100, selection: moved,
                                            markedRange: NSRange(location: 0, length: 4), composing: true,
                                            anchorApplication: app, anchorPid: 100, anchor: NSRange(location: 0, length: 0)))
    }

    func testHostReportsEmptyMarkedAsZeroZero_noFalseMatch() {
        // 宿主用 {0,0} 表示无字母时不得误判为同框（选区已移动）。
        let moved = NSRange(location: 9, length: 0)
        XCTAssertFalse(FocusRule.isSameField(application: app, pid: 100, selection: moved,
                                             markedRange: NSRange(location: 0, length: 0), composing: true,
                                             anchorApplication: app, anchorPid: 100, anchor: NSRange(location: 0, length: 0)))
    }

    func testIdleSelectionMoved_startsNewComposition() {
        // 确认后宿主可短暂报告旧选区；无组合时直接以当前选区重锚，不能吞首键。
        let moved = NSRange(location: 9, length: 0)
        XCTAssertTrue(FocusRule.isSameField(application: app, pid: 100, selection: moved,
                                            markedRange: FocusRule.noMarkedRange, composing: false,
                                            anchorApplication: app, anchorPid: 100, anchor: anchor))
    }

    func testUnavailableSelectionDoesNotLoseActiveComposition() {
        XCTAssertTrue(FocusRule.isSameField(application: app, pid: 100,
                                            selection: NSRange(location: NSNotFound, length: 0),
                                            markedRange: FocusRule.noMarkedRange, composing: true,
                                            anchorApplication: app, anchorPid: 100, anchor: anchor))
    }

    func testLettersDisabledRequiresStableAnchor() {
        XCTAssertTrue(FocusRule.isSameField(application: app, pid: 100, selection: anchor,
                                            markedRange: FocusRule.noMarkedRange, composing: true,
                                            anchorApplication: app, anchorPid: 100, anchor: anchor,
                                            expectsMarkedText: false))
        XCTAssertFalse(FocusRule.isSameField(application: app, pid: 100,
                                             selection: NSRange(location: 20, length: 0),
                                             markedRange: FocusRule.noMarkedRange, composing: true,
                                             anchorApplication: app, anchorPid: 100, anchor: anchor,
                                             expectsMarkedText: false))
    }

    func testApplicationChanged_differentField() {
        XCTAssertFalse(FocusRule.isSameField(application: otherApp, pid: 100, selection: anchor,
                                             markedRange: NSRange(location: 5, length: 4), composing: true,
                                             anchorApplication: app, anchorPid: 100, anchor: anchor))
    }

    func testPidChanged_differentField() {
        XCTAssertFalse(FocusRule.isSameField(application: app, pid: 200, selection: anchor,
                                             markedRange: NSRange(location: 5, length: 4), composing: true,
                                             anchorApplication: app, anchorPid: 100, anchor: anchor))
    }

    func testMarkedElsewhere_differentField() {
        // 字母范围不在锚点位置（宿主清了旧字母又在别处显示）：异框。
        let moved = NSRange(location: 9, length: 0)
        XCTAssertFalse(FocusRule.isSameField(application: app, pid: 100, selection: moved,
                                             markedRange: NSRange(location: 20, length: 2), composing: true,
                                             anchorApplication: app, anchorPid: 100, anchor: anchor))
    }
}
