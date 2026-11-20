import AppKit
import XCTest
import GogakuKit
@testable import GogakuInput

/// 粘性复用必须粘「锚定边」：候选变少、面板高度收缩时，贴光标的一侧不动，
/// 面板向底部收缩。旧实现复用左下角 origin，高度收缩时顶边下塌、面板沉底
/// （用户反馈：候选项变少后候选框贴到底部而不是贴着光标）。
final class CandidatePanelStickyTests: XCTestCase {
    private let anchor = NSRect(x: 400, y: 500, width: 2, height: 16)

    private func makeView(candidateCount: Int) -> CompositionView {
        var view = CompositionView(stamp: InputStamp(mode: .normal, direction: .zhToEn))
        view.normalPageSize = 9
        view.page = 0
        view.selected = 0
        view.totalCandidates = candidateCount
        view.preedit = "ni"
        view.candidates = (0..<candidateCount).map { i in
            Candidate(stamp: view.stamp, sourceID: "sticky-test", source: "ni",
                      range: RawRange(start: 0, length: 0),
                      target: "你\(i)", explanation: "", resource: "test")
        }
        return view
    }

    /// 纯几何：上次显示在锚点下方时，顶边稳定，高度变化向底部伸缩。
    func testStickyOriginKeepsTopEdgeWhenBelowAnchor() {
        // 顶边 92 + 400 = 492 = anchor.minY(500) - margin(8)，典型下方放置。
        let previous = NSPoint(x: 400, y: 92)
        // 收缩：顶边仍为 492，底部上收。
        XCTAssertEqual(CandidatePanel.stickyOrigin(previous: previous, previousHeight: 400,
                                                   anchor: anchor, panelSize: NSSize(width: 300, height: 250)).y,
                       242, accuracy: 0.001)
        // 增高：顶边仍为 492，向底部生长。
        XCTAssertEqual(CandidatePanel.stickyOrigin(previous: previous, previousHeight: 400,
                                                   anchor: anchor, panelSize: NSSize(width: 300, height: 500)).y,
                       -8, accuracy: 0.001)
    }

    /// 纯几何：上次显示在锚点上方（上翻）时，底边稳定，高度变化向顶部伸缩。
    func testStickyOriginKeepsBottomEdgeWhenAboveAnchor() {
        let previous = NSPoint(x: 400, y: 524)   // anchor.maxY(516) + margin(8)
        XCTAssertEqual(CandidatePanel.stickyOrigin(previous: previous, previousHeight: 300,
                                                   anchor: anchor, panelSize: NSSize(width: 300, height: 150)).y,
                       524, accuracy: 0.001)
        XCTAssertEqual(CandidatePanel.stickyOrigin(previous: previous, previousHeight: 300,
                                                   anchor: anchor, panelSize: NSSize(width: 300, height: 450)).y,
                       524, accuracy: 0.001)
    }

    /// 真实布局路径：同锚点候选从多变少，顶边不得下塌，收缩发生在底边。
    func testLayoutPanelKeepsTopEdgeWhenCandidatesShrink() throws {
        guard NSScreen.screens.first != nil else { return }
        let panel = CandidatePanel()
        panel.prime()
        panel.renderLayoutOnly(makeView(candidateCount: 9), at: anchor)
        let tall = panel.frame
        panel.renderLayoutOnly(makeView(candidateCount: 2), at: anchor)
        let short = panel.frame
        XCTAssertLessThan(short.height, tall.height, "测试前提：候选变少面板应变矮")
        XCTAssertEqual(short.maxY, tall.maxY, accuracy: 0.5,
                       "高度收缩时顶边（贴光标一侧）不得下塌")
        XCTAssertGreaterThan(short.minY, tall.minY, "收缩应发生在底边（向上收）")
    }
}
