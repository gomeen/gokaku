import XCTest
import AppKit
@testable import GogakuKit

/// 候选窗无锚点回退（2026-11 企业微信兼容）。词首 pre-read 有效时必须原样
/// 采纳（既有行为不变）；无效时按「上一组合锚点＞鼠标位置」回退；全部
/// 不可得返回 nil（维持隐藏）。
final class AnchorFallbackTests: XCTestCase {
    private let valid = NSRect(x: 800, y: 700, width: 0, height: 17)
    private let carried = NSRect(x: 760, y: 700, width: 0, height: 17)
    private let mouse = NSRect(x: 500, y: 400, width: 0, height: 18)

    func testValidPreReadWinsUnchanged() {
        XCTAssertEqual(AnchorFallback.resolve(preRead: valid, carried: carried, mouseCaret: mouse),
                       valid, "pre-read 有效时原样采纳，不受回退影响")
        XCTAssertEqual(AnchorFallback.resolve(preRead: valid, carried: nil, mouseCaret: nil),
                       valid)
    }

    func testCarriedAnchorUsedWhenPreReadInvalid() {
        XCTAssertEqual(AnchorFallback.resolve(preRead: .zero, carried: carried, mouseCaret: mouse),
                       carried, "pre-read 无效时优先上一组合锚点（贴近真实插入点）")
    }

    func testMouseCaretWhenNoCarriedAnchor() {
        XCTAssertEqual(AnchorFallback.resolve(preRead: .zero, carried: nil, mouseCaret: mouse),
                       mouse, "会话内尚无锚点时回退鼠标位置")
        XCTAssertEqual(AnchorFallback.resolve(preRead: .zero, carried: .zero, mouseCaret: mouse),
                       mouse, "零值 carried 视同无锚点")
    }

    func testNilWhenNothingAvailable() {
        XCTAssertNil(AnchorFallback.resolve(preRead: .zero, carried: nil, mouseCaret: nil),
                     "全部不可得＝无处可显，维持隐藏")
        XCTAssertNil(AnchorFallback.resolve(preRead: .zero, carried: .zero, mouseCaret: nil))
    }
}
