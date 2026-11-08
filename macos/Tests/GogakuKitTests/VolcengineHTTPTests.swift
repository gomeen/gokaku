import Foundation
import XCTest
@testable import GogakuKit

/// 接管会话中的所有 URL（含重定向目标），无路由立即失败，绝不回退真实网络。
private final class VolcengineStubURLProtocol: URLProtocol {
    struct Sent {
        let request: URLRequest
        let body: Data
    }
    enum Reply {
        case http(Int, Data)
        case failure(URLError.Code)
        case redirect(Int, URL)
    }
    typealias Handler = (Sent) throws -> Reply
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var sent: [Sent] = []

    static func configure(_ handler: Handler? = nil) {
        lock.lock()
        self.handler = handler
        sent = []
        lock.unlock()
    }

    static var requests: [Sent] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            // URLSession 可能将 httpBody 转成 stream；检查实际传输字节而不是重造 payload。
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let sent = Sent(request: request, body: body)
            Self.lock.lock()
            Self.sent.append(sent)
            let handler = Self.handler
            Self.lock.unlock()
            guard let handler else { throw URLError(.resourceUnavailable) }
            switch try handler(sent) {
            case let .http(status, data):
                let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                               httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case let .failure(code):
                throw URLError(code)
            case let .redirect(status, target):
                let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                               httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": target.absoluteString])!
                // 最坏情形：重定向提议保留 POST、源文与签名。生产 delegate 必须整体拒绝。
                var redirected = request
                redirected.url = target
                redirected.httpBody = body
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
                // 拒绝跳转后仍须完成原始响应，否则自定义 protocol 会一直等待至超时。
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// 运行生产 translate 与 URLSession，只替换最底层 URLProtocol；不访问用户凭据。
final class VolcengineHTTPTests: XCTestCase {
    private var root: URL!
    private var credentialsPath: URL { root.appendingPathComponent("credentials.json") }
    private let credentials = VolcengineCredentials(accessKeyId: "OFFLINE_AK", secretAccessKey: "OFFLINE_SK")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try credentials.save(at: credentialsPath)
        VolcengineStubURLProtocol.configure()
    }

    override func tearDownWithError() throws {
        VolcengineStubURLProtocol.configure()
        try FileManager.default.removeItem(at: root)
    }

    private func client(timeout: TimeInterval = 2) -> VolcengineClient {
        VolcengineClient(credentialsPath: credentialsPath, timeout: timeout,
                         protocolClasses: [VolcengineStubURLProtocol.self])
    }

    private func expectError(_ expected: VolcengineError, client: VolcengineClient,
                             source: String = "你好", file: StaticString = #filePath,
                             line: UInt = #line) async {
        do {
            _ = try await client.translate(source: source, direction: .zhToEn)
            XCTFail("应失败：\(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? VolcengineError, expected, file: file, line: line)
        }
    }

    private func assertSigned(_ sent: VolcengineStubURLProtocol.Sent,
                              credentials: VolcengineCredentials, source: String,
                              sourceLanguage: String, targetLanguage: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let request = sent.request
        XCTAssertEqual(request.httpMethod, "POST", file: file, line: line)
        XCTAssertEqual(request.url?.scheme, "https", file: file, line: line)
        XCTAssertEqual(request.url?.host, credentials.host, file: file, line: line)
        XCTAssertEqual(request.url?.query, VolcengineSigner.canonicalQuery(), file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Host"), credentials.host, file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json", file: file, line: line)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(body["TextList"] as? [String], [source], file: file, line: line)
        XCTAssertEqual(body["SourceLanguage"] as? String, sourceLanguage, file: file, line: line)
        XCTAssertEqual(body["TargetLanguage"] as? String, targetLanguage, file: file, line: line)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let xDate = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Date"))
        let date = try XCTUnwrap(formatter.date(from: xDate))
        let signed = VolcengineSigner.sign(accessKeyId: credentials.accessKeyId,
                                           secretAccessKey: credentials.secretAccessKey,
                                           host: credentials.host, region: credentials.region,
                                           query: VolcengineSigner.canonicalQuery(), body: sent.body, date: date)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), signed.authorization,
                       file: file, line: line)
        XCTAssertEqual(request.timeoutInterval, 2, file: file, line: line)
    }

