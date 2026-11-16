import XCTest
import GogakuKit
@testable import GogakuInput

final class HorizontalCandidatePanelTests: XCTestCase {
    func testHorizontalLayoutWidthWithinClamp() {
        var view = CompositionView(stamp: InputStamp(mode: .normal, direction: .zhToEn))
        view.candidateLayoutHorizontal = true
        view.normalPageSize = 7
        view.horizontalGlossRowEnabled = true
        view.page = 0
        view.selected = 0
        view.totalCandidates = 12
        view.preedit = "ni'hao"
        let words = ["你好", "你号", "泥好", "你好啊", "你好吗", "你好呀", "你"]
        view.candidates = words.enumerated().map { i, w in
            Candidate(stamp: view.stamp, sourceID: "t", source: w, range: RawRange(start: 0, length: 0),
                      target: w, explanation: i == 0 ? "(int.) hello · hi" : "", resource: "test")
        }
        let theme = CandidatePanelTheme.resolve(.rimeMacOSLike, fontSize: 14)
        let layout = PanelLayout.horizontalNormal(view: view, theme: theme)
        XCTAssertGreaterThanOrEqual(layout.panelWidth, 320)
        XCTAssertLessThanOrEqual(layout.panelWidth, 860)
        XCTAssertEqual(layout.rows.count, 7)
        XCTAssertNotNil(layout.glossLine)
    }
}

/// 横排布局的序号与页码合同（2026-11-16 用户报「序号显示有问题」「9 之后还可选」）。
final class HorizontalLayoutContractTests: XCTestCase {
    private func makeView(words: [String], selected: Int = 0, page: Int = 0,
                          pageSize: Int = 9, total: Int? = nil,
                          gloss: Bool = false) -> CompositionView {
        var view = CompositionView(stamp: InputStamp(mode: .normal, direction: .zhToEn))
        view.candidateLayoutHorizontal = true
        view.normalPageSize = pageSize
        view.horizontalGlossRowEnabled = gloss
        view.page = page
        view.selected = selected
        view.totalCandidates = total ?? words.count
        view.preedit = "heng"
        view.candidates = words.enumerated().map { i, w in
            Candidate(stamp: view.stamp, sourceID: "t", source: w, range: RawRange(start: 0, length: 0),
                      target: w, explanation: "", resource: "test")
        }
        return view
    }

    private let theme = CandidatePanelTheme.resolve(.rimeMacOSLike, fontSize: 14)

    /// 每个 chip 的序号必须画在自己的 chip 内（旧实现用固定左边距，横排下所有
    /// 序号叠在第一个 chip 上，看起来是一个乱码方块）。
    func testIndexIsDrawnInsideItsOwnChip() {
        let view = makeView(words: ["橫", "行", "恒", "哼", "衡", "亨", "隈", "蘅"])
        let layout = PanelLayout.horizontalNormal(view: view, theme: theme)
        XCTAssertEqual(layout.rows.count, 8)
        for row in layout.rows {
            XCTAssertGreaterThanOrEqual(row.indexX, row.frame.minX,
                                        "序号左缘不得早于自己的 chip")
            XCTAssertLessThanOrEqual(row.indexX + row.indexWidth, row.wordX,
                                     "序号不得与候选字重叠")
        }
        // 序号逐行右移：证明不是都画在同一处
        let xs = layout.rows.map(\.indexX)
        XCTAssertEqual(xs, xs.sorted())
        XCTAssertGreaterThan(xs.last! - xs.first!, 100)
    }

    /// 候选不得压到分页标签上（旧实现出现「蘅/5」粘连并被窗口裁字）。
    func testRowsNeverOverlapPageLabel() {
        let words = ["橫", "行", "恒", "哼", "衡", "亨", "隈", "蘅"] + Array(repeating: "测试词语", count: 8)
        let view = makeView(words: Array(words.prefix(9)), pageSize: 9, total: 45)
        let layout = PanelLayout.horizontalNormal(view: view, theme: theme)
        guard let page = layout.page else { return XCTFail("多页时应有分页标签") }
        XCTAssertGreaterThan(page.length, 0)
        let pageLeft = layout.pageRect.minX
        for row in layout.rows {
            XCTAssertLessThanOrEqual(row.frame.maxX, pageLeft + 0.5,
                                     "候选不得侵入分页标签区域")
        }
    }

    /// 宽度上限不变：横排面板仍夹在 [320, 860]。
    func testWidthClampHoldsWithPageReserve() {
        let view = makeView(words: ["很长的候选词语重复很多遍测试宽度上限"], pageSize: 4, total: 40)
        let layout = PanelLayout.horizontalNormal(view: view, theme: theme)
        XCTAssertGreaterThanOrEqual(layout.panelWidth, 320)
        XCTAssertLessThanOrEqual(layout.panelWidth, 860)
    }
}
