import XCTest
@testable import GogakuKit

/// 提交合并等待窗口（2026-11-20 时序修复裁决 B）两分支单测：
/// 1. 源文匹配 → fulfil 结束等待且超时兜底不触发（结果直接上屏）；
/// 2. 超时 → 兜底携源文触发（回退自发 commit 请求），且回退后迟到的
///    同源文结果不得再合并（只入译文缓存）。
final class CommitMergeWindowTests: XCTestCase {
    /// 分支 1：等待期间收到同源文结果 → 直接完成，超时兜底永不触发。
    func testFulfilMatchingSourceEndsWaitAndSuppressesTimeout() {
        let timeout = XCTestExpectation(description: "超时兜底不应触发")
        timeout.isInverted = true
        let window = CommitMergeWindow(waitLimit: 0.05, onTimeout: { _ in timeout.fulfill() })
        window.begin(source: "你好")
        XCTAssertEqual(window.waitingFor, "你好")
        XCTAssertTrue(window.fulfilIfWaiting(source: "你好"), "同源文结果应结束等待并返回可合并")
        XCTAssertFalse(window.isWaiting, "fulfil 后等待应结束，兜底随之取消")
        wait(for: [timeout], timeout: 0.3)
    }

    /// 分支 2：预译结果迟迟不回 → 兜底携源文触发（回退自发 commit 请求）。
    func testTimeoutFiresFallbackWithSource() {
        let fallback = XCTestExpectation(description: "超时回退")
        let window = CommitMergeWindow(waitLimit: 0.05, onTimeout: { source in
            XCTAssertEqual(source, "你好")
            fallback.fulfill()
        })
        window.begin(source: "你好")
        wait(for: [fallback], timeout: 2)
        XCTAssertFalse(window.isWaiting, "兜底触发后等待应结束")
    }

    /// 不同源文的结果不得结束等待（兜底继续生效，直到超时回退）。
    func testFulfilMismatchKeepsWaitingUntilTimeout() {
        let fallback = XCTestExpectation(description: "超时回退")
        let window = CommitMergeWindow(waitLimit: 0.05, onTimeout: { source in
            XCTAssertEqual(source, "你好", "兜底应携带仍在等待的源文")
            fallback.fulfill()
        })
        window.begin(source: "你好")
        XCTAssertFalse(window.fulfilIfWaiting(source: "你号"))
        XCTAssertEqual(window.waitingFor, "你好")
        wait(for: [fallback], timeout: 2)
    }

    /// 显式取消（提交完成／失焦）既结束等待也不触发兜底。
    func testCancelDropsWaitWithoutFiringFallback() {
        let fallback = XCTestExpectation(description: "超时回退不应触发")
        fallback.isInverted = true
        let window = CommitMergeWindow(waitLimit: 0.05, onTimeout: { _ in fallback.fulfill() })
        window.begin(source: "你好")
        window.cancel()
        XCTAssertFalse(window.isWaiting)
        wait(for: [fallback], timeout: 0.3)
    }

    /// 超时回退后的迟到同源文结果不得重新合并（只入译文缓存）；
    /// 兜底也只触发一次。
    func testLateResultAfterTimeoutDoesNotMerge() {
        let fallback = XCTestExpectation(description: "超时回退只触发一次")
        fallback.assertForOverFulfill = true
        let window = CommitMergeWindow(waitLimit: 0.05, onTimeout: { _ in fallback.fulfill() })
        window.begin(source: "你好")
        wait(for: [fallback], timeout: 2)
        XCTAssertFalse(window.fulfilIfWaiting(source: "你好"), "超时后的迟到结果不应合并")
    }
}
