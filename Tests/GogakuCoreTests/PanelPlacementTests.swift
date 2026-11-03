import XCTest
import AppKit
@testable import GogakuCore

/// 候选窗放置几何：边缘、负坐标、零宽光标、无效矩形、多屏（离线假屏幕）。
/// 覆盖 2026-11-03 定稿：默认插入点右下，空间不足上翻，最终不越界；
/// 完全不在任何屏幕内的锚点不得显示。
final class PanelPlacementTests: XCTestCase {
    /// 1920×1080 主屏，菜单栏/Dock 假设可视区 [0, 25]–[1920, 1055]。
    private let main = ScreenFrame(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                                   visibleFrame: NSRect(x: 0, y: 25, width: 1920, height: 1030))
    /// 左侧副屏（负坐标），可用区偏小。
    private let side = ScreenFrame(frame: NSRect(x: -1440, y: 0, width: 1440, height: 900),
                                   visibleFrame: NSRect(x: -1440, y: 0, width: 1440, height: 875))
    private let size = NSSize(width: 200, height: 300)

    func testDefaultPlacementBelowCaret() {
        let caret = NSRect(x: 800, y: 700, width: 0, height: 17)
        let origin = PanelPlacement.origin(anchor: caret, panelSize: size, screens: [main])
        XCTAssertEqual(origin?.x, 800, "默认贴插入点左侧起点")
        XCTAssertEqual(origin?.y, 700 - 300 - 8, "插入点右下（下方留 8pt）")
    }

    func testFlipUpWhenInsufficientSpaceBelow() {
        // 光标贴近屏幕底部：下方放不下时上翻。
        let caret = NSRect(x: 800, y: 40, width: 0, height: 17)
        let origin = PanelPlacement.origin(anchor: caret, panelSize: size, screens: [main])
        XCTAssertEqual(origin?.y, 40 + 17 + 8, "上翻到光标上方 + 8pt")
    }

    func testClampedInsideVisibleFrameOnAllEdges() {
        // 右缘：面板右侧不能越界。
        let right = PanelPlacement.origin(anchor: NSRect(x: 1900, y: 600, width: 0, height: 17),
                                          panelSize: size, screens: [main])
        XCTAssertLessThanOrEqual(right!.x + size.width, main.visibleFrame.maxX - PanelPlacement.margin)
        // 左缘：clamp 不低于可视区左缘。
        let left = PanelPlacement.origin(anchor: NSRect(x: 2, y: 600, width: 0, height: 17),
                                         panelSize: size, screens: [main])
        XCTAssertGreaterThanOrEqual(left!.x, main.visibleFrame.minX + PanelPlacement.margin)
        // 上翻后仍超顶（面板高于可视区一半且光标在中部）：回推到顶部内边界。
        let middle = PanelPlacement.origin(anchor: NSRect(x: 800, y: 300, width: 0, height: 17),
                                           panelSize: size, screens: [main])
        XCTAssertLessThanOrEqual(middle!.y + size.height, main.visibleFrame.maxY - PanelPlacement.margin,
                                 "重算高度后保证面板不越界")
    }

    func testNegativeCoordinatesOnSideDisplay() {
        // 副屏负坐标：放置在包含锚点的屏幕内，且不越出该屏可视区。
        let caret = NSRect(x: -700, y: 500, width: 0, height: 17)
        let origin = PanelPlacement.origin(anchor: caret, panelSize: size, screens: [main, side])
        XCTAssertNotNil(origin)
        XCTAssertTrue(side.visibleFrame.contains(NSRect(origin: origin!, size: size)),
                      "面板完全落在副屏可视区内")
        XCTAssertEqual(origin?.x, -700)
    }

    func testZeroWidthCaretRectIsValid() {
        let origin = PanelPlacement.origin(anchor: NSRect(x: 800, y: 700, width: 0, height: 17),
                                           panelSize: size, screens: [main])
        XCTAssertNotNil(origin, "零宽光标矩形可以有效")
    }

