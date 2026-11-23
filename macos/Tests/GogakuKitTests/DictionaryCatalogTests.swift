import XCTest
import CryptoKit
import CGogakuCore
@testable import GogakuKit

/// 官方词库渠道客户端回归（合同见 docs/dictionaries.md §七）：
/// 清单合同校验（kind／keyId／防回滚／URL 前缀）在共享核心，这里覆盖
/// Ed25519 验签、注入传输的失败路径（离线／404／验签失败／哈希不符）与安装。
final class DictionaryCatalogTests: XCTestCase {
    private let previousSupport = ProcessInfo.processInfo.environment["GOGAKU_SUPPORT_DIRECTORY"]
    private let previousEngineData = ProcessInfo.processInfo.environment["GOGAKU_ENGINE_DATA"]
    var supportDir: URL!
    var engineDataDir: URL!
    var engineDataSource: URL!

    override func setUpWithError() throws {
        supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gogaku-dictcat-\(UUID().uuidString)")
        engineDataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gogaku-dictcat-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engineDataDir, withIntermediateDirectories: true)
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

    private var config: DictionaryCatalog.Config {
        DictionaryCatalog.Config(schema: 1, owner: "gomeen", repo: "gogaku-dicts",
                                 trustedKeyIds: ["test-key"])
    }

    private func makeCatalogJSON(keyId: String = "test-key", kind: String = "gogaku-dictionary-catalog",
                                 catalogVersion: Int = 3,
                                 dictionaries: String =
                                 #"[{"id":"zhwiki","name":"维基百科词库","category":"综合","description":"词条","version":"0.3.1","license":"CC BY-SA 4.0","attribution":"维基百科贡献者","sourceUrl":"https://example.org","downloadUrl":"https://github.com/gomeen/gogaku-dicts/releases/download/catalog-3/zhwiki.dict","size":1024,"sha256":"abc123","entryCount":10}]"#) -> String {
        """
        {"kind":"\(kind)","schemaVersion":1,"keyId":"\(keyId)","catalogVersion":\(catalogVersion),"dictionaries":\(dictionaries)}
        """
    }

    /// 注入传输：按 URL 前缀分发固定响应。
    final class MockTransport: UpdateTransport {
        enum Response { case ok(Data), http(Int), offline, timeout }
        var routes: [String: Response] = [:]
        /// download 返回的资产字节（写入临时文件，模拟传输下载）。
        var downloaded: Data?

        func get(_ url: URL, headers: [String: String], timeout: TimeInterval,
                 maxBytes: Int) async throws -> UpdateHTTPResponse {
            try respond(to: url)
        }

        func download(_ url: URL, timeout: TimeInterval,
                      progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, UpdateHTTPResponse) {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("dictcat-download-\(UUID().uuidString)")
            try (downloaded ?? Data()).write(to: temp)
            progress(1)
            return (temp, UpdateHTTPResponse(status: 200, headers: [:], body: Data(), finalURL: url))
        }

        private func respond(to url: URL) throws -> UpdateHTTPResponse {
            // 精确匹配（catalog.json 与 catalog.json.sig 是前缀关系，不能模糊）。
            if let response = routes[url.absoluteString] {
                switch response {
                case .ok(let data):
                    return UpdateHTTPResponse(status: 200, headers: [:], body: data, finalURL: url)
                case .http(let status):
                    return UpdateHTTPResponse(status: status, headers: [:], body: Data(), finalURL: url)
                case .offline: throw UpdateTransportError.offline
                case .timeout: throw UpdateTransportError.timeout
                }
            }
            throw UpdateTransportError.http(404)
        }
    }

    // MARK: 验签

    func testSignatureVerifyAndTamper() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifest = makeCatalogJSON().data(using: .utf8)!
        let signature = try privateKey.signature(for: manifest)
        let trusted = [UpdateTrustedKey(
            keyId: "test-key",
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString())]

