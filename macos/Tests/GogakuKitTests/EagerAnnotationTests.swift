import XCTest
@testable import GogakuKit

/// 学习中→英预译注释映射（CompositionView.annotatingHighlight）。
/// 合同（2026-11 用户裁决）：仅高亮候选显示英文注释，其余行清空残留注释。
/// 回归背景（2026-11 用户反馈「停止输入后译文不出来」）：预译结果曾把注释
/// 只写进渲染路径，渲染条件不满足时旧视图原样盖回，且泵按译文缓存判定
/// 完成、不再重发——恢复显示的载体必须是「已带注释的视图本身」。
final class EagerAnnotationTests: XCTestCase {
    private func view(highlight: Int, page: Int = 0,
                      candidates: [(text: String, explanation: String)]) -> CompositionView {
        var view = CompositionView(stamp: InputStamp(mode: .learning, direction: .zhToEn))
        view.page = page
        view.selected = highlight
        view.candidates = candidates.map { item in
            Candidate(stamp: view.stamp, sourceID: "normal:word", source: item.text,
                      range: RawRange(start: 0, length: 0), target: item.text,
                      explanation: item.explanation, resource: "gogaku-core")
        }
        return view
    }

    /// 高亮行写入缓存注释；其余行清空残留。
    func testHighlightRowAnnotatedAndOthersCleared() {
        let memory = ["你好": "hello"]
        let updated = view(highlight: 0, candidates: [
            ("你好", ""), ("你号", "stale"), ("拟好", ""),
        ]).annotatingHighlight(memory: memory)
        XCTAssertEqual(updated.candidates[0].explanation, "hello")
        XCTAssertEqual(updated.candidates[1].explanation, "", "非高亮行残留注释必须清空")
        XCTAssertEqual(updated.candidates[2].explanation, "")
    }

    /// 无缓存的高亮行保持无注释（等待预译），不清空也不虚构。
    func testUncachedHighlightStaysEmpty() {
        let updated = view(highlight: 1, candidates: [
            ("你好", "hello"), ("无缓存", ""),
        ]).annotatingHighlight(memory: ["你好": "hello"])
        XCTAssertEqual(updated.candidates[0].explanation, "", "非高亮行即使有缓存也不显示")
        XCTAssertEqual(updated.candidates[1].explanation, "")
    }

    /// 页内高亮换算：candidates 只装当前页（与快照口径一致），selected 为
    /// 全局序号，页内偏移 = selected − page×size。
    func testPageOffsetDrivesHighlightIndex() {
        var pageTwo = [(text: String, explanation: String)]()
        for i in CandidatePage.size..<(CandidatePage.size * 2) {
            pageTwo.append(("_\(i)", ""))
        }
        let updated = view(highlight: CandidatePage.size, page: 1, candidates: pageTwo)
            .annotatingHighlight(memory: ["_9": "ninth"])
        XCTAssertEqual(updated.candidates[0].explanation, "ninth", "全局第 10 个候选在第 2 页页内偏移 0")
    }

    /// 已一致的注释不产生新值（幂等，面板可安全重复渲染）。
    func testAnnotationIsIdempotent() {
        let memory = ["你好": "hello"]
        let once = view(highlight: 0, candidates: [("你好", "")]).annotatingHighlight(memory: memory)
        let twice = once.annotatingHighlight(memory: memory)
        XCTAssertEqual(once.candidates, twice.candidates)
        // 其余行清空同样幂等。
        let mixed = view(highlight: 0, candidates: [("你好", "hello"), ("你号", "stale")])
            .annotatingHighlight(memory: memory)
        XCTAssertEqual(mixed.candidates, mixed.annotatingHighlight(memory: memory).candidates)
    }

    /// 空缓存＝恢复显示时视图保持无注释（与修复前旧视图盖回的形态一致，
    /// 用于区分「映射正确但缓存未就绪」与「映射丢失注释」两类问题）。
    func testEmptyMemoryClearsStaleExplanations() {
        let updated = view(highlight: 0, candidates: [("你好", "hello"), ("你号", "x")])
            .annotatingHighlight(memory: [:])
        XCTAssertEqual(updated.candidates.map(\.explanation), ["", ""])
    }
}
