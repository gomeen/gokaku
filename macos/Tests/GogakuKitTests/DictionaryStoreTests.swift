import XCTest
@testable import GogakuKit

/// 扩展词库存储回归（合同见 docs/dictionaries.md §三／§五；解析与转换向量在
/// shared/GogakuCore/tests/dict_import_test.cpp，这里覆盖 Swift 侧：目录注入、
/// 导入／取消／重复导入错误映射、开关与删除落盘、损坏元数据报告）。
final class DictionaryStoreTests: XCTestCase {
    var supportDir: URL!
    var engineDataDir: URL!
    private let previousSupport = ProcessInfo.processInfo.environment["GOGAKU_SUPPORT_DIRECTORY"]
    private let previousEngineData = ProcessInfo.processInfo.environment["GOGAKU_ENGINE_DATA"]

    private var engineDataSource: URL!

    override func setUpWithError() throws {
        supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gogaku-dictstore-\(UUID().uuidString)")
        engineDataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gogaku-dictstore-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engineDataDir, withIntermediateDirectories: true)
        // 出厂词典：与本机 libime 缓存同一份（缺失则跳过，与 NormalEngineTests 同口径）。
        if let previous = previousEngineData {
            engineDataSource = URL(fileURLWithPath: previous, isDirectory: true)
        } else {
            engineDataSource = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/Gogaku/libime-1.1.17/data", isDirectory: true)
        }
        let source = engineDataSource.appendingPathComponent("sc.dict")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: source.path), "缺 libime 出厂数据")
        try FileManager.default.copyItem(at: source, to: engineDataDir.appendingPathComponent("sc.dict"))
        setenv("GOGAKU_SUPPORT_DIRECTORY", supportDir.path, 1)
        setenv("GOGAKU_ENGINE_DATA", engineDataDir.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousSupport {
            setenv("GOGAKU_SUPPORT_DIRECTORY", previousSupport, 1)
        } else {
            unsetenv("GOGAKU_SUPPORT_DIRECTORY")
        }
        if let previousEngineData {
            setenv("GOGAKU_ENGINE_DATA", previousEngineData, 1)
        } else {
            unsetenv("GOGAKU_ENGINE_DATA")
        }
        try? FileManager.default.removeItem(at: supportDir)
        try? FileManager.default.removeItem(at: engineDataDir)
    }

    private var dictionariesDir: URL {
        supportDir.appendingPathComponent("dictionaries", isDirectory: true)
    }

    private func writeSource(_ name: String, _ content: String) throws -> URL {
        let url = supportDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: 导入

    func testImportCreatesDictAndMetadata() throws {
        let url = try writeSource("words.txt", "网络热词 wang'luo're'ci\n网络用语 wang'luo'yong'yu\n")
        let result = try DictionaryStore.importFile(at: url)
        XCTAssertTrue(result.id.hasPrefix("import-"))
        XCTAssertEqual(result.entryCount, 2)
        XCTAssertEqual(result.dropped["duplicateFactory"], 0)

        let listing = try DictionaryStore.list(learningAvailable: true)
        XCTAssertEqual(listing.entries.count, 1)
        XCTAssertEqual(listing.entries[0].id, result.id)
        XCTAssertEqual(listing.entries[0].entryCount, 2)
        XCTAssertTrue(listing.entries[0].enabled)
        XCTAssertTrue(listing.entries[0].learning)   // 小词库＋flag
        XCTAssertEqual(listing.entries[0].estimatedBytes, listing.entries[0].sizeBytes * 2)
        XCTAssertFalse(listing.warn)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dictionariesDir.appendingPathComponent("\(result.id).dict").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dictionariesDir.appendingPathComponent("\(result.id).json").path))
    }

    func testDuplicateImportRejected() throws {
        let url = try writeSource("dup.txt", "网络热词 wang'luo're'ci\n")
        _ = try DictionaryStore.importFile(at: url)
        XCTAssertThrowsError(try DictionaryStore.importFile(at: url)) { error in
            guard case DictionaryStore.StoreError.duplicate = error else {
                return XCTFail("期望重复导入错误，实际 \(error)")
            }
        }
    }

    func testCancelViaProgress() throws {
        let url = try writeSource("cancel.txt", "网络热词 wang'luo're'ci\n")
        XCTAssertThrowsError(
            try DictionaryStore.importFile(at: url) { _ in false }
        ) { error in
            guard case DictionaryStore.StoreError.cancelled = error else {
                return XCTFail("期望取消错误，实际 \(error)")
            }
        }
        // 取消不留半成品。
        let listing = try DictionaryStore.list(learningAvailable: false)
        XCTAssertTrue(listing.entries.isEmpty)
    }

    func testInvalidFormatError() throws {
        let url = try writeSource("bad.bin", "不是词库")
        XCTAssertThrowsError(try DictionaryStore.importFile(at: url)) { error in
            guard case DictionaryStore.StoreError.io = error else {
                return XCTFail("期望格式错误，实际 \(error)")
            }
        }
    }

    // MARK: 开关与删除

    func testToggleAndRemove() throws {
        let url = try writeSource("toggle.txt", "网络热词 wang'luo're'ci\n")
        let result = try DictionaryStore.importFile(at: url)
        try DictionaryStore.setEnabled(false, id: result.id)
        var listing = try DictionaryStore.list(learningAvailable: false)
        XCTAssertFalse(listing.entries[0].enabled)
        XCTAssertEqual(listing.enabledEstimatedBytes, 0)

        try DictionaryStore.remove(id: result.id)
        listing = try DictionaryStore.list(learningAvailable: false)
        XCTAssertTrue(listing.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dictionariesDir.appendingPathComponent("\(result.id).json").path))
    }

    func testCorruptMetadataBackedUp() throws {
        let url = try writeSource("corrupt.txt", "网络热词 wang'luo're'ci\n")
        let result = try DictionaryStore.importFile(at: url)
        try "{not json".write(to: dictionariesDir.appendingPathComponent("\(result.id).json"),
                              atomically: true, encoding: .utf8)
        let listing = try DictionaryStore.list(learningAvailable: false)
        XCTAssertTrue(listing.entries.isEmpty)
        XCTAssertEqual(listing.corrupt.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dictionariesDir.appendingPathComponent("\(result.id).json.corrupt").path))
    }

    func testMemoryWarningOverThreshold() throws {
        // 伪造大 sizeBytes 元数据：不落 200MB 文件，只验证提醒口径（list 只读元数据）。
        let url = try writeSource("big.txt", "网络热词 wang'luo're'ci\n")
        let result = try DictionaryStore.importFile(at: url)
        let metaURL = dictionariesDir.appendingPathComponent("\(result.id).json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: metaURL)) as? [String: Any])
        var patched = object
        patched["sizeBytes"] = 130_000_000
        try JSONSerialization.data(withJSONObject: patched)
            .write(to: metaURL)
        let listing = try DictionaryStore.list(learningAvailable: true)
        XCTAssertTrue(listing.warn)
        XCTAssertFalse(listing.entries[0].learning)   // 超过学习单本阈值 8MiB
    }
}
