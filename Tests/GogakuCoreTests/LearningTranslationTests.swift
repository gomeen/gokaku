import XCTest
@testable import GogakuCore

/// quickmt 开发版学习翻译后端（2026-11 裁决）：装配配置、后端状态检查、
/// 设置默认值与钳制、候选标注与失败路径。见 docs/learning-quickmt-dev-decision.md。
final class LearningTranslationTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: 服务配置（venv python＋worker＋beam 启动参数）

    func testServiceConfigurationComposesPathsAndClampsBeam() {
        let config = LearningTranslation.serviceConfiguration(root: root, beam: 4)
        XCTAssertEqual(config.executable, root.appendingPathComponent("venv/bin/python"))
        XCTAssertEqual(config.arguments,
                       [root.appendingPathComponent("quickmt_worker.py").path, "--beam", "4"])
        XCTAssertEqual(LearningTranslation.serviceConfiguration(root: root, beam: 0).arguments.last, "1")
        XCTAssertEqual(LearningTranslation.serviceConfiguration(root: root, beam: 99).arguments.last, "10")
        XCTAssertEqual(LearningTranslation.clampedBeam(-3), 1)
        XCTAssertEqual(LearningTranslation.clampedBeam(11), 10)
        XCTAssertEqual(LearningTranslation.clampedBeam(7), 7)
    }

    // MARK: 后端状态（设置页缺失与就绪口径）

    func testEnvironmentReportsMissingParts() {
        let env = LearningTranslation.environment(root: root)
        XCTAssertFalse(env.ready)
        XCTAssertEqual(env.missing.count, 5)   // venv、worker、manifest、两向权重
        let python = root.appendingPathComponent("venv/bin/python")
        try? FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(atPath: root.appendingPathComponent("quickmt_worker.py").path, contents: Data())
        FileManager.default.createFile(atPath: root.appendingPathComponent("manifest.json").path, contents: Data())
        for name in ["quickmt-en-zh", "quickmt-zh-en"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: root.appendingPathComponent(name).appendingPathComponent("model.bin").path, contents: Data())
        }
        XCTAssertTrue(LearningTranslation.environment(root: root).ready)
    }

    // MARK: 设置默认值与解码钳制（旧配置缺字段 → 开发版默认开）

    func testSettingsDefaultsAndDecodedClamp() throws {
        let defaults = Settings()
        XCTAssertTrue(defaults.learningTranslationEnabled)
        XCTAssertEqual(defaults.learningBeamSize, LearningTranslation.defaultBeam)
        let decoded = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.learningTranslationEnabled)
        XCTAssertEqual(decoded.learningBeamSize, 1)
        let clamped = try JSONDecoder().decode(Settings.self, from: Data(
            #"{"learningBeamSize": 99, "learningTranslationEnabled": false}"#.utf8))
        XCTAssertEqual(clamped.learningBeamSize, 10)
        XCTAssertFalse(clamped.learningTranslationEnabled)
        let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(clamped))
        XCTAssertEqual(round.learningBeamSize, 10)
        XCTAssertFalse(round.learningTranslationEnabled)
    }

    // MARK: 组合会话：开发版候选标注与失败路径

    func session(_ direction: Direction) throws -> CompositionSession {
        let path = ProcessInfo.processInfo.environment["GOGAKU_ENGINE_DATA"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Gogaku/libime-1.1.17/data").path
        let s = CompositionSession(engine: try ChineseEngine(directory: URL(fileURLWithPath: path)))
        s.configure(focus: 1, mode: .learning, direction: direction)
        try s.type("metting")
        return s
    }

    func testDevCandidateCarriesLabelAndApprovedOnlyForDevResource() throws {
        let s = try session(.enToZh)
        let stamp = s.view.stamp
        let request = TranslationRequest(stamp: stamp, sourceID: "english:full", source: s.view.raw,
                                         resource: LearningTranslation.resourceID)
        // 非 quickmt 资源即使成功也不进入候选（正式口径不变）。
        s.receive(TranslationResult(request: request, target: "会议"), approved: false)
        XCTAssertTrue(s.view.candidates.isEmpty)
        // 开发版资源按豁免进入候选，注释带固定标注。
        s.receive(TranslationResult(request: request, target: "会议"), approved: true)
        let candidate = try XCTUnwrap(s.view.candidates.first)
        XCTAssertEqual(candidate.resource, LearningTranslation.resourceID)
        XCTAssertTrue(candidate.explanation.hasSuffix(" · quickmt 开发版"))
        XCTAssertEqual(candidate.target, "会议")
        XCTAssertEqual(s.view.status, "")
    }

    func testTranslationFailureKeepsInputAndShowsHint() throws {
        let s = try session(.enToZh)
        let stamp = s.view.stamp
        let request = TranslationRequest(stamp: stamp, sourceID: "english:full", source: s.view.raw,
                                         resource: LearningTranslation.resourceID)
        s.translationFailed(TranslationResult(request: request, error: "model_missing"),
                            message: "quickmt 模型未就绪；输入已保留")
        XCTAssertTrue(s.view.candidates.isEmpty)
        XCTAssertEqual(s.view.raw, "metting")   // 输入保留
        XCTAssertEqual(s.view.status, "quickmt 模型未就绪；输入已保留")
        // 迟到结果（组合已更新到新 revision，stamp 不再匹配）不再覆盖状态。
        let staleStamp = stamp
        try s.type("x")
        XCTAssertNotEqual(s.view.stamp, staleStamp)
        s.translationFailed(TranslationResult(request: TranslationRequest(stamp: staleStamp, sourceID: "english:full",
                                                                         source: s.view.raw, resource: "test-only"),
                                             error: "timeout"),
                            message: "过期提示")
        XCTAssertNotEqual(s.view.status, "过期提示")
        // 同 stamp 的后续失败（新请求结果）仍可更新提示。
        s.translationFailed(TranslationResult(request: TranslationRequest(stamp: s.view.stamp, sourceID: "english:full",
                                                                         source: s.view.raw, resource: "test-only"),
                                             error: "timeout"),
                            message: "quickmt 翻译超时；输入已保留")
        XCTAssertEqual(s.view.status, "quickmt 翻译超时；输入已保留")
    }
}
