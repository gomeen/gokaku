import XCTest
import CryptoKit
@testable import GogakuCore

/// 火山翻译客户端合同：请求体、V4 签名、凭据文件、错误映射与文本规则。
/// 签名与请求体用 Python 参考 worker 的计算结果做逐字节比对。
final class VolcengineTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: 请求体与签名（Python 参考实现的固定向量）

    func testPayloadMatchesPythonReference() throws {
        let payload = try VolcengineClient.payload(source: "你好", direction: .zhToEn)
        XCTAssertEqual(String(decoding: payload, as: UTF8.self),
                       #"{"SourceLanguage":"zh","TargetLanguage":"en","TextList":["你好"]}"#)
    }

    func testSignatureMatchesPythonReference() throws {
        let body = try VolcengineClient.payload(source: "你好", direction: .zhToEn)
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026; components.month = 11; components.day = 6
        components.hour = 10; components.minute = 30; components.second = 0
        let date = try XCTUnwrap(components.date)
        let signed = VolcengineSigner.sign(
            accessKeyId: "AKIDEXAMPLE", secretAccessKey: "SECRETEXAMPLE",
            host: "translate.volcengineapi.com", region: "cn-north-1",
            query: VolcengineSigner.canonicalQuery(), body: body, date: date)
        XCTAssertEqual(signed.xDate, "20261106T103000Z")
        XCTAssertEqual(signed.authorization,
            "HMAC-SHA256 Credential=AKIDEXAMPLE/20261106/cn-north-1/translate/request, "
            + "SignedHeaders=content-type;host;x-date, "
            + "Signature=551e01a649aa2607ea6a210c24ad5a02c225f08921af4451c3ae564ffcced685")
    }

    func testCanonicalQuery() {
        XCTAssertEqual(VolcengineSigner.canonicalQuery(), "Action=TranslateText&Version=2020-06-01")
    }

    // MARK: 凭据文件

    func testCredentialsRoundTripAndPermissions() throws {
        let url = root.appendingPathComponent("volcengine-credentials.json")
        let credentials = VolcengineCredentials(accessKeyId: "AKID", secretAccessKey: "SECRET",
                                                requestOverrides: ["ResourceId": "x"])
        try credentials.save(at: url)
        let loaded = try VolcengineCredentials.load(at: url)
        XCTAssertEqual(loaded, credentials)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try VolcengineCredentials.remove(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try VolcengineCredentials.load(at: url)) { error in
            XCTAssertEqual(error as? VolcengineError, .credentialsMissing)
        }
    }

    func testCredentialsRejectsIncompleteFile() throws {
        let url = root.appendingPathComponent("bad.json")
        try Data(#"{"accessKeyId":"AKID"}"#.utf8).write(to: url)
        XCTAssertThrowsError(try VolcengineCredentials.load(at: url)) { error in
            XCTAssertEqual(error as? VolcengineError, .credentialsMissing)
        }
    }

    func testEndpointRejectsForeignHost() {
        let credentials = VolcengineCredentials(accessKeyId: "a", secretAccessKey: "b",
                                                host: "evil.example.com")
        XCTAssertThrowsError(try VolcengineAPI.endpoint(for: credentials)) { error in
            XCTAssertEqual(error as? VolcengineError, .unsupportedHost)
        }
        let allowed = VolcengineCredentials(accessKeyId: "a", secretAccessKey: "b",
                                            host: "translate.volcengineapi.com")
        XCTAssertEqual(try VolcengineAPI.endpoint(for: allowed).absoluteString,
                       "https://translate.volcengineapi.com?Action=TranslateText&Version=2020-06-01")
    }

    // MARK: 文本与错误

    func testStripTrailingOrphanPunctuation() {
        XCTAssertEqual(VolcengineText.stripTrailingOrphanPunctuation("你好。"), "你好。")
        XCTAssertEqual(VolcengineText.stripTrailingOrphanPunctuation("你好 ）"), "你好")
        XCTAssertEqual(VolcengineText.stripTrailingOrphanPunctuation("你好，。"), "你好，。")
        XCTAssertEqual(VolcengineText.stripTrailingOrphanPunctuation("你好 ？"), "你好")
        XCTAssertEqual(VolcengineText.stripTrailingOrphanPunctuation("Hello,"), "Hello,")
        XCTAssertEqual(VolcengineText.stripTrailingOrphanPunctuation("你好 、 "), "你好 、 ")
        XCTAssertEqual(VolcengineText.stripTrailingOrphanPunctuation(""), "")
    }

    func testErrorCodeMapping() {
        XCTAssertEqual(LearningTranslation.errorCode(for: VolcengineError.credentialsMissing), "credentials_missing")
        XCTAssertEqual(LearningTranslation.errorCode(for: VolcengineError.timeout), "timeout")
        XCTAssertEqual(LearningTranslation.errorCode(for: VolcengineError.network), "network_error")
        XCTAssertEqual(LearningTranslation.errorCode(for: VolcengineError.unsupportedHost), "unsupported_host")
        XCTAssertEqual(LearningTranslation.errorCode(for: VolcengineError.emptyOutput), "empty_output")
        XCTAssertEqual(LearningTranslation.errorCode(for: VolcengineError.backend(status: 401)), "auth_error")
        XCTAssertEqual(LearningTranslation.errorCode(for: VolcengineError.backend(status: 500)), "backend_error")
    }

    func testPayloadRejectsOversizeAndBlank() {
        XCTAssertThrowsError(try VolcengineClient.payload(source: "", direction: .zhToEn))
        XCTAssertThrowsError(try VolcengineClient.payload(source: "   ", direction: .enToZh))
        XCTAssertThrowsError(try VolcengineClient.payload(source: String(repeating: "a", count: 513),
                                                          direction: .enToZh))
    }

    // MARK: 与本地模型无残留依赖

    func testLearningTranslationOnlyExposesVolcengine() throws {
        let config = LearningTranslation.serviceConfiguration(root: root,
                                                              helperOverride: root.appendingPathComponent("helper"))
        XCTAssertTrue(config.arguments.contains("--volcengine"))
        XCTAssertFalse(config.arguments.contains("--beam"))
        XCTAssertEqual(config.arguments.last, LearningTranslation.credentialsPath(root: root).path)
        XCTAssertEqual(LearningTranslation.resourceID, "volcengine-nmt")
    }
}