    func testTranslateBothDirectionsAndBillingThroughHTTP() async throws {
        let client = client()
        for (direction, source, target, from, to, characters) in [
            (Direction.zhToEn, "你好", "Hello", "zh", "en", 17),
            (Direction.enToZh, "Good morning", "早上好", "en", "zh", 23)
        ] {
            let data = try JSONSerialization.data(withJSONObject: [
                "TranslationList": [["Translation": "  \(target) ） \n",
                                     "Extra": ["input_characters": characters]]]
            ])
            VolcengineStubURLProtocol.configure { _ in .http(200, data) }
            let result = try await client.translate(source: source, direction: direction)
            XCTAssertEqual(result.target, target)
            XCTAssertEqual(result.characters, characters, "采用服务端计费数，不以源文长度代替")
            XCTAssertTrue(result.milliseconds.isFinite)
            XCTAssertGreaterThanOrEqual(result.milliseconds, 0)
            XCTAssertEqual(VolcengineStubURLProtocol.requests.count, 1)
            try assertSigned(XCTUnwrap(VolcengineStubURLProtocol.requests.first), credentials: credentials,
                             source: source, sourceLanguage: from, targetLanguage: to)
        }
    }

    func testTranslateWithoutBillingField() async throws {
        VolcengineStubURLProtocol.configure { _ in
            .http(200, Data(#"{"TranslationList":[{"Translation":"你好。"}]}"#.utf8))
        }
        let result = try await client().translate(source: "Hello.", direction: .enToZh)
        XCTAssertEqual(result.target, "你好。")
        XCTAssertNil(result.characters)
    }

    func testHTTPFailuresDoNotReturnTargetsOrRetry() async {
        let client = client()
        for status in [401, 403, 429, 500, 502, 503] {
            // 即使有貌似可用的译文，也不能把失败状态当成功。
            VolcengineStubURLProtocol.configure { _ in
                .http(status, Data(#"{"TranslationList":[{"Translation":"must not commit"}]}"#.utf8))
            }
            await expectError(.backend(status: status), client: client)
            XCTAssertEqual(VolcengineStubURLProtocol.requests.count, 1)
        }
    }

    func testEmptyAndMalformedResponses() async {
        let client = client()
        let cases: [(String, VolcengineError)] = [
            (#"{"TranslationList":[]}"#, .emptyOutput),
            (#"{"TranslationList":[{"Translation":" \n "}]}"#, .emptyOutput),
            (#"{"TranslationList":[{}]}"#, .emptyOutput),
            ("", .backend(status: 200)),
            ("not JSON", .backend(status: 200)),
            ("{", .backend(status: 200)),
            ("[]", .backend(status: 200)),
            (#"{"TranslationList":"wrong type"}"#, .backend(status: 200)),
            (#"{"ResponseMetadata":{"Error":{"Code":"ServiceError"}}}"#, .backend(status: 200))
        ]
        for (body, error) in cases {
            VolcengineStubURLProtocol.configure { _ in .http(200, Data(body.utf8)) }
            await expectError(error, client: client)
            XCTAssertEqual(VolcengineStubURLProtocol.requests.count, 1)
        }
    }

    func testBufferedResponseSizeBoundary() async throws {
        let client = client()
        let base = Data(#"{"TranslationList":[{"Translation":"Hello"}]}"#.utf8)
        for size in [59_999, 60_000, 100_000] {
            let data = base + Data(repeating: 0x20, count: size - base.count)
            VolcengineStubURLProtocol.configure { _ in .http(200, data) }
            if size < 60_000 {
                let result = try await client.translate(source: "你好", direction: .zhToEn)
                XCTAssertEqual(result.target, "Hello")
            } else {
                await expectError(.responseTooLarge, client: client)
            }
            XCTAssertEqual(VolcengineStubURLProtocol.requests.count, 1)
        }
        // 此测试只证明完整接收后的大小检查，不证明流式内存／下载上限。
    }

    func testTimeoutAndNetworkFailures() async {
        let client = client()
        for (code, expected) in [(URLError.timedOut, VolcengineError.timeout),
                                 (.notConnectedToInternet, .network),
                                 (.cannotFindHost, .network),
                                 (.networkConnectionLost, .network),
                                 (.secureConnectionFailed, .network)] {
            VolcengineStubURLProtocol.configure { _ in .failure(code) }
            await expectError(expected, client: client)
            XCTAssertEqual(VolcengineStubURLProtocol.requests.count, 1)
        }
    }

    func testMissingStubRouteFailsClosed() async {
        VolcengineStubURLProtocol.configure()
        await expectError(.network, client: client())
        XCTAssertEqual(VolcengineStubURLProtocol.requests.count, 1)
    }

    func testCredentialsAreReadAfterSaveReplaceRemoveAndRestore() async throws {
        try VolcengineCredentials.remove(at: credentialsPath)
        let client = client()
        VolcengineStubURLProtocol.configure { _ in
            .http(200, Data(#"{"TranslationList":[{"Translation":"Hello"}]}"#.utf8))
        }
        await expectError(.credentialsMissing, client: client)
        XCTAssertTrue(VolcengineStubURLProtocol.requests.isEmpty)
        try credentials.save(at: credentialsPath)
        _ = try await client.translate(source: "你好", direction: .zhToEn)
        let changed = VolcengineCredentials(accessKeyId: "REPLACED_AK", secretAccessKey: "REPLACED_SK",
                                            region: "cn-test-1", requestOverrides: ["ResourceId": "offline-resource"])
        try changed.save(at: credentialsPath)
        _ = try await client.translate(source: "你好", direction: .zhToEn)
        XCTAssertEqual(VolcengineStubURLProtocol.requests.count, 2)
        let first = try XCTUnwrap(VolcengineStubURLProtocol.requests.first)
        let second = try XCTUnwrap(VolcengineStubURLProtocol.requests.last)
        try assertSigned(first, credentials: credentials, source: "你好", sourceLanguage: "zh", targetLanguage: "en")
        try assertSigned(second, credentials: changed, source: "你好", sourceLanguage: "zh", targetLanguage: "en")
        XCTAssertNotEqual(first.request.value(forHTTPHeaderField: "Authorization"),
                          second.request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: second.body) as? [String: Any])
        XCTAssertEqual(body["ResourceId"] as? String, "offline-resource")
        try VolcengineCredentials.remove(at: credentialsPath)
        await expectError(.credentialsMissing, client: client)
        XCTAssertEqual(VolcengineStubURLProtocol.requests.count, 2, "移除凭据后不发请求")
        try credentials.save(at: credentialsPath)
        _ = try await client.translate(source: "你好", direction: .zhToEn)
        XCTAssertEqual(VolcengineStubURLProtocol.requests.count, 3)
    }

    func testInvalidInputAndForeignCredentialHostFailBeforeTransport() async throws {
        let client = client()
        VolcengineStubURLProtocol.configure()
        for source in ["", "  \n", String(repeating: "a", count: 513)] {
            await expectError(.invalidRequest, client: client, source: source)
        }
        let foreign = VolcengineCredentials(accessKeyId: "a", secretAccessKey: "b", host: "evil.example")
        try foreign.save(at: credentialsPath)
        await expectError(.unsupportedHost, client: client)
        XCTAssertTrue(VolcengineStubURLProtocol.requests.isEmpty)
    }

    func testRedirectsNeverForwardSourceOrSignature() async throws {
        let client = client()
        for status in [301, 302, 303, 307, 308] {
            for target in ["https://evil.example/collect", "http://translate.volcengineapi.com/collect",
                           "https://other.volcengineapi.com/collect", "https://translate.volcengineapi.com/other"] {
                let destination = try XCTUnwrap(URL(string: target))
                VolcengineStubURLProtocol.configure { sent in
                    // 即使生产保护退化，所有目标仍由 stub 截获，绝不真实联网。
                    if sent.request.url == destination {
                        XCTFail("禁止重定向转发源文或签名")
                        return .failure(.unsupportedURL)
                    }
                    return .redirect(status, destination)
                }
                await expectError(.backend(status: status), client: client)
                XCTAssertEqual(VolcengineStubURLProtocol.requests.count, 1, "不得启动第二个请求：\(target)")
                try assertSigned(XCTUnwrap(VolcengineStubURLProtocol.requests.first), credentials: credentials,
                                 source: "你好", sourceLanguage: "zh", targetLanguage: "en")
            }
        }
    }
}