    func testInvalidRectanglesAreRejected() {
        // 非有限值。
        XCTAssertNil(PanelPlacement.origin(anchor: NSRect(x: CGFloat.infinity, y: 0, width: 0, height: 17),
                                           panelSize: size, screens: [main]))
        XCTAssertNil(PanelPlacement.origin(anchor: NSRect(x: CGFloat.nan, y: 0, width: 0, height: 17),
                                           panelSize: size, screens: [main]))
        // 负尺寸（origin:size: 构造保留原始 size 值；x:y:width:height: 会被规范化）。
        XCTAssertNil(PanelPlacement.origin(
            anchor: NSRect(origin: CGPoint(x: 800, y: 700), size: CGSize(width: -10, height: 17)),
            panelSize: size, screens: [main]))
        XCTAssertNil(PanelPlacement.origin(
            anchor: NSRect(origin: CGPoint(x: 800, y: 700), size: CGSize(width: 0, height: -17)),
            panelSize: size, screens: [main]))
        // 全零矩形（无可确认插入点）。
        XCTAssertNil(PanelPlacement.origin(anchor: .zero, panelSize: size, screens: [main]))
        // 面板尺寸非法。
        XCTAssertNil(PanelPlacement.origin(anchor: NSRect(x: 800, y: 700, width: 0, height: 17),
                                           panelSize: .zero, screens: [main]))
    }

    func testAnchorOutsideAllScreensIsHidden() {
        // 完全不在任何屏幕内的锚点不得显示（无「任意屏幕」回退）。
        XCTAssertNil(PanelPlacement.origin(anchor: NSRect(x: 5000, y: 700, width: 0, height: 17),
                                           panelSize: size, screens: [main]))
        XCTAssertNil(PanelPlacement.origin(anchor: NSRect(x: 800, y: 700, width: 0, height: 17),
                                           panelSize: size, screens: []))
    }

    func testPanelLargerThanScreenIsRejected() {
        let huge = NSSize(width: 2500, height: 1200)
        XCTAssertNil(PanelPlacement.origin(anchor: NSRect(x: 800, y: 700, width: 0, height: 17),
                                           panelSize: huge, screens: [main]))
    }

    func testContainmentCheckForStickyOrigin() {
        XCTAssertTrue(PanelPlacement.isContained(origin: NSPoint(x: 100, y: 100), panelSize: size, screens: [main]))
        XCTAssertFalse(PanelPlacement.isContained(origin: NSPoint(x: 1800, y: 100), panelSize: size, screens: [main]),
                       "越界 origin 不可复用")
        XCTAssertFalse(PanelPlacement.isContained(origin: NSPoint(x: 100, y: 100), panelSize: size, screens: []),
                       "无屏幕时不可复用")
    }

    // MARK: 切换提示浮层（2026-11 用户裁决：提示位置跟随输入位置）

    private let toastSize = NSSize(width: 80, height: 36)

    func testToastPrefersAboveCaret() {
        // 优先锚点上方（下方常被候选窗占用）。
        let caret = NSRect(x: 800, y: 700, width: 0, height: 17)
        let origin = PanelPlacement.toastOrigin(anchor: caret, panelSize: toastSize, screens: [main])
        XCTAssertEqual(origin?.x, 800)
        XCTAssertEqual(origin?.y, 700 + 17 + 8, "光标上方 + 8pt")
    }

    func testToastFallsBelowWhenNoRoomAbove() {
        // 光标贴近屏幕顶部：上方放不下时移到下方。
        let caret = NSRect(x: 800, y: 1000, width: 0, height: 17)
        let origin = PanelPlacement.toastOrigin(anchor: caret, panelSize: toastSize, screens: [main])
        XCTAssertEqual(origin?.y, 1000 - 36 - 8)
    }

    func testToastClampsHorizontalAndRejectsInvalidAnchor() {
        // 右缘钳制。
        let right = PanelPlacement.toastOrigin(anchor: NSRect(x: 1900, y: 600, width: 0, height: 17),
                                               panelSize: toastSize, screens: [main])
        XCTAssertLessThanOrEqual(right!.x + toastSize.width, main.visibleFrame.maxX - PanelPlacement.margin)
        // 零矩形与屏外锚点回退 nil（调用方用固定位置）。
        XCTAssertNil(PanelPlacement.toastOrigin(anchor: .zero, panelSize: toastSize, screens: [main]))
        XCTAssertNil(PanelPlacement.toastOrigin(anchor: NSRect(x: 5000, y: 600, width: 0, height: 17),
                                                panelSize: toastSize, screens: [main]))
        // 副屏负坐标跟随。
        let sideOrigin = PanelPlacement.toastOrigin(anchor: NSRect(x: -700, y: 500, width: 0, height: 17),
                                                    panelSize: toastSize, screens: [main, side])
        XCTAssertEqual(sideOrigin?.x, -700)
    }
}
