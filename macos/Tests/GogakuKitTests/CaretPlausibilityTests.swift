import XCTest
import GogakuKit

/// 宿主回报的插入点矩形合理性（2026-11-13 微信真机事故回归）。
///
/// 微信有时把整个屏幕矩形当插入点矩形回报；它有限、正高、落在屏内，旧规则
/// 全部通过，`PanelPlacement` 把它算成「上翻到屏幕顶部」，候选窗钉死在左上角
/// (8,38)。同一份不可信读数还会让 `AnchorPlausibility` 的瞬移过滤在逃生门后
/// 接受它，位置再也回不来。
final class CaretPlausibilityTests: XCTestCase {
    private let screen = ScreenFrame(
        frame: NSRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1410))

    private var screens: [ScreenFrame] { [screen] }

    /// 真实事故读数：整屏矩形必须被拒。
    func testFullScreenRectIsNotACaret() {
        let wholeScreen = NSRect(x: 0, y: 0, width: 2560, height: 1410)
        XCTAssertFalse(AnchorPlausibility.isPlausibleCaret(wholeScreen, screens: screens))
    }

    /// 整窗／整个文本框高度（多行选区）同样不是光标。
    func testTallRectIsNotACaret() {
        let tall = NSRect(x: 100, y: 200, width: 800, height: 900)
        XCTAssertFalse(AnchorPlausibility.isPlausibleCaret(tall, screens: screens))
    }

    /// 候选窗被钉在左上角的回归向量：整屏矩形代入 PanelPlacement 得到的正是
    /// (8,38)（AX 坐标）。合理性校验必须先把这类读数挡在锚点之外。
    func testFullScreenAnchorWouldPinTopLeft() {
        let wholeScreen = NSRect(x: 0, y: 0, width: 2560, height: 1410)
        let size = NSSize(width: 381, height: 331)
        let origin = PanelPlacement.origin(anchor: wholeScreen, panelSize: size, screens: screens)
        XCTAssertEqual(origin, NSPoint(x: 8, y: 1071))
        // 换成合理光标后落在插入点右下、屏幕中部；高度 18 是一行文本量级。
        XCTAssertTrue(AnchorPlausibility.isPlausibleCaret(
            NSRect(x: 335, y: 500, width: 2, height: 18), screens: screens))
    }

    /// 整行宽的矩形是合法的（编辑器一行文本），不能误伤。
    func testWideSingleLineIsStillACaret() {
        let line = NSRect(x: 0, y: 700, width: 2400, height: 20)
        XCTAssertTrue(AnchorPlausibility.isPlausibleCaret(line, screens: screens))
    }

    /// 零矩形、负尺寸、非有限值、屏幕外读数一律不可信。
    func testDegenerateRectsAreRejected() {
        XCTAssertFalse(AnchorPlausibility.isPlausibleCaret(.zero, screens: screens))
        XCTAssertFalse(AnchorPlausibility.isPlausibleCaret(
            NSRect(x: 10, y: 10, width: -5, height: 18), screens: screens))
        XCTAssertFalse(AnchorPlausibility.isPlausibleCaret(
            NSRect(x: 0, y: 0, width: 2, height: 0), screens: screens))
        XCTAssertFalse(AnchorPlausibility.isPlausibleCaret(
            NSRect(x: CGFloat.nan, y: 10, width: 2, height: 18), screens: screens))
        XCTAssertFalse(AnchorPlausibility.isPlausibleCaret(
            NSRect(x: 9000, y: 9000, width: 2, height: 18), screens: screens))
    }

    /// 零宽光标矩形（部分宿主只报高度）仍合法。
    func testZeroWidthCaretIsValid() {
        XCTAssertTrue(AnchorPlausibility.isPlausibleCaret(
            NSRect(x: 400, y: 300, width: 0, height: 18), screens: screens))
    }
}
