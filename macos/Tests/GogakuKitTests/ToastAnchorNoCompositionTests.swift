import XCTest
import GogakuKit

/// 无组合时提示锚点（2026-11-16 用户事故回归）。
///
/// 事故：Shift 单击切「中／英」后，提示浮层跑到窗口右上角，而不是输入光标附近。
/// 真因是 `toastAnchor()` 在无组合时去读宿主矩形——IMKTextInput 契约里索引相对
/// inline session，无组合时读数或是陈旧值、或在相邻字符格间循环，最终落到
/// 「鼠标位置」兜底。上一组合锚点才是同一输入框里最近的真实光标位置。
final class ToastAnchorNoCompositionTests: XCTestCase {
    private let screen = ScreenFrame(
        frame: NSRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1410))

    private var screens: [ScreenFrame] { [screen] }

    /// 有上一组合锚点、本次读数无效 → 用上一锚点，不落到鼠标。
    func testCarriedAnchorWinsOverMouseWhenPreReadUnusable() {
        let carried = NSRect(x: 300, y: 400, width: 2, height: 18)
        let mouse = NSRect(x: 2400, y: 1380, width: 0, height: 18)   // 窗口右上角
        let anchor = ToastAnchor.resolve(preRead: .zero, carried: carried,
                                         mouseCaret: mouse, screens: screens)
        XCTAssertEqual(anchor, carried, "无组合时必须用上一组合锚点，不能用鼠标位置")
    }

    /// 上一锚点与本次读数都不可用 → 才退回鼠标位置（保证提示必现）。
    func testMouseIsLastResort() {
        let mouse = NSRect(x: 2400, y: 1380, width: 0, height: 18)
        let anchor = ToastAnchor.resolve(preRead: .zero, carried: nil,
                                         mouseCaret: mouse, screens: screens)
        XCTAssertEqual(anchor, mouse)
    }

    /// 上一锚点在屏幕外（换屏／旧字段）→ 视为不可用，不采纳。
    func testOffscreenCarriedAnchorRejected() {
        let offscreen = NSRect(x: 9000, y: 9000, width: 2, height: 18)
        let mouse = NSRect(x: 100, y: 200, width: 0, height: 18)
        let anchor = ToastAnchor.resolve(preRead: .zero, carried: offscreen,
                                         mouseCaret: mouse, screens: screens)
        XCTAssertEqual(anchor, mouse, "屏幕外旧锚点必须作废")
    }

    /// 本次读数有效且与上一锚点相容 → 采纳更精确的本次读数。
    func testCompatiblePreReadPreferredOverCarried() {
        let carried = NSRect(x: 300, y: 400, width: 2, height: 18)
        let preRead = NSRect(x: 360, y: 400, width: 2, height: 18)   // 同行右移
        let anchor = ToastAnchor.resolve(preRead: preRead, carried: carried,
                                         mouseCaret: nil, screens: screens)
        XCTAssertEqual(anchor, preRead)
    }
}
