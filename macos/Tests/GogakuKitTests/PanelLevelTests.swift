import AppKit
import GogakuHost
import XCTest

/// 候选窗层级策略：宿主窗口层级 → 目标层级（纯函数）与真实窗口排序修正。
/// 背景（Bob 报告）：候选窗固定 .popUpMenu（101）会被宿主自建浮窗（层级更高，
/// 如 Bob 翻译浮窗）遮挡；自绘候选窗应读取 IMKTextInput.windowLevel 并在其
/// 上一层显示。策略纯函数在 GogakuHost.GGPanelTargetLevel（测试目标不依赖
/// GogakuInput，策略放宿主桥以便单测；CandidatePanel 调用同一实现）。
final class PanelLevelTests: XCTestCase {
    // MARK: - 纯函数 GGPanelTargetLevel

    func testBaselineConstantMatchesPopUpMenuLevel() {
        XCTAssertEqual(GGPanelLevelBaseline, NSWindow.Level.popUpMenu.rawValue)
        XCTAssertEqual(GGPanelLevelBaseline, 101)
        XCTAssertEqual(GGPanelLevelCeiling, 10000)
    }

    func testUnknownOrNonPositiveClientLevelUsesBaseline() {
        XCTAssertEqual(GGPanelTargetLevel(0, false), GGPanelLevelBaseline)
        XCTAssertEqual(GGPanelTargetLevel(500, false), GGPanelLevelBaseline, "层级未知时不采信数值")
        XCTAssertEqual(GGPanelTargetLevel(0, true), GGPanelLevelBaseline, "普通窗口（0）用基准")
        XCTAssertEqual(GGPanelTargetLevel(-3, true), GGPanelLevelBaseline)
        XCTAssertEqual(GGPanelTargetLevel(Int.min, true), GGPanelLevelBaseline)
    }

    func testHigherClientLevelRaisesByOneOnly() {
        XCTAssertEqual(GGPanelTargetLevel(100, true), GGPanelLevelBaseline, "客户端低于基准不抬高")
        XCTAssertEqual(GGPanelTargetLevel(101, true), 102, "同基准的宿主浮窗要压住候选窗")
        XCTAssertEqual(GGPanelTargetLevel(2000, true), 2001)
    }

    func testCeilingCapsAbnormalClientLevel() {
        XCTAssertEqual(GGPanelTargetLevel(GGPanelLevelCeiling - 1, true), GGPanelLevelCeiling)
        XCTAssertEqual(GGPanelTargetLevel(GGPanelLevelCeiling, true), GGPanelLevelCeiling)
        XCTAssertEqual(GGPanelTargetLevel(GGPanelLevelCeiling + 100_000, true), GGPanelLevelCeiling)
        XCTAssertEqual(GGPanelTargetLevel(Int.max, true), GGPanelLevelCeiling, "先钳后加，避免 +1 溢出")
    }

    // MARK: - 真实窗口排序（无 WindowServer 时跳过，不硬失败）

    private func orderedLayerAndIndex(of window: NSWindow, in list: [[String: Any]]) -> (layer: Int, index: Int)? {
        for (index, entry) in list.enumerated() {
            if let number = entry[kCGWindowNumber as String] as? Int, number == window.windowNumber,
               let layer = entry[kCGWindowLayer as String] as? Int {
                return (layer, index)
            }
        }
        return nil
    }

    private func onScreenList() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    }

    func testWindowLevelChangeReachesWindowServer() throws {
        // xctest 进程默认 .prohibited：窗口不会真正接入窗口服务器屏幕列表。
        // 需要先初始化 NSApplication（accessory）＋跑一圈事件循环；无
        // WindowServer 的 headless 环境仍按 XCTSkip 处理，不硬失败。
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        defer { app.setActivationPolicy(originalPolicy) }
        guard onScreenList() != nil else { throw XCTSkip("无 WindowServer 窗口列表") }

        // 与生产 prime() 同构：不可见（alpha 0）＋屏幕外坐标，只在窗口服务器里验证排序。
        func makePanel() -> NSPanel {
            let panel = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 10, height: 10),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.alphaValue = 0
            return panel
        }
        let low = makePanel()
        let high = makePanel()
        low.level = .popUpMenu
        let targetLevel = GGPanelTargetLevel(2000, true)   // 2001
        high.level = NSWindow.Level(rawValue: targetLevel)
        low.orderFrontRegardless()
        high.orderFrontRegardless()
        defer { low.orderOut(nil); high.orderOut(nil) }
        app.finishLaunching()
        // 窗口服务器列表异步更新：跑几轮事件循环再查询。
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true)
        }

        guard low.windowNumber != 0, high.windowNumber != 0 else { throw XCTSkip("窗口未接入 WindowServer") }
        guard let entries = onScreenList(),
              let lowInfo = orderedLayerAndIndex(of: low, in: entries),
              let highInfo = orderedLayerAndIndex(of: high, in: entries) else {
            throw XCTSkip("测试窗口不在窗口服务器列表中")
        }
        XCTAssertEqual(lowInfo.layer, NSWindow.Level.popUpMenu.rawValue)
        XCTAssertEqual(highInfo.layer, targetLevel, "层级改动真实到达窗口服务器")
        XCTAssertLessThan(highInfo.index, lowInfo.index, "更高层级排序在前，不再被宿主浮窗遮挡")
    }
}
