import XCTest
@testable import GogakuCore
import CGogakuCore

/// 共享 C++ 普通模式核心的 Swift 桥接回归。
/// 详细事件轨迹向量在 native/GogakuCore/tests（195 项断言）；这里覆盖桥接层合同：
/// 配置传递、事件映射、自定义词语读写与校验、快速添加记录。
final class NormalEngineTests: XCTestCase {
    var dir: URL!
    var dictPath: URL!
    var wordsPath: URL!
    var englishPath: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dictPath = dir.appendingPathComponent("sc.dict")
        wordsPath = dir.appendingPathComponent("custom-words.tsv")
        englishPath = dir.appendingPathComponent("english.txt")
        // 与既有 Swift 测试一致：使用本机 libime 出厂数据。
        let source = URL(fileURLWithPath: engineModelPath().replacingOccurrences(of: "/zh_CN.lm", with: "/sc.dict"))
        try XCTSkipIf(!FileManager.default.fileExists(atPath: source.path), "缺 libime 出厂数据")
        try FileManager.default.copyItem(at: source, to: dictPath)
        try "company 1000\ncompare 900\n".write(to: englishPath, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func engine() -> NormalEngine {
        var config = NormalEngineConfig(dictPath: dictPath.path, modelPath: engineModelPath())
        config.customWordsPath = wordsPath.path
        config.englishWordsPath = englishPath.path
        config.englishEnabled = true
        config.freqEnabled = false   // 桥接测试不写用户目录
        return NormalEngine(config: config)!
    }

    private func engineModelPath() -> String {
        if let env = ProcessInfo.processInfo.environment["GOGAKU_ENGINE_DATA"] {
            return env + "/zh_CN.lm"
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Gogaku/libime-1.1.17/data/zh_CN.lm").path
    }

    private func type(_ keys: String, on engine: NormalEngine) -> NormalSnapshot? {
        var snap: NormalSnapshot?
        for ch in keys { snap = engine.handle(.text(String(ch)), app: "test.app", field: "f", timeMs: 0) }
        return snap
    }

    func testBridgeAbiVersion() {
        XCTAssertEqual(gc_abi_version(), 2)
        XCTAssertEqual(gc_abi_check(2), 0)
        XCTAssertEqual(gc_abi_check(1), 1)
    }

    func testXiaoheCommitAndEnglishCandidates() throws {
        let engine = engine()
        let snap = try XCTUnwrap(type("nihc", on: engine))
        XCTAssertTrue(snap.composing)
        XCTAssertEqual(snap.rawInput, "nihc")
        XCTAssertEqual(snap.marked, snap.preedit)
        XCTAssertEqual(snap.preedit, "ni'hao")
        XCTAssertEqual(snap.candidates.first?.text, "你好")
        XCTAssertEqual(snap.candidates.first?.kind, Int32(GC_CAND_CHINESE))
        let commit = try XCTUnwrap(engine.handle(.space, app: "test.app", field: "f", timeMs: 0))
        XCTAssertEqual(commit.commit, "你好")
        XCTAssertFalse(commit.composing)
        XCTAssertEqual(commit.marked, "")
        XCTAssertEqual(commit.rawInput, "")
    }

    func testShiftClickCommitAndToggle() throws {
        let engine = engine()
        _ = type("nihc", on: engine)
        // 组合中 Shift：原编码上屏、不切英文（规格）。
        let shift = try XCTUnwrap(engine.handle(.shiftClick(side: 0), app: "test.app", field: "f", timeMs: 0))
        XCTAssertEqual(shift.commit, "nihc")
        XCTAssertEqual(shift.english, 0)
        XCTAssertFalse(shift.composing)
        // 未组合单击切换英文；字母直通。
        let toggle = try XCTUnwrap(engine.handle(.shiftClick(side: 0), app: "test.app", field: "f", timeMs: 0))
        XCTAssertEqual(toggle.english, 1)
        XCTAssertEqual(toggle.toast, 2)
        let pass = try XCTUnwrap(engine.handle(.text("x"), app: "test.app", field: "f", timeMs: 0))
        XCTAssertFalse(pass.consumed)
        // 再切回中文并完成一次普通上屏（出厂词典）。
        let back = try XCTUnwrap(engine.handle(.shiftClick(side: 0), app: "test.app", field: "f", timeMs: 0))
        XCTAssertEqual(back.english, 0)
        let snap = try XCTUnwrap(type("nihc", on: engine))
        XCTAssertEqual(snap.candidates.first?.text, "你好")
    }

    func testCustomWordsRoundTripAndValidation() throws {
        let words = [
            CustomWord(kind: Int32(GC_WORD_SHORTCODE), enabled: true, code: "zj", pinyin: "", content: "早安！"),
            CustomWord(kind: Int32(GC_WORD_PINYIN), enabled: true, code: "", pinyin: "hui'yi", content: "会议纪要"),
        ]
        XCTAssertTrue(CustomWordStore.write(path: wordsPath.path, words: words))
        let loaded = try XCTUnwrap(CustomWordStore.read(path: wordsPath.path))
        XCTAssertFalse(loaded.corrupt)
        XCTAssertEqual(loaded.words, words)
        XCTAssertNotNil(CustomWordStore.validate(kind: Int32(GC_WORD_SHORTCODE), code: "ZJ", pinyin: "", content: "内容"))
        XCTAssertNil(CustomWordStore.validate(kind: Int32(GC_WORD_SHORTCODE), code: "zj", pinyin: "", content: "含 制表\\测试"))
        XCTAssertNotNil(CustomWordStore.validate(kind: Int32(GC_WORD_PINYIN), code: "", pinyin: "hui'yi", content: "会议纪"))
    }

    func testFactoryCustomPinyinInBothSchemesAndReload() throws {
        let word = CustomWord(kind: Int32(GC_WORD_PINYIN), enabled: true,
                              code: "", pinyin: "ji'shi'jiao", content: "极视角")
        for (scheme, keys) in [(GC_SCHEME_XIAOHE, "jiuijn"), (GC_SCHEME_FULLPINYIN, "jishijiao")] {
            for reload in [false, true] {
                XCTAssertTrue(CustomWordStore.write(path: wordsPath.path, words: reload ? [] : [word]))
                let engine = engine()
                engine.update(scheme: Int32(scheme.rawValue), fuzzyMask: 0,
                              fullPinyinPreedit: true, freqEnabled: false)
                if reload {
                    XCTAssertTrue(CustomWordStore.write(path: wordsPath.path, words: [word]))
                    XCTAssertTrue(engine.reloadCustomWords())
                }
                let snapshot = try XCTUnwrap(type(keys, on: engine))
                XCTAssertEqual(snapshot.preedit, "ji'shi'jiao")
                XCTAssertEqual(snapshot.candidates.first?.text, "极视角")
                XCTAssertEqual(snapshot.candidates.first?.kind, Int32(GC_CAND_PINYIN_WORD))
                let commit = try XCTUnwrap(engine.handle(.space, app: "test.app", field: "f", timeMs: 0))
                XCTAssertEqual(commit.commit, "极视角")
                XCTAssertFalse(engine.quickAddAvailable)
            }
        }
    }

    func testFactoryAutoPinyinUsesCommonReadings() {
        for (word, pinyin) in [("极视角", "ji'shi'jiao"), ("角", "jiao"), ("会议", "hui'yi")] {
            XCTAssertEqual(CustomWordStore.autoPinyin(dictPath: dictPath.path, hanzi: word), pinyin)
        }
        XCTAssertNil(CustomWordStore.autoPinyin(dictPath: dir.appendingPathComponent("missing.dict").path,
                                              hanzi: "极视角"))
    }

    func testFocusSyncAndAppDefaults() throws {
        let engine = engine()
        engine.setAppDefaults(["com.raycast.macos"])
        let sync = try XCTUnwrap(engine.handle(.focusSync, app: "com.raycast.macos", field: "f1", timeMs: 0))
        XCTAssertEqual(sync.english, 2)
        let letter = try XCTUnwrap(engine.handle(.text("a"), app: "com.raycast.macos", field: "f1", timeMs: 0))
        XCTAssertFalse(letter.consumed)
        let esc = try XCTUnwrap(engine.handle(.esc, app: "com.raycast.macos", field: "f1", timeMs: 0))
        XCTAssertEqual(esc.english, 2)   // 已是默认：Esc 交还宿主
        XCTAssertTrue(esc.consumed == false)
    }

    func testRestoreChineseDraftInDefaultAndTemporaryEnglish() throws {
        let engine = engine()
        let app = "default.english.app"
        engine.setAppDefaults([app])
        XCTAssertEqual(engine.handle(.focusSync, app: app, field: "f", timeMs: 0)?.english, 2)
        var restored = try XCTUnwrap(engine.restoreRawInput("nihc", app: app, field: "f", timeMs: 0))
        XCTAssertEqual(restored.english, 0)
        XCTAssertTrue(restored.composing)
        XCTAssertEqual(restored.rawInput, "nihc")
        XCTAssertEqual(restored.candidates.first?.text, "你好")
        _ = engine.handle(.esc, app: app, field: "f", timeMs: 0)
        XCTAssertEqual(engine.handle(.shiftClick(side: 0), app: app, field: "f", timeMs: 0)?.english, 1)
        restored = try XCTUnwrap(engine.restoreRawInput("nihc", app: app, field: "f", timeMs: 0))
        XCTAssertEqual(restored.english, 0)
        XCTAssertEqual(restored.rawInput, "nihc")
        let next = try XCTUnwrap(engine.handle(.text("n"), app: app, field: "f", timeMs: 0))
        XCTAssertEqual(next.rawInput, "nihcn")
        XCTAssertTrue(next.composing)
    }

    func testSettingsNormalFieldsDecodeLegacyFiles() throws {
        let legacy = Data(#"{"recording":false,"excludedApplications":["com.example.App"]}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: legacy)
        XCTAssertFalse(settings.recording)
        XCTAssertEqual(settings.inputScheme, .xiaohe)
        XCTAssertTrue(settings.glossEnabled)
        XCTAssertTrue(settings.inputLettersEnabled)
        XCTAssertEqual(settings.candidateFontSize, 14)
        XCTAssertEqual(settings.appDefaultEnglish.count, 9)
        let outOfRange = try JSONDecoder().decode(Settings.self, from: Data(#"{"candidateFontSize": 99}"#.utf8))
        XCTAssertEqual(outOfRange.candidateFontSize, 16)
    }
}
