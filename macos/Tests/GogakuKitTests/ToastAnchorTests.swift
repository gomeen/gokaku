import XCTest
import AppKit
@testable import GogakuKit

/// 模式切换提示浮层的锚点解析（2026-11-11，用户裁决：与候选窗首键同一套
/// 规则）。两条核心：①无组合时的宿主读数可能是陈旧／屏幕外坐标（Orca 终端
/// 按选区读到 shell 行，提示就跑到左上角），要有参照物与有效性双闸；
/// ②回退顺序与 AnchorFallback 一致：pre-read ＞ 上一组合锚点 ＞ 鼠标位置。
final class ToastAnchorTests: XCTestCase {
    /// 1920×1080 主屏，菜单栏＋Dock 占掉后可视区 [0, 25]–[1920, 1055]。
    private let screens = [ScreenFrame(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                                       visibleFrame: NSRect(x: 0, y: 25, width: 1920, height: 1030))]
    private let carried = NSRect(x: 760, y: 300, width: 0, height: 17)
    /// 同字段下一字的正常前进（横向 +60pt，同一行）。
    private let nextChar = NSRect(x: 820, y: 300, width: 0, height: 17)
    /// Orca 终端无组合时的陈旧读数：同为整屏但跨多行（shell 行在顶部）。
    private let staleTop = NSRect(x: 326, y: 900, width: 0, height: 17)
    /// 宿主返回的垃圾坐标（屏幕外）：几何层只会把它钳到左上角。
    private let offScreen = NSRect(x: 0, y: 1410, width: 0, height: 17)
    private let mouse = NSRect(x: 500, y: 700, width: 0, height: 18)

    private func resolve(carried: NSRect? = nil, preRead: NSRect = .zero,
                         mouseCaret: NSRect? = nil) -> NSRect? {
        ToastAnchor.resolve(preRead: preRead, carried: carried,
                            mouseCaret: mouseCaret ?? mouse, screens: screens)
    }

    func testStalePreReadIsRejectedInFavourOfCarriedAnchor() {
        XCTAssertEqual(resolve(carried: carried, preRead: staleTop), carried,
                       "跨多行跳变的本次读数判为陈旧，保留上一组合锚点")
    }

    func testPlausiblePreReadRefinesCarriedAnchor() {
        XCTAssertEqual(resolve(carried: carried, preRead: nextChar), nextChar,
                       "同行前进＝宿主读数可信且比上一组合锚点更贴近光标")
    }

    func testOffScreenPreReadWithoutAnchorFallsBackToMouse() {
        XCTAssertEqual(resolve(preRead: offScreen), mouse,
                       "屏幕外读数是垃圾坐标，宁可退回鼠标也不甩到左上角")
        XCTAssertEqual(resolve(preRead: staleTop), staleTop,
                       "屏幕内的首入读数（本字段尚无锚点）仍采信，与候选窗首键同待遇")
    }

    func testOffScreenPreReadKeepsCarriedAnchor() {
        XCTAssertEqual(resolve(carried: carried, preRead: offScreen), carried)
    }

    func testOffScreenCarriedAnchorIsIgnored() {
        XCTAssertEqual(resolve(carried: offScreen, preRead: nextChar), nextChar,
                       "上一组合锚点已不在任何屏幕内（窗口移动／显示器变更）＝视同无锚点")
        XCTAssertEqual(resolve(carried: offScreen, preRead: .zero), mouse)
    }

    func testCarriedAnchorUsedWhenPreReadIsZero() {
        XCTAssertEqual(resolve(carried: carried, preRead: .zero), carried,
                       "宿主读不出矩形（企业微信长段落）时用上一组合锚点")
        XCTAssertEqual(resolve(carried: .zero, preRead: .zero), mouse,
                       "零值 carried 视同无锚点，退回鼠标位置")
    }

    func testNilWhenNothingAvailable() {
        XCTAssertNil(ToastAnchor.resolve(preRead: .zero, carried: nil, mouseCaret: nil, screens: screens),
                     "全部不可得＝无处可放，不显示")
        XCTAssertNil(ToastAnchor.resolve(preRead: .zero, carried: .zero, mouseCaret: nil, screens: screens))
    }
}