        // 有效签名。
        try DictionaryCatalog.verifySignature(manifestBytes: manifest, signature: signature,
                                              trustedKeyIds: ["test-key"], trustedKeys: trusted)
        // base64 文本签名同样接受。
        try DictionaryCatalog.verifySignature(manifestBytes: manifest,
                                              signature: signature.base64EncodedString().data(using: .utf8)!,
                                              trustedKeyIds: ["test-key"], trustedKeys: trusted)
        // 篡改清单 → 签名不符。
        let tampered = makeCatalogJSON(catalogVersion: 4).data(using: .utf8)!
        XCTAssertThrowsError(try DictionaryCatalog.verifySignature(
            manifestBytes: tampered, signature: signature,
            trustedKeyIds: ["test-key"], trustedKeys: trusted))
        // 未知 keyId。
        XCTAssertThrowsError(try DictionaryCatalog.verifySignature(
            manifestBytes: manifest, signature: signature,
            trustedKeyIds: ["other-key"], trustedKeys: trusted))
    }

    // MARK: 拉取失败路径（注入传输）

    private func signedResponse(_ json: String, privateKey: Curve25519.Signing.PrivateKey) throws -> Data {
        let manifest = json.data(using: .utf8)!
        return try privateKey.signature(for: manifest)
    }

    /// 捕获 fetch 的错误（合同：传输失败包成 CatalogError.transfer）。
    private func fetchError(_ transport: MockTransport, updateKeys: [UpdateTrustedKey],
                            installed: [DictionaryStore.Entry]) async -> Error? {
        do {
            _ = try await DictionaryCatalog.fetch(transport: transport, config: config,
                                                  updateKeys: updateKeys, installed: installed)
            return nil
        } catch {
            return error
        }
    }

    func testFetchOfflineMapsDistinctError() async throws {
        let transport = MockTransport()
        transport.routes["https://github.com/gomeen/gogaku-dicts/releases/latest/download/catalog.json"] = .offline
        let offlineError = await fetchError(transport, updateKeys: [], installed: [])
        let error = try XCTUnwrap(offlineError)
        guard case DictionaryCatalog.CatalogError.transfer(.offline) = error else {
            return XCTFail("期望离线错误，实际 \(error)")
        }
        XCTAssertEqual(DictionaryCatalog.failureMessage(error), "无法连接词库渠道（离线）")
    }

    func testFetch404MapsDistinctError() async throws {
        let transport = MockTransport()   // 无路由 → 404
        let notFoundError = await fetchError(transport, updateKeys: [], installed: [])
        let error = try XCTUnwrap(notFoundError)
        guard case DictionaryCatalog.CatalogError.transfer(.http(404)) = error else {
            return XCTFail("期望 404 错误，实际 \(error)")
        }
        XCTAssertEqual(DictionaryCatalog.failureMessage(error), "词库渠道还没有发布清单（404）")
    }

    func testFetchBadSignatureRejected() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let transport = MockTransport()
        let base = "https://github.com/gomeen/gogaku-dicts/releases/latest/download/"
        transport.routes[base + "catalog.json"] = .ok(makeCatalogJSON().data(using: .utf8)!)
        // 签名对应另一个清单（版本不同）→ 验签失败。
        transport.routes[base + "catalog.json.sig"] =
            .ok(try signedResponse(makeCatalogJSON(catalogVersion: 9), privateKey: privateKey))
        let trusted = [UpdateTrustedKey(
            keyId: "test-key",
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString())]
        let signatureError = await fetchError(transport, updateKeys: trusted, installed: [])
        let error = try XCTUnwrap(signatureError)
        guard case DictionaryCatalog.CatalogError.signature = error else {
            return XCTFail("期望签名错误，实际 \(error)")
        }
    }

    func testFetchWrongKindRejected() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let transport = MockTransport()
        let base = "https://github.com/gomeen/gogaku-dicts/releases/latest/download/"
        let wrongKind = makeCatalogJSON(kind: "gogaku-update-manifest")
        let manifest = wrongKind.data(using: .utf8)!
        transport.routes[base + "catalog.json"] = .ok(manifest)
        transport.routes[base + "catalog.json.sig"] =
            .ok(try privateKey.signature(for: manifest))
        let trusted = [UpdateTrustedKey(
            keyId: "test-key",
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString())]
        let contractError = await fetchError(transport, updateKeys: trusted, installed: [])
        let error = try XCTUnwrap(contractError)
        guard case DictionaryCatalog.CatalogError.contract = error else {
            return XCTFail("期望合同错误（kind 不符），实际 \(error)")
        }
    }

    // MARK: 拉取成功与安装

    func testFetchAndInstallRoundtrip() async throws {
        // 词库资产：真实 libime 二进制（出厂词典截一份小词库内容——直接用出厂
        // 词典本身；size/sha256 由内容计算）。
        let dictBytes = try Data(contentsOf: engineDataDir.appendingPathComponent("sc.dict"))
        let sha = dictBytes.sha256Hex()
        let escapedSHA = sha
        let dictionaries = """
        [{"id":"zhwiki","name":"维基百科词库","category":"综合","description":"词条",\
        "version":"0.3.1","license":"CC BY-SA 4.0","attribution":"维基百科贡献者",\
        "sourceUrl":"https://example.org",\
        "downloadUrl":"https://github.com/gomeen/gogaku-dicts/releases/download/catalog-3/zhwiki.dict",\
        "size":\(dictBytes.count),"sha256":"\(escapedSHA)","entryCount":300471}]
        """
        let privateKey = Curve25519.Signing.PrivateKey()
        let trusted = [UpdateTrustedKey(
            keyId: "test-key",
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString())]
        let transport = MockTransport()
        let base = "https://github.com/gomeen/gogaku-dicts/releases/latest/download/"
        let manifest = makeCatalogJSON(dictionaries: dictionaries).data(using: .utf8)!
        transport.routes[base + "catalog.json"] = .ok(manifest)
        transport.routes[base + "catalog.json.sig"] = .ok(try privateKey.signature(for: manifest))
        transport.downloaded = dictBytes

        let snapshot = try await DictionaryCatalog.fetch(
            transport: transport, config: config, updateKeys: trusted, installed: [])
        XCTAssertEqual(snapshot.rejected.count, 0)
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.catalogVersion, 3)
        XCTAssertFalse(snapshot.entries[0].installed)

        // 安装（下载 → 核心 sha256 校验 → 落盘）。
        try await DictionaryCatalog.install(snapshot.entries[0], catalogVersion: 3,
                                            transport: transport) { _ in }
        let listing = try DictionaryStore.list(learningAvailable: true)
        XCTAssertEqual(listing.entries.count, 1)
        let entry = try XCTUnwrap(listing.entries.first)
        XCTAssertEqual(entry.id, "zhwiki")
        XCTAssertEqual(entry.origin, "official")
        XCTAssertEqual(entry.version, "0.3.1")
        XCTAssertTrue(entry.enabled)

        // 再拉取：显示已安装。
        let installed = try DictionaryStore.list(learningAvailable: true).entries
        let snapshot2 = try await DictionaryCatalog.fetch(
            transport: transport, config: config, updateKeys: trusted, installed: installed)
        XCTAssertTrue(snapshot2.entries[0].installed)
        XCTAssertFalse(snapshot2.entries[0].updateAvailable)
    }

    func testInstallChecksumMismatchRejected() async throws {
        // 哈希不符：核心返回 4，不落盘（合同：校验失败均不安装）。
        let dictBytes = try Data(contentsOf: engineDataDir.appendingPathComponent("sc.dict"))
        let downloaded = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictcat-bad-\(UUID().uuidString)")
        try dictBytes.write(to: downloaded)
        let entry = """
        {"id":"zhwiki","name":"维基百科词库","version":"0.3.1","license":"CC BY-SA 4.0",\
        "attribution":"署名","sourceUrl":"",\
        "downloadUrl":"https://github.com/gomeen/gogaku-dicts/releases/download/catalog-3/zhwiki.dict",\
        "size":\(dictBytes.count),"sha256":"\(String(repeating: "0", count: 64))",\
        "entryCount":1,"catalogVersion":3}
        """
        var err = [CChar](repeating: 0, count: 512)
        let dirCopy = DictionaryStore.dictionariesDirectory.path.unsafeConstUTF8Copy()
        let pathCopy = downloaded.path.unsafeConstUTF8Copy()
        let entryCopy = entry.unsafeConstUTF8Copy()
        defer { freeConst(dirCopy); freeConst(pathCopy); freeConst(entryCopy) }
        let rc = gc_dict_install(dirCopy, pathCopy, entryCopy, &err, err.count)
        XCTAssertEqual(rc, 4, "哈希不符应返回 4")
        let listing = try DictionaryStore.list(learningAvailable: true)
        XCTAssertTrue(listing.entries.isEmpty)
    }
}

extension Data {
    func sha256Hex() -> String {
        // CryptoKit SHA256：与核心安装校验同一算法（gc_dict_install）。
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
