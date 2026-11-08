import XCTest
@testable import GogakuKit

/// 火山翻译配置、设置迁移、候选标注与失败路径。
/// 2026-11-06 双端统一计划：本地模型与 Python 后端已移除，只保留火山 NMT。
final class LearningTranslationTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: 服务配置（helper ＋ 凭据路径；无 beam／后端选择）

    func testServiceConfigurationUsesHelperAndCredentials() {
        let helper = root.appendingPathComponent("GogakuTranslator")
        let config = LearningTranslation.serviceConfiguration(root: root, helperOverride: helper)
        XCTAssertEqual(config.executable, helper)
        XCTAssertEqual(config.arguments,
                       ["--volcengine", "--credentials",
                        root.appendingPathComponent("volcengine-credentials.json").path])
    }

    // MARK: 环境状态

    func testEnvironmentReportsMissingParts() throws {
        let helper = root.appendingPathComponent("GogakuTranslator")
        let missing = LearningTranslation.environment(root: root, helperOverride: helper)
        XCTAssertFalse(missing.ready)
        XCTAssertFalse(missing.hasCredentials)
        XCTAssertEqual(missing.missing.count, 2)

        FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let stillMissing = LearningTranslation.environment(root: root, helperOverride: helper)
        XCTAssertFalse(stillMissing.ready)
        XCTAssertEqual(stillMissing.missing, ["火山翻译凭据"])

        try VolcengineCredentials(accessKeyId: "AK", secretAccessKey: "SK")
            .save(at: root.appendingPathComponent("volcengine-credentials.json"))
        let ready = LearningTranslation.environment(root: root, helperOverride: helper)
        XCTAssertTrue(ready.ready)
        XCTAssertTrue(ready.hasCredentials)
        XCTAssertTrue(ready.missing.isEmpty)
    }

    // MARK: 设置迁移（旧本地模型默认关闭云翻译；已启用火山的保留）

    /// 迁移规则现在住在共享核心（`gc_settings_normalize`），所以这里走真实读盘路径：
    /// 写 settings.json → Settings.load → 规范化 → 解码。
    private func load(_ json: String) throws -> Settings {
        try Data(json.utf8).write(to: root.appendingPathComponent("settings.json"))
        return Settings.load(at: root)
    }

    func testNewSettingsDefaultOff() {
        let defaults = Settings()
        XCTAssertFalse(defaults.learningTranslationEnabled)
        XCTAssertEqual(defaults.schemaVersion, 2)
    }

    func testEmptyLegacyConfigMigratesToOff() throws {
        let decoded = try load("{}")
        XCTAssertFalse(decoded.learningTranslationEnabled)
        XCTAssertEqual(decoded.schemaVersion, 2)
    }

    func testLegacyLocalBackendMigratesToOff() throws {
        for backend in ["quickmt", "small100"] {
            let json = #"{"learningTranslationEnabled": true, "learningTranslationBackend": "\#(backend)"}"#
            let decoded = try load(json)
            XCTAssertFalse(decoded.learningTranslationEnabled, backend)
            XCTAssertEqual(decoded.schemaVersion, 2)
        }
    }

    func testLegacyVolcengineConfigKeepsEnabledAndCredentials() throws {
        let credentials = VolcengineCredentials(accessKeyId: "AK", secretAccessKey: "SK")
        try credentials.save(at: root.appendingPathComponent("volcengine-credentials.json"))
        let json = #"{"learningTranslationEnabled": true, "learningTranslationBackend": "volcengine", "volcengineUsageMonth": "2026-11", "volcengineUsageCharacters": 42}"#
        let decoded = try load(json)
        XCTAssertTrue(decoded.learningTranslationEnabled)
        XCTAssertEqual(decoded.volcengineUsageMonth, "2026-11")
        XCTAssertEqual(decoded.volcengineUsageCharacters, 42)
        XCTAssertEqual(LearningTranslation.credentials(root: root), credentials)
    }

    func testLegacyVolcengineDisabledStaysDisabled() throws {
        let json = #"{"learningTranslationEnabled": false, "learningTranslationBackend": "volcengine"}"#
        let decoded = try load(json)
        XCTAssertFalse(decoded.learningTranslationEnabled)
    }

    func testSchemaTwoRoundTrip() throws {
        var settings = Settings()
        settings.learningTranslationEnabled = true
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(decoded.learningTranslationEnabled)
        XCTAssertEqual(decoded.schemaVersion, 2)
    }

    // MARK: 组合会话：火山资源标注与失败路径

    func session(_ direction: Direction) throws -> CompositionSession {
        let path = ProcessInfo.processInfo.environment["GOGAKU_ENGINE_DATA"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/Gogaku/libime-1.1.17/data").path
        let s = try CompositionSession(config: .init(dictPath: path + "/sc.dict", modelPath: path + "/zh_CN.lm"))
        s.configure(focus: 1, mode: .learning, direction: direction)
        try s.type("metting")
        return s
    }

    func testVolcengineCandidateEntersOnlyWithApproval() throws {
        let s = try session(.enToZh)
        let stamp = s.view.stamp
        let request = TranslationRequest(stamp: stamp, sourceID: "english:full", source: s.view.raw,
                                         resource: LearningTranslation.resourceID)
        // 非火山资源即使成功也不进入候选。
        s.receive(TranslationResult(request: request, target: "会议"), approved: false)
        XCTAssertTrue(s.view.candidates.isEmpty)
        // 火山资源成功进入候选；源文已在预编辑行显示，注释留空。
        s.receive(TranslationResult(request: request, target: "会议"), approved: true)
        let candidate = try XCTUnwrap(s.view.candidates.first)
        XCTAssertEqual(candidate.resource, LearningTranslation.resourceID)
        XCTAssertEqual(candidate.explanation, "")
        XCTAssertEqual(candidate.target, "会议")
        XCTAssertEqual(s.view.status, "")
    }

    func testTranslationFailureKeepsInputAndShowsVolcengineHint() throws {
        let s = try session(.enToZh)
        let stamp = s.view.stamp
        let request = TranslationRequest(stamp: stamp, sourceID: "english:full", source: s.view.raw,
                                         resource: LearningTranslation.resourceID)
        let message = LearningTranslation.failureMessage("credentials_missing")
        s.translationFailed(TranslationResult(request: request, error: "credentials_missing"), message: message)
        XCTAssertTrue(s.view.candidates.isEmpty)
        XCTAssertEqual(s.view.raw, "metting")
        XCTAssertEqual(s.view.status, message)
        XCTAssertTrue(message.contains("火山翻译"))
        // 迟到结果（组合已更新到新 revision）不再覆盖状态。
        let staleStamp = stamp
        try s.type("x")
        XCTAssertNotEqual(s.view.stamp, staleStamp)
        s.translationFailed(TranslationResult(request: TranslationRequest(stamp: staleStamp, sourceID: "english:full",
                                                                         source: s.view.raw, resource: "test-only"),
                                             error: "timeout"),
                            message: "过期提示")
        XCTAssertNotEqual(s.view.status, "过期提示")
    }

    func testConnectionErrorMessagesAreShort() {
        let errors: [VolcengineError] = [
            .credentialsMissing, .backend(status: 401), .backend(status: 500),
            .timeout, .network, .unsupportedHost, .emptyOutput,
        ]
        for error in errors {
            XCTAssertFalse(LearningTranslation.connectionErrorMessage(error).contains("输入已保留"))
        }
        XCTAssertTrue(LearningTranslation.connectionErrorMessage(VolcengineError.credentialsMissing).contains("凭据"))
        XCTAssertTrue(LearningTranslation.connectionErrorMessage(VolcengineError.backend(status: 401)).contains("认证"))
        XCTAssertTrue(LearningTranslation.connectionErrorMessage(VolcengineError.timeout).contains("超时"))
        XCTAssertTrue(LearningTranslation.connectionErrorMessage(VolcengineError.network).contains("网络"))
    }

    func testFailureMessagesAreSpecific() {
        XCTAssertTrue(LearningTranslation.failureMessage("auth_error").contains("认证"))
        XCTAssertTrue(LearningTranslation.failureMessage("timeout").contains("超时"))
        XCTAssertTrue(LearningTranslation.failureMessage("network_error").contains("网络"))
        for code in ["credentials_missing", "timeout", "service_unavailable", "backend_error",
                     "empty_output", "invalid_request", "auth_error", "network_error", "unknown"] {
            let message = LearningTranslation.failureMessage(code)
            XCTAssertTrue(message.contains("输入已保留"), code)
            XCTAssertTrue(message.contains("⌘Return"), code)
        }
    }
}
