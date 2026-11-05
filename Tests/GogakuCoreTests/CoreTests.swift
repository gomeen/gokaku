import XCTest
@testable import GogakuCore

final class EngineTests: XCTestCase {
    func engine() throws -> ChineseEngine {
        let path = ProcessInfo.processInfo.environment["GOGAKU_ENGINE_DATA"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Gogaku/libime-1.1.17/data").path
        return try ChineseEngine(directory: URL(fileURLWithPath: path))
    }
    /// 学习组合会话（共享 C++ 核心，ABI v3）：与核心测试同源出厂数据。
    func learningSession() throws -> CompositionSession {
        let path = ProcessInfo.processInfo.environment["GOGAKU_ENGINE_DATA"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Gogaku/libime-1.1.17/data").path
        return try CompositionSession(config: .init(dictPath: path + "/sc.dict", modelPath: path + "/zh_CN.lm"))
    }
    func type(_ keys: String, on engine: ChineseEngine) throws -> EngineSnapshot {
        var result = EngineSnapshot()
        for c in keys.unicodeScalars { result = try engine.apply(.type(c.value)) }
        return result
    }
    func testFactoryXiaoheCompleteAndNonFirst() throws {
        let e = try engine()
        for (keys, target) in [("nihc", "你好"), ("kdhv", "开会"), ("woxlxtykyu", "我想学英语")] {
            _ = try e.apply(.cancel)
            let s = try type(keys, on: e)
            let candidate = try XCTUnwrap(s.candidates.first { $0.text == target })
            XCTAssertTrue(candidate.completes)
            XCTAssertEqual(candidate.range, RawRange(start: 0, length: keys.count))
            let selected = try e.apply(.select(candidate.index))
            XCTAssertEqual(selected.commit, target); XCTAssertFalse(selected.composing)
            XCTAssertEqual(try e.apply(.peek).commit, "")
        }
        let s = try type("nihc", on: e)
        let second = s.candidates[1]
        XCTAssertEqual(try e.apply(.select(second.index)).commit, second.text)
    }
    func testPartialSelectionUsesGraphRange() throws {
        let e = try engine(), s = try type("nihc", on: e)
        let ni = try XCTUnwrap(s.candidates.first { $0.text == "你" })
        XCTAssertEqual(ni.range, RawRange(start: 0, length: 2)); XCTAssertFalse(ni.completes)
        let partial = try e.apply(.select(ni.index))
        XCTAssertEqual(partial.commit, ""); XCTAssertEqual(partial.selectedLength, 2)
        XCTAssertTrue(partial.preedit.hasPrefix("你"))
        let hao = try XCTUnwrap(partial.candidates.first { $0.text == "好" })
        XCTAssertEqual(hao.range, RawRange(start: 2, length: 2))
        XCTAssertEqual(try e.apply(.select(hao.index)).commit, "你好")
    }
    func testPagingEditingAndInvalidCommandsPreserveState() throws {
        let e = try engine()
        _ = try type("ni", on: e)
        let page = try e.apply(.page(1))
        XCTAssertEqual(page.page, 1); XCTAssertEqual(page.candidates.first?.index, 9)
        XCTAssertThrowsError(try e.apply(.type(0x1F600)))
        XCTAssertThrowsError(try e.apply(.select(-1)))
        XCTAssertThrowsError(try e.apply(.select(100000)))
        XCTAssertEqual(try e.apply(.peek).raw, "ni")
        XCTAssertEqual(try e.apply(.backspace).raw, "n")
        XCTAssertFalse(try e.apply(.cancel).composing)
    }
    func testSessionStaleCandidateAndNoAutomaticCommit() throws {
        let s = try learningSession()
        try s.type("nihc")
        let stale = try XCTUnwrap(s.view.candidates.first)
        try s.type("m")
        XCTAssertNil(try s.choose(stale))
        s.cancel(); try s.type("nihc")
        let candidate = try XCTUnwrap(s.view.candidates.first)
        let commit = try XCTUnwrap(try s.choose(candidate))
        XCTAssertEqual(commit.text, "你好")
        XCTAssertNil(try s.choose(candidate)); XCTAssertEqual(s.view.raw, "")
    }
    func testEnglishUnicodeAndCompletionAreIndependent() throws {
        let s = try learningSession()
        s.configure(focus: 1, mode: .learning, direction: .enToZh)
        try s.type("metting 👩🏽‍💻 e\u{301} 12!")
        XCTAssertEqual(s.sourceExpressions().first?.text, s.view.raw)
        let old = s.view.stamp
        let request = TranslationRequest(stamp: old, sourceID: "english:full", source: s.view.raw, resource: "test-only")
        s.receive(TranslationResult(request: request, target: "会议"), approved: false)
        XCTAssertTrue(s.view.candidates.isEmpty)
        s.receive(TranslationResult(request: request, target: "会议"), approved: true)
        XCTAssertEqual(s.view.candidates.count, 1)
        try s.backspace()
        XCTAssertTrue(s.view.candidates.isEmpty)
        s.receive(TranslationResult(request: request, target: "旧结果"), approved: true)
        XCTAssertTrue(s.view.candidates.isEmpty)
        XCTAssertNil(try s.choose(Candidate(stamp: old, sourceID: "english:full", source: "", range: RawRange(start: 0, length: 1), target: "旧", explanation: "", resource: "test-only")))
    }
    func testLiteralChineseSegmentsAndPartialLearningConsumption() throws {
        let s = try learningSession()
        s.configure(focus: 1, mode: .learning, direction: .zhToEn)
        try s.type("nihc,12!kdhv")
        XCTAssertEqual(s.sourceExpressions().first?.text, "你好,12!开会")
        let partial = try XCTUnwrap(s.sourceExpressions().first { $0.text == "你" })
        XCTAssertEqual(partial.range, RawRange(start: 0, length: 2))
        let request = TranslationRequest(stamp: s.view.stamp, sourceID: partial.id, source: partial.text, resource: "test-only")
        s.receive(TranslationResult(request: request, target: "you"), approved: true)
        let commit = try XCTUnwrap(try s.choose(s.view.candidates[0]))
        XCTAssertEqual(commit.text, "you"); XCTAssertEqual(s.view.raw, "hc,12!kdhv")
    }
    func testCandidateAppendNeverRenumbersAndNavigationFreezes() throws {
        let s = try learningSession()
        s.configure(focus: 1, mode: .learning, direction: .zhToEn); try s.type("nihc")
        let sources = s.sourceExpressions()
        func add(_ source: SourceExpression) {
            let request = TranslationRequest(stamp: s.view.stamp, sourceID: source.id, source: source.text, resource: "test-only")
            s.receive(TranslationResult(request: request, target: "translated \(source.id)"), approved: true)
        }
        add(sources[0]); let id = s.view.candidates[0].id
        add(sources[1]); XCTAssertEqual(s.view.candidates[0].id, id)
        s.navigate(1); let count = s.view.candidates.count
        add(sources[2]); XCTAssertEqual(s.view.candidates.count, count)
    }
    func testFocusModeAndDirectionInvalidateCandidates() throws {
        let s = try learningSession(); try s.type("ni")
        let c = s.view.candidates[0]
        s.configure(focus: 2, mode: .learning, direction: .enToZh)
        XCTAssertNil(try s.choose(c)); XCTAssertNil(s.original())
        try s.restore("hello")
        XCTAssertNotEqual(s.view.stamp.composition, c.stamp.composition)
    }
    func testOriginalOnlyOnceAndScalarLimit() throws {
        let s = try learningSession()
        s.configure(focus: 1, mode: .learning, direction: .enToZh)
        try s.type(String(repeating: "😀", count: 512)); try s.type("x")
        XCTAssertEqual(s.view.raw.unicodeScalars.count, 512)
        XCTAssertTrue(s.view.status.contains("512"))
        XCTAssertEqual(s.original()?.text.unicodeScalars.count, 512)
        XCTAssertNil(s.original())
        try s.type("e\u{301}"); try s.backspace(); XCTAssertEqual(s.view.raw, "")
    }
    func testDraftsNeverOverwriteAndExplicitTake() {
        let drafts = DraftStore()
        drafts.save(application: "test", mode: .normal, direction: .zhToEn, raw: "ni")
        drafts.save(application: "test", mode: .normal, direction: .zhToEn, raw: "hc")
        XCTAssertEqual(drafts.drafts.count, 2)
        let id = drafts.drafts[0].id
        XCTAssertEqual(drafts.take(id: id)?.raw, "ni"); XCTAssertNil(drafts.take(id: id))
        drafts.clear(); XCTAssertTrue(drafts.drafts.isEmpty)
    }
    func testSettingsThemeDefaultPreservesLegacyFiles() throws {
        let legacy = Data(#"{"recording":false,"excludedApplications":["com.example.App"]}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: legacy)
        XCTAssertFalse(settings.recording)
        XCTAssertEqual(settings.excludedApplications, ["com.example.App"])
        XCTAssertEqual(settings.candidateTheme, .rimeMacOSLike)
        let renamed = Data(#"{"recording":false,"candidateTheme":"qingjian-like"}"#.utf8)
        let tolerated = try JSONDecoder().decode(Settings.self, from: renamed)
        XCTAssertFalse(tolerated.recording)
        XCTAssertEqual(tolerated.candidateTheme, .rimeMacOSLike)
        let encoded = try JSONEncoder().encode(settings)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("rime-macos-like"))
    }
}

final class StoreTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    func event(now: Date = Date(), id: UUID = UUID()) -> LearningEvent {
        LearningEvent(id: id, source: "hello", target: "你好", direction: .enToZh, category: "activeAttempt", issues: [], application: "test.app", now: now)
    }
    func list(_ store: LearningStore, now: Date = Date()) throws -> [LearningEvent] {
        let done = expectation(description: "read"); var value: Result<[LearningEvent], Error>!
        store.list(now: now) { value = $0; done.fulfill() }; wait(for: [done], timeout: 5)
        return try value.get()
    }
    func testDedupExpiryAndPauseExclusion() throws {
        let store = LearningStore(directory: directory), e = event()
        XCTAssertTrue(store.append(e)); XCTAssertTrue(store.append(e))
        XCTAssertEqual(try list(store).count, 1)
        XCTAssertEqual(try list(store, now: e.expiresAt).count, 0)
        store.policy(recording: false, excludedApplications: [])
        XCTAssertFalse(store.append(event()))
        store.policy(recording: true, excludedApplications: ["test.app"])
        XCTAssertFalse(store.append(event()))
    }
    func testDeleteTombstoneRejectsLateDuplicate() throws {
        let store = LearningStore(directory: directory), e = event()
        store.append(e)
        let done = expectation(description: "delete")
        store.delete(ids: [e.id]) { XCTAssertTrue($0); done.fulfill() }
        wait(for: [done], timeout: 5)
        store.append(e)
        XCTAssertTrue(try list(store).isEmpty)
    }
    func testStorageFailureDoesNotThrowIntoInput() {
        let path = directory.appendingPathComponent("blocked")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! Data([1]).write(to: path)
        let store = LearningStore(directory: path)
        let done = expectation(description: "failure")
        store.onFailure = { done.fulfill() }
        XCTAssertTrue(store.append(event())); wait(for: [done], timeout: 5)
    }
}
