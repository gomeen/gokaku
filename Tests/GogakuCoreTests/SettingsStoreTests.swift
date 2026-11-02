import XCTest
import AppKit
@testable import GogakuCore

/// 设置写入协调器：立即保存／合并提交／失败保留与重试／最新改动胜出／
/// 仅成功落盘后通知（2026-11-03 定稿）。
final class SettingsStoreTests: XCTestCase {
    private var directory: URL!
    private let changedNotification = Notification.Name("org.gogaku.settings.changed")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gogaku-settings-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func readDisk() throws -> Settings {
        let data = try Data(contentsOf: directory.appendingPathComponent("settings.json"))
        return try JSONDecoder().decode(Settings.self, from: data)
    }

    func testImmediateSubmitWritesAndNotifies() throws {
        // 通知观察先于提交注册，避免其他测试或历史通知误触发。
        let received = expectation(description: "changed notification after successful write")
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: changedNotification, object: nil, queue: nil) { _ in
            received.fulfill()
        }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }

        let store = SettingsStore(directory: directory)
        var settings = Settings()
        settings.candidateFontSize = 15
        let done = expectation(description: "flush")
        store.submit(settings) { outcome in
            guard case .success = outcome else { XCTFail("提交失败"); return }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        wait(for: [received], timeout: 2)
        XCTAssertEqual(try readDisk().candidateFontSize, 15)
    }

    func testCoalescedSubmitKeepsLatestValue() throws {
        let store = SettingsStore(directory: directory)
        var first = Settings(); first.candidateFontSize = 12
        var second = Settings(); second.candidateFontSize = 16
        let done = expectation(description: "final flush")
        store.submit(first, coalesce: true)
        store.submit(second, coalesce: true) { _ in done.fulfill() }
        wait(for: [done], timeout: 3)
        // 合并后只有最新值落盘，旧值不产生中间状态残留。
        XCTAssertEqual(try readDisk().candidateFontSize, 16)
    }

    func testWriteFailureKeepsPendingAndRetrySucceeds() throws {
        // 目录不可写：失败保留待保存改动，不伪报成功；修复后重试成功。
        var settings = Settings()
        settings.fuzzyPinyin = ["z-zh"]
        let locked = FileManager.default.temporaryDirectory
            .appendingPathComponent("gogaku-locked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let store = SettingsStore(directory: locked)
        // 把目标目录设为不可写，使 settings.json 写入失败。
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)

        let failed = expectation(description: "failed")
        var reportedFailure = false
        store.submit(settings) { outcome in
            if case .failure = outcome { reportedFailure = true; failed.fulfill() }
        }
        wait(for: [failed], timeout: 3)
        XCTAssertTrue(reportedFailure, "写入失败必须上报失败，不得伪报成功")
        XCTAssertFalse(FileManager.default.fileExists(atPath: locked.appendingPathComponent("settings.json").path))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        let retried = expectation(description: "retried")
        store.retry { outcome in
            guard case .success = outcome else { XCTFail("重试仍失败"); return }
            retried.fulfill()
        }
        wait(for: [retried], timeout: 3)
        let data = try Data(contentsOf: locked.appendingPathComponent("settings.json"))
        let written = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(written.fuzzyPinyin, ["z-zh"], "重试必须写入保留的待保存改动")
    }

    func testSecondInstanceMergesInsteadOfOverwriting() throws {
        // 模拟两个进程／两页：实例 A 写入的偏好不被实例 B 的整份快照回滚
        //（旧做法是旧整份快照覆盖磁盘；协调器按顶层字段差异合并）。
        var first = Settings()
        first.applications = ["com.app.one": AppPreference()]
        let instanceA = SettingsStore(directory: directory)
        let doneA = expectation(description: "A")
        instanceA.submit(first) { _ in doneA.fulfill() }
        wait(for: [doneA], timeout: 2)

        // 实例 B 在 A 写入之后创建（基线含 A 的改动），按真实流程从磁盘加载后
        // 只改快捷键；基线中与加载值相同的字段（如 A 写入的偏好）不复制，不被回滚。
        var second = Settings.load(at: directory)
        second.modeShortcut = Shortcut(key: "m", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
        let instanceB = SettingsStore(directory: directory)
        let doneB = expectation(description: "B")
        instanceB.submit(second) { _ in doneB.fulfill() }
        wait(for: [doneB], timeout: 2)

        let disk = try readDisk()
        XCTAssertEqual(disk.modeShortcut.key, "m", "B 的改动必须落盘")
        XCTAssertNotNil(disk.applications["com.app.one"], "A 已写入的偏好不得被 B 回滚")
    }

    func testStaleBaselineDoesNotClobberForeignFields() throws {
        // 实例 A 的基线过期（磁盘被外部进程改写）时，只提交 A 真正修改的字段。
        var original = Settings()
        original.ignoredWords = ["keepme"]
        try original.save(at: directory)

        var modified = original
        modified.ignoredWords = ["keepme", "brand"]   // A 只改这一字段
        let store = SettingsStore(directory: directory)

        // 外部写入（模拟输入法进程在 A 提交前写入的偏好）。
        var external = original
        external.applications = ["com.foreign": AppPreference()]
        try external.save(at: directory)

        let done = expectation(description: "merged")
        store.submit(modified) { _ in done.fulfill() }
        wait(for: [done], timeout: 2)

        let disk = try readDisk()
        XCTAssertEqual(disk.ignoredWords, ["keepme", "brand"], "A 修改的字段落盘")
        XCTAssertNotNil(disk.applications["com.foreign"], "外部进程写入不得被过期基线覆盖")
    }

    func testMergeOnlyCopiesChangedTopLevelFields() throws {
        let pending = ["a": 1, "b": "same", "c": [1, 2, 3]] as [String: Any]
        let baseline = ["a": 0, "b": "same", "c": [1, 2, 3]] as [String: Any]
        let disk = ["a": 99, "b": "same", "c": [1, 2, 3], "foreign": true] as [String: Any]
        let merged = SettingsStore.merge(pending: pending, baseline: baseline, disk: disk)
        XCTAssertEqual(merged["a"] as? Int, 1, "变化字段以 pending 为准")
        XCTAssertEqual(merged["b"] as? String, "same")
        XCTAssertEqual(merged["c"] as? [Int], [1, 2, 3])
        XCTAssertEqual(merged["foreign"] as? Bool, true, "磁盘独有字段保留")
    }
}
