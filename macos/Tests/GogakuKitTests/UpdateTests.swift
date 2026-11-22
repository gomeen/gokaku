import XCTest
import CryptoKit
@testable import GogakuKit

/// 更新合同与检查器：签名、通道、构建号、兼容性、分页／ETag／限流、
/// 下载校验与偏好节流。全部用注入传输，不访问真实网络。
final class UpdateTests: XCTestCase {
    var root: URL!
    var preferencesURL: URL!
    var key: Curve25519.Signing.PrivateKey!
    var trusted: UpdateTrustedKey!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        preferencesURL = root.appendingPathComponent("update-preferences.json")
        key = Curve25519.Signing.PrivateKey()
        trusted = UpdateTrustedKey(keyId: "test-key",
                                   publicKey: key.publicKey.rawRepresentation.base64EncodedString())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: 夹具

    func config(owner: String = "gogaku", repo: String = "gogaku-releases") -> UpdateSourceConfig {
        UpdateSourceConfig(owner: owner, repo: repo, trustedKeys: [trusted])
    }

    func installation(channel: UpdateChannel = .stable, build: Int = 9,
                      arch: String = "x86_64", os: String = "26.7.2") -> UpdateInstallation {
        UpdateInstallation(version: "0.1.1", buildNumber: build, channel: channel,
                           platform: "macos", arch: arch, osVersion: os)
    }

    func manifest(build: Int = 10, version: String = "0.1.2", channel: UpdateChannel = .stable,
                  assets: [UpdateAsset]? = nil) -> UpdateManifest {
        UpdateManifest(keyId: "test-key", version: version, buildNumber: build, channel: channel,
                       notes: "修复若干问题。",
                       assets: assets ?? [UpdateAsset(platform: "macos", arch: "x86_64", minOS: "26.0",
                                                      assetId: 7, name: "Gogaku-0.1.2-b10.pkg",
                                                      size: 1_024, sha256: String(repeating: "a", count: 64))])
    }

    func signedRelease(_ manifest: UpdateManifest, tag: String = "v0.1.2",
                       prerelease: Bool = false, draft: Bool = false,
                       packageName: String? = nil, packageSize: Int64 = 1_024,
                       packageAssetId: Int64 = 7) throws -> (Data, Data) {
        let manifestData = try JSONEncoder().encode(manifest)
        let signature = try key.signature(for: manifestData)
        return (manifestData, Data(signature.base64EncodedString().utf8))
    }

    func releaseJSON(tag: String = "v0.1.2", name: String = "Gogaku 0.1.2",
                     prerelease: Bool = false, draft: Bool = false,
                     manifestData: Data?, signatureData: Data?,
                     packageName: String = "Gogaku-0.1.2-b10.pkg",
                     packageSize: Int64 = 1_024, packageAssetId: Int64 = 7,
                     publishedAt: String = "2026-11-06T10:00:00Z") throws -> Data {
        var assets: [[String: Any]] = []
        if let manifestData {
            assets.append(["id": 1, "name": "update-manifest.json", "size": manifestData.count,
                           "browser_download_url": "https://github.com/gogaku/gogaku-releases/releases/download/\(tag)/update-manifest.json"])
        }
        if let signatureData {
            assets.append(["id": 2, "name": "update-manifest.json.sig", "size": signatureData.count,
                           "browser_download_url": "https://github.com/gogaku/gogaku-releases/releases/download/\(tag)/update-manifest.json.sig"])
        }
        assets.append(["id": packageAssetId, "name": packageName, "size": packageSize,
                       "browser_download_url": "https://github.com/gogaku/gogaku-releases/releases/download/\(tag)/\(packageName)"])
        let release: [String: Any] = [
            "id": 42, "tag_name": tag, "name": name, "body": "notes",
            "draft": draft, "prerelease": prerelease,
            "published_at": publishedAt, "assets": assets,
        ]
        return try JSONSerialization.data(withJSONObject: [release])
    }

    final class FakeTransport: UpdateTransport {
        var handler: ((URL, [String: String]) -> UpdateHTTPResponse)!
        var downloadHandler: ((URL) throws -> (URL, Int64))?
        var requested: [URL] = []
        var downloadTimeouts: [TimeInterval] = []

        func get(_ url: URL, headers: [String: String], timeout: TimeInterval,
                 maxBytes: Int) async throws -> UpdateHTTPResponse {
            requested.append(url)
            return handler(url, headers)
        }

        func download(_ url: URL, timeout: TimeInterval,
                      progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, UpdateHTTPResponse) {
            requested.append(url)
            downloadTimeouts.append(timeout)
            guard let downloadHandler else { throw UpdateTransportError.transport("no handler") }
            let (file, size) = try downloadHandler(url)
            progress(size)
            return (file, UpdateHTTPResponse(status: 200, headers: [:], body: Data(), finalURL: url))
        }
    }

    func engine(_ transport: FakeTransport, config: UpdateSourceConfig? = nil,
                installation: UpdateInstallation? = nil,
                preferences: UpdatePreferencesStore? = nil) -> UpdateEngine {
        UpdateEngine(config: config ?? self.config(),
                     installation: installation ?? self.installation(),
                     transport: transport,
                     preferences: preferences ?? UpdatePreferencesStore(url: preferencesURL),
                     now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    /// 标准成功路由：清单／签名／资产。
    func route(_ transport: FakeTransport, manifestData: Data, signatureData: Data,
               releasesJSON: Data, packageData: Data = Data(repeating: 1, count: 1_024)) {
        transport.handler = { url, _ in
            if url.path.hasPrefix("/repos/") {
                return UpdateHTTPResponse(status: 200, headers: ["etag": "\"v1\""],
                                          body: releasesJSON, finalURL: url)
            }
            if url.lastPathComponent == "update-manifest.json" {
                return UpdateHTTPResponse(status: 200, headers: [:], body: manifestData, finalURL: url)
            }
            if url.lastPathComponent == "update-manifest.json.sig" {
                return UpdateHTTPResponse(status: 200, headers: [:], body: signatureData, finalURL: url)
            }
            return UpdateHTTPResponse(status: 404, headers: [:], body: Data(), finalURL: url)
        }
        transport.downloadHandler = { url in
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("fake-asset-\(UUID().uuidString)")
            try packageData.write(to: file)
            return (file, Int64(packageData.count))
        }
    }

    // MARK: 清单合同

    func testManifestValidationRejectsBadFields() throws {
        XCTAssertThrowsError(try UpdateManifestVerifier.validate(
            UpdateManifest(schema: 3, keyId: "k", version: "0.1.2", buildNumber: 1,
                           channel: .stable, notes: "", assets: manifest().assets))) {
            XCTAssertEqual($0 as? UpdateManifestError, .unsupportedSchema(3))
        }
        // schema 2 必须携带 dataPackage（防静默丢数据包）。
        XCTAssertThrowsError(try UpdateManifestVerifier.validate(
            UpdateManifest(schema: 2, keyId: "k", version: "0.1.2", buildNumber: 1,
                           channel: .stable, notes: "", assets: manifest().assets))) {
            XCTAssertEqual($0 as? UpdateManifestError, .missingDataPackage)
        }
        XCTAssertThrowsError(try UpdateManifestVerifier.validate(
            UpdateManifest(keyId: "k", version: "0.1", buildNumber: 1,
                           channel: .stable, notes: "", assets: manifest().assets)))
        XCTAssertThrowsError(try UpdateManifestVerifier.validate(
            UpdateManifest(keyId: "k", version: "0.1.2-rc.1", buildNumber: 1,
                           channel: .stable, notes: "", assets: manifest().assets)))
        // dev 通道允许 rc。
        XCTAssertNoThrow(try UpdateManifestVerifier.validate(
            UpdateManifest(keyId: "k", version: "0.1.2-rc.1", buildNumber: 1,
                           channel: .dev, notes: "", assets: manifest().assets)))
        var bad = manifest()
        bad = UpdateManifest(keyId: "k", version: bad.version, buildNumber: bad.buildNumber,
                             channel: .stable, notes: "",
                             assets: [UpdateAsset(platform: "macos", arch: "x86_64", minOS: "26.0",
                                                  assetId: 1, name: "../evil.pkg", size: 1,
                                                  sha256: String(repeating: "0", count: 64))])
        XCTAssertThrowsError(try UpdateManifestVerifier.validate(bad))
    }

    func testSignatureVerification() throws {
        let manifest = manifest()
        let data = try JSONEncoder().encode(manifest)
        let signature = try key.signature(for: data)
        XCTAssertNoThrow(try UpdateManifestVerifier.verify(manifestBytes: data, signature: signature,
                                                           trustedKeys: [trusted]))
        var tampered = data
        tampered.append(0x20)
        XCTAssertThrowsError(try UpdateManifestVerifier.verify(manifestBytes: tampered, signature: signature,
                                                               trustedKeys: [trusted])) {
            XCTAssertEqual($0 as? UpdateManifestError, .invalidSignature)
        }
        XCTAssertThrowsError(try UpdateManifestVerifier.verify(manifestBytes: data, signature: signature,
                                                               trustedKeys: [])) {
            XCTAssertEqual($0 as? UpdateManifestError, .unknownKey("test-key"))
        }
        let base64Sig = Data(signature.base64EncodedString().utf8)
        XCTAssertNoThrow(try UpdateManifestVerifier.verify(manifestBytes: data, signature: base64Sig,
                                                           trustedKeys: [trusted]))
    }

    func testVersionAndOSComparison() {
        XCTAssertEqual(UpdateVersion.compareDotted("26.7.2", "26.0"), .orderedDescending)
        XCTAssertEqual(UpdateVersion.compareDotted("26.0", "26.0.0"), .orderedSame)
        XCTAssertEqual(UpdateVersion.compareDotted("10.0.22000", "10.0.22621"), .orderedAscending)
        XCTAssertTrue(UpdateVersion.isValidVersion("0.1.2"))
        XCTAssertTrue(UpdateVersion.isValidVersion("0.1.2-rc.1"))
        XCTAssertFalse(UpdateVersion.isValidVersion("0.1.2-beta.1"))
        XCTAssertFalse(UpdateVersion.isValidVersion("01.2.3"))
    }

    // MARK: 检查器

    func testFindsAvailableUpdate() async throws {
        let manifest = manifest()
        let (manifestData, signature) = try signedRelease(manifest)
        let releases = try releaseJSON(manifestData: manifestData, signatureData: signature)
        let transport = FakeTransport()
        route(transport, manifestData: manifestData, signatureData: signature, releasesJSON: releases)
        let result = await engine(transport).check(automatic: false)
        XCTAssertEqual(result.kind, .available)
        XCTAssertEqual(result.candidate?.manifest.buildNumber, 10)
        XCTAssertEqual(result.candidate?.asset.name, "Gogaku-0.1.2-b10.pkg")
    }

    func testSameOrLowerBuildIsUpToDate() async throws {
        for build in [9, 8] {
            let manifest = manifest(build: build)
            let (manifestData, signature) = try signedRelease(manifest)
            let releases = try releaseJSON(manifestData: manifestData, signatureData: signature)
            let transport = FakeTransport()
            route(transport, manifestData: manifestData, signatureData: signature, releasesJSON: releases)
            let result = await engine(transport).check(automatic: false)
            XCTAssertEqual(result.kind, .upToDate, "build \(build)")
            XCTAssertNil(result.candidate)
        }
    }

    func testInvalidSignatureIsNotUpToDate() async throws {
        let manifest = manifest()
        let (manifestData, signature) = try signedRelease(manifest)
        let releases = try releaseJSON(manifestData: manifestData, signatureData: Data("bad".utf8))
        let transport = FakeTransport()
        route(transport, manifestData: manifestData, signatureData: Data("bad".utf8), releasesJSON: releases)
        let result = await engine(transport).check(automatic: false)
        XCTAssertEqual(result.kind, .invalidManifest)
    }

    func testUnknownKeyIsRejected() async throws {
        let manifest = UpdateManifest(keyId: "other", version: "0.1.2", buildNumber: 10,
                                      channel: .stable, notes: "", assets: manifest().assets)
        let (manifestData, signature) = try signedRelease(manifest)
        let releases = try releaseJSON(manifestData: manifestData, signatureData: signature)
        let transport = FakeTransport()
        route(transport, manifestData: manifestData, signatureData: signature, releasesJSON: releases)
        let result = await engine(transport).check(automatic: false)
        XCTAssertEqual(result.kind, .invalidManifest)
    }

    func testUnsupportedArchAndOS() async throws {
        let arm = UpdateAsset(platform: "macos", arch: "arm64", minOS: "26.0",
                              assetId: 7, name: "arm.pkg", size: 1, sha256: String(repeating: "a", count: 64))
        let armManifest = manifest(assets: [arm])
        let (manifestData, signature) = try signedRelease(armManifest)
        let releases = try releaseJSON(manifestData: manifestData, signatureData: signature,
                                       packageName: "arm.pkg")
        let transport = FakeTransport()
        route(transport, manifestData: manifestData, signatureData: signature, releasesJSON: releases)
        let result = await engine(transport).check(automatic: false)
        XCTAssertEqual(result.kind, .unsupported)

        let future = UpdateAsset(platform: "macos", arch: "x86_64", minOS: "99.0",
                                 assetId: 7, name: "future.pkg", size: 1, sha256: String(repeating: "a", count: 64))
        let manifest2 = manifest(assets: [future])
        let (data2, sig2) = try signedRelease(manifest2)
        let releases2 = try releaseJSON(manifestData: data2, signatureData: sig2, packageName: "future.pkg")
        let transport2 = FakeTransport()
        route(transport2, manifestData: data2, signatureData: sig2, releasesJSON: releases2)
        let result2 = await engine(transport2).check(automatic: false)
        XCTAssertEqual(result2.kind, .unsupported)
    }

    func testChannelIsolation() async throws {
        // dev 客户端不接受 stable 清单。
        let stableManifest = manifest(channel: .stable)
        let (data, sig) = try signedRelease(stableManifest)
        let releases = try releaseJSON(manifestData: data, signatureData: sig)
        let transport = FakeTransport()
        route(transport, manifestData: data, signatureData: sig, releasesJSON: releases)
        let result = await engine(transport, installation: installation(channel: .dev)).check(automatic: false)
        XCTAssertEqual(result.kind, .noRelease)

        // stable 客户端跳过预发布 Release。
        let devManifest = manifest(version: "0.1.2-dev.1", channel: .dev)
        let (data2, sig2) = try signedRelease(devManifest, prerelease: true)
        let releases2 = try releaseJSON(prerelease: true, manifestData: data2, signatureData: sig2)
        let transport2 = FakeTransport()
        route(transport2, manifestData: data2, signatureData: sig2, releasesJSON: releases2)
        let result2 = await engine(transport2).check(automatic: false)
        XCTAssertEqual(result2.kind, .noManifest)
    }

    func testNoManifestAndUnconfigured() async throws {
        let releases = try releaseJSON(manifestData: nil, signatureData: nil)
        let transport = FakeTransport()
        transport.handler = { url, _ in
            UpdateHTTPResponse(status: 200, headers: [:], body: releases, finalURL: url)
        }
        let result = await engine(transport).check(automatic: false)
        XCTAssertEqual(result.kind, .noManifest)

        let unconfigured = await engine(transport, config: UpdateSourceConfig(owner: "", repo: "",
                                                                             trustedKeys: [])).check(automatic: false)
        XCTAssertEqual(unconfigured.kind, .unconfigured)
    }

    func testRateLimitAndHTTPFailure() async throws {
        let transport = FakeTransport()
        transport.handler = { url, _ in
            UpdateHTTPResponse(status: 403,
                               headers: ["x-ratelimit-remaining": "0",
                                         "x-ratelimit-reset": "1800003600"],
                               body: Data(), finalURL: url)
        }
        let limited = await engine(transport).check(automatic: false)
        XCTAssertEqual(limited.kind, .rateLimited)

        transport.handler = { url, _ in
            UpdateHTTPResponse(status: 500, headers: [:], body: Data(), finalURL: url)
        }
        let failed = await engine(transport).check(automatic: false)
        XCTAssertEqual(failed.kind, .networkError)
    }

    func testETag304ReevaluatesAfterUpgrade() async throws {
        let (data, sig) = try signedRelease(manifest())
        let releases = try releaseJSON(manifestData: data, signatureData: sig)
        let transport = FakeTransport()
        route(transport, manifestData: data, signatureData: sig, releasesJSON: releases)
        let first = await engine(transport).check(automatic: false)
        XCTAssertEqual(first.kind, .available)

        // 重建偏好存储和 Engine，模拟安装新构建后再次检查。
        let original = transport.handler!
        transport.handler = { url, headers in
            if url.host == "api.github.com" {
                XCTAssertEqual(headers["If-None-Match"], "\"v1\"")
                return UpdateHTTPResponse(status: 304, headers: [:], body: Data(), finalURL: url)
            }
            return original(url, headers)
        }
        transport.requested = []
        let result = await engine(transport, installation: installation(build: 10)).check(automatic: false)
        XCTAssertEqual(result.kind, .upToDate)
        XCTAssertNil(result.candidate)
        // 用户可见文案不写构建号（2026-11-19 裁决）：只确认“已是最新”与版本。
        XCTAssertTrue(result.message.contains("已是最新"))
        XCTAssertFalse(result.message.contains("构建"), "用户可见状态行不得出现构建号")
        XCTAssertEqual(transport.requested.count, 3, "304 仍需重新验证清单与签名")
    }

    func testInvalidSignatureDoesNotCommitETagBefore304() async throws {
        let (data, sig) = try signedRelease(manifest())
        let releases = try releaseJSON(manifestData: data, signatureData: sig)
        let transport = FakeTransport()
        route(transport, manifestData: data, signatureData: sig, releasesJSON: releases)
        let first = await engine(transport).check(automatic: false)
        XCTAssertEqual(first.kind, .available)

        let original = transport.handler!
        var notModified = false
        transport.handler = { url, headers in
            if url.host == "api.github.com" {
                XCTAssertEqual(headers["If-None-Match"], "\"v1\"", "坏签名的 v2 不得覆盖有效缓存")
                return UpdateHTTPResponse(status: notModified ? 304 : 200,
                                          headers: ["etag": "\"v2\""], body: releases, finalURL: url)
            }
            if url.lastPathComponent == "update-manifest.json.sig" {
                return UpdateHTTPResponse(status: 200, headers: [:], body: Data("bad".utf8), finalURL: url)
            }
            return original(url, headers)
        }
        let invalid = await engine(transport).check(automatic: false)
        XCTAssertEqual(invalid.kind, .invalidManifest)
        notModified = true
        let after304 = await engine(transport).check(automatic: false)
        XCTAssertEqual(after304.kind, .invalidManifest, "不能复用失败之前的 available 结论")
    }

    func testInvalidFirstCheckThen304CannotReuseLegacyOutcome() async throws {
        let prefs = UpdatePreferencesStore(url: preferencesURL)
        let old = UpdateCheckOutcome(kind: .upToDate, message: "旧结论", checkedAt: .distantPast)
        try prefs.setOutcome(old, channel: .stable)
        try prefs.setETag("\"legacy\"", channel: .stable)
        let (data, _) = try signedRelease(manifest())
        let bad = Data("bad".utf8)
        let releases = try releaseJSON(manifestData: data, signatureData: bad)
        let transport = FakeTransport()
        route(transport, manifestData: data, signatureData: bad, releasesJSON: releases)
        let invalid = await engine(transport).check(automatic: false)
        XCTAssertEqual(invalid.kind, .invalidManifest)
        transport.handler = { url, headers in
            XCTAssertNil(headers["If-None-Match"], "没有对应列表的旧 ETag 不得发送")
            return UpdateHTTPResponse(status: 304, headers: [:], body: Data(), finalURL: url)
        }
        let result = await engine(transport).check(automatic: false)
        XCTAssertEqual(result.kind, .networkError)
        XCTAssertNil(result.candidate)
        XCTAssertNotEqual(result.message, old.message)
    }

    func testPaginationFindsManifestOnSecondPage() async throws {
        var pageOne: [[String: Any]] = []
        for index in 0..<30 {
            pageOne.append(["id": Int64(index), "tag_name": "v0.0.\(index)", "draft": false,
                            "prerelease": false, "published_at": "2026-11-01T10:00:00Z",
                            "assets": []])
        }
        let pageOneData = try JSONSerialization.data(withJSONObject: pageOne)
        let manifest = manifest()
        let (manifestData, signature) = try signedRelease(manifest)
        let pageTwoData = try releaseJSON(manifestData: manifestData, signatureData: signature)
        let transport = FakeTransport()
        transport.handler = { url, _ in
            if url.query?.contains("page=2") == true {
                return UpdateHTTPResponse(status: 200, headers: [:], body: pageTwoData, finalURL: url)
            }
            if url.path.hasPrefix("/repos/") {
                return UpdateHTTPResponse(status: 200, headers: [:], body: pageOneData, finalURL: url)
            }
            if url.lastPathComponent == "update-manifest.json" {
                return UpdateHTTPResponse(status: 200, headers: [:], body: manifestData, finalURL: url)
            }
            if url.lastPathComponent == "update-manifest.json.sig" {
                return UpdateHTTPResponse(status: 200, headers: [:], body: signature, finalURL: url)
            }
            return UpdateHTTPResponse(status: 404, headers: [:], body: Data(), finalURL: url)
        }
        let result = await engine(transport).check(automatic: false)
        XCTAssertEqual(result.kind, .available)
    }

    func testCrossChannelPaginationAndPerPage304() async throws {
        let stable = try signedRelease(manifest(channel: .stable))
        let dev = try signedRelease(manifest(version: "0.1.2-dev.1", channel: .dev))
        let stablePage = try releaseJSON(tag: "stable", manifestData: stable.0, signatureData: stable.1)
        let devPage = try releaseJSON(tag: "dev", prerelease: true, manifestData: dev.0, signatureData: dev.1)
        let stableRow = try XCTUnwrap((JSONSerialization.jsonObject(with: stablePage) as? [[String: Any]])?.first)
        let fullStablePage = try JSONSerialization.data(withJSONObject: Array(repeating: stableRow, count: 30))
        let transport = FakeTransport()
        var notModified = false
        var pages: [Int] = []
        transport.handler = { url, headers in
            if url.host == "api.github.com" {
                let page = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    .queryItems!.first { $0.name == "page" }!.value!)!
                pages.append(page)
                let etag = "\"page-\(page)\""
                XCTAssertEqual(headers["If-None-Match"], notModified ? etag : nil)
                return UpdateHTTPResponse(status: notModified ? 304 : 200, headers: ["etag": etag],
                                          body: page < 3 ? fullStablePage : devPage, finalURL: url)
            }
            let pair = url.path.contains("/dev/") ? dev : stable
            return UpdateHTTPResponse(status: 200, headers: [:],
                                      body: url.pathExtension == "sig" ? pair.1 : pair.0, finalURL: url)
        }
        let first = await engine(transport, installation: installation(channel: .dev)).check(automatic: false)
        XCTAssertEqual(first.kind, .available)
        XCTAssertEqual(first.candidate?.manifest.channel, .dev)
        XCTAssertEqual(pages, [1, 2, 3])
        notModified = true
        pages = []
        let upgraded = await engine(transport, installation: installation(channel: .dev, build: 10))
            .check(automatic: false)
        XCTAssertEqual(upgraded.kind, .upToDate)
        XCTAssertEqual(pages, [1, 2, 3], "第一页 304 不能代替后续页面的重新验证")
    }

    func testPaginationNeverExceedsThreePages() async throws {
        let row: [String: Any] = ["id": 1, "tag_name": "ignored", "draft": false,
                                  "prerelease": false, "assets": []]
        let fullPage = try JSONSerialization.data(withJSONObject: Array(repeating: row, count: 30))
        let transport = FakeTransport()
        transport.handler = { url, _ in
            UpdateHTTPResponse(status: 200, headers: [:], body: fullPage, finalURL: url)
        }
        let result = await engine(transport).check(automatic: false)
        XCTAssertEqual(result.kind, .noManifest)
        XCTAssertEqual(transport.requested.count, 3)
    }

    func testAutoCheckThrottleDefaultsOff() throws {
        let prefs = UpdatePreferencesStore(url: preferencesURL)
        XCTAssertFalse(prefs.preferences.autoCheck)
        XCTAssertFalse(prefs.isAutoCheckDue(channel: .stable))
        try prefs.setAutoCheck(true)
        XCTAssertTrue(prefs.isAutoCheckDue(channel: .stable))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try prefs.recordAutoCheck(channel: .stable, now: now)
        XCTAssertFalse(prefs.isAutoCheckDue(channel: .stable, now: now.addingTimeInterval(3600)))
        XCTAssertTrue(prefs.isAutoCheckDue(channel: .stable, now: now.addingTimeInterval(86400)))
        // 通道独立。
        XCTAssertTrue(prefs.isAutoCheckDue(channel: .dev, now: now.addingTimeInterval(3600)))
    }

    // MARK: 下载校验

    func testDownloaderVerifiesSizeAndHashAndReusesCache() async throws {
        let data = Data("gogaku package".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let asset = UpdateAsset(platform: "macos", arch: "x86_64", minOS: "26.0",
                                assetId: 7, name: "Gogaku.pkg", size: Int64(data.count), sha256: hash)
        let manifest = UpdateManifest(keyId: "test-key", version: "0.1.2", buildNumber: 10,
                                      channel: .stable, notes: "", assets: [asset])
        let candidate = UpdateCandidate(releaseTag: "v0.1.2", releaseName: "x",
                                        manifest: manifest, asset: asset,
                                        downloadURL: URL(string: "https://github.com/gogaku/g.pkg")!,
                                        publishedAt: nil)
        let transport = FakeTransport()
        var downloads = 0
        transport.downloadHandler = { _ in
            downloads += 1
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("pkg-\(UUID().uuidString)")
            try data.write(to: file)
            return (file, Int64(data.count))
        }
        let downloader = UpdateDownloader(transport: transport,
                                          cacheRoot: root.appendingPathComponent("cache"))
        let file = try await downloader.download(candidate) { _ in }
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(downloads, 1)
        // 第二次直接复用缓存，不重新下载。
        _ = try await downloader.download(candidate) { _ in }
        XCTAssertEqual(downloads, 1)
        XCTAssertThrowsError(try UpdateDownloader.verify(
            file: file,
            asset: UpdateAsset(platform: "macos", arch: "x86_64", minOS: "26.0",
                               assetId: 7, name: "Gogaku.pkg", size: Int64(data.count),
                               sha256: String(repeating: "0", count: 64))))
    }

    func testDownloaderCancellationMapsToCancelled() async throws {
        final class SlowTransport: UpdateTransport {
            func get(_ url: URL, headers: [String: String], timeout: TimeInterval,
                     maxBytes: Int) async throws -> UpdateHTTPResponse {
                throw UpdateTransportError.transport("unused")
            }
            func download(_ url: URL, timeout: TimeInterval,
                          progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, UpdateHTTPResponse) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw UpdateTransportError.cancelled
            }
        }
        let data = Data("package".utf8)
        let asset = UpdateAsset(platform: "macos", arch: "x86_64", minOS: "26.0",
                                assetId: 7, name: "Gogaku.pkg", size: Int64(data.count),
                                sha256: String(repeating: "a", count: 64))
        let manifest = UpdateManifest(keyId: "test-key", version: "0.1.2", buildNumber: 10,
                                      channel: .stable, notes: "", assets: [asset])
        let candidate = UpdateCandidate(releaseTag: "v0.1.2", releaseName: "x",
                                        manifest: manifest, asset: asset,
                                        downloadURL: URL(string: "https://github.com/gogaku/g.pkg")!,
                                        publishedAt: nil)
        let downloader = UpdateDownloader(transport: SlowTransport(),
                                          cacheRoot: root.appendingPathComponent("cache"))
        let task = Task { try await downloader.download(candidate) { _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消后仍返回成功")
        } catch {
            XCTAssertEqual(error as? UpdateDownloadError, .cancelled)
        }
    }

    func testDownloaderRejectsSizeMismatch() throws {
        let file = root.appendingPathComponent("bad.pkg")
        try Data("abc".utf8).write(to: file)
        let asset = UpdateAsset(platform: "macos", arch: "x86_64", minOS: "26.0",
                                assetId: 1, name: "bad.pkg", size: 99,
                                sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try UpdateDownloader.verify(file: file, asset: asset)) {
            XCTAssertEqual($0 as? UpdateDownloadError, .sizeMismatch(expected: 99, actual: 3))
        }
    }

    // MARK: schema 2 双清单（数据包分离）

    func dataPackage(platform: String = "macos") -> UpdateDataPackage {
        UpdateDataPackage(platform: platform, name: "Gogaku-Data-0.1.2.pkg", size: 4_096,
                          sha256: String(repeating: "b", count: 64), assetId: 8,
                          dataVersion: "ab12cd34ef56ab12")
    }

    func v2Manifest() -> UpdateManifest {
        UpdateManifest(schema: 2, keyId: "test-key", version: "0.1.2", buildNumber: 10,
                       channel: .stable, notes: "", assets: manifest().assets,
                       dataPackage: dataPackage())
    }

    func routeManifest(_ transport: FakeTransport, manifestData: Data, signatureData: Data,
                       releasesJSON: Data, v2ManifestData: Data? = nil, v2SignatureData: Data? = nil,
                       v2Status: Int = 404) {
        transport.handler = { url, _ in
            if url.path.hasPrefix("/repos/") {
                return UpdateHTTPResponse(status: 200, headers: ["etag": "\"v1\""],
                                          body: releasesJSON, finalURL: url)
            }
            if url.lastPathComponent == "update-manifest-v2.json" {
                guard let v2ManifestData else {
                    return UpdateHTTPResponse(status: v2Status, headers: [:], body: Data(), finalURL: url)
                }
                return UpdateHTTPResponse(status: 200, headers: [:], body: v2ManifestData, finalURL: url)
            }
            if url.lastPathComponent == "update-manifest-v2.json.sig" {
                guard let v2SignatureData else {
                    return UpdateHTTPResponse(status: v2Status, headers: [:], body: Data(), finalURL: url)
                }
                return UpdateHTTPResponse(status: 200, headers: [:], body: v2SignatureData, finalURL: url)
            }
            if url.lastPathComponent == "update-manifest.json" {
                return UpdateHTTPResponse(status: 200, headers: [:], body: manifestData, finalURL: url)
            }
            if url.lastPathComponent == "update-manifest.json.sig" {
                return UpdateHTTPResponse(status: 200, headers: [:], body: signatureData, finalURL: url)
            }
            return UpdateHTTPResponse(status: 404, headers: [:], body: Data(), finalURL: url)
        }
    }

    func testSchema2ManifestCarriesDataPackage() async throws {
        let v2 = v2Manifest()
        let (v2Data, v2Sig) = try signedRelease(v2)
        let v1 = manifest()
        let (v1Data, v1Sig) = try signedRelease(v1)
        let releases = try releaseJSONWithV2(v2ManifestData: v2Data, v2SignatureData: v2Sig,
                                             v1ManifestData: v1Data, v1SignatureData: v1Sig)
        let transport = FakeTransport()
        routeManifest(transport, manifestData: v1Data, signatureData: v1Sig,
                      releasesJSON: releases, v2ManifestData: v2Data, v2SignatureData: v2Sig,
                      v2Status: 200)
        let result = await engine(transport).check(automatic: false)
        XCTAssertEqual(result.kind, .available)
        XCTAssertEqual(result.dataPackage, dataPackage())
        XCTAssertEqual(result.candidate?.manifest.schema, 2)
    }

    func testMissingV2FallsBackToSchema1() async throws {
        // 404 v2 → 回落 schema 1：可升级，无数据包（老发布形态）。
        let (v1Data, v1Sig) = try signedRelease(manifest())
        let releases = try releaseJSON(manifestData: v1Data, signatureData: v1Sig)
        let transport = FakeTransport()
        routeManifest(transport, manifestData: v1Data, signatureData: v1Sig, releasesJSON: releases)
        let result = await engine(transport).check(automatic: false)
        XCTAssertEqual(result.kind, .available)
        XCTAssertNil(result.dataPackage)
        XCTAssertEqual(result.candidate?.manifest.schema, 1)
    }

    func testOldClientStyleSchema1OnlyReleaseStillUpgradable() async throws {
        // 0.2.0 旧客户端视角：发布只有 schema 1 清单（旧名字），无 v2 资产。
        // 客户端照常 available；v1 清单没有 dataPackage 字段时解码不报错。
        let manifestData = try JSONEncoder().encode(manifest())
        let decoded = try JSONDecoder().decode(UpdateManifest.self, from: manifestData)
        XCTAssertNil(decoded.dataPackage)
        let (data, sig) = try signedRelease(manifest())
        let releases = try releaseJSON(manifestData: data, signatureData: sig)
        let transport = FakeTransport()
        routeManifest(transport, manifestData: data, signatureData: sig, releasesJSON: releases)
        let result = await engine(transport).check(automatic: false)
        XCTAssertEqual(result.kind, .available)
    }

    func testSchema2WithoutDataPackageIsRejected() throws {
        // schema 2 缺 dataPackage 字段：解码即拒（不能静默丢数据包）。
        let json = "{" +
            "\"schema\":2,\"keyId\":\"k\",\"version\":\"0.1.2\",\"buildNumber\":10," +
            "\"channel\":\"stable\",\"notes\":\"\",\"assets\":[]}"
        XCTAssertThrowsError(try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8)))
        // validate 层同样拒绝（dataPackage == nil）。
        let bad = UpdateManifest(schema: 2, keyId: "k", version: "0.1.2", buildNumber: 10,
                                 channel: .stable, notes: "", assets: manifest().assets,
                                 dataPackage: nil)
        XCTAssertThrowsError(try UpdateManifestVerifier.validate(bad)) {
            XCTAssertEqual($0 as? UpdateManifestError, .missingDataPackage)
        }
    }

    func testDataPackageFieldValidation() throws {
        // 无主包的平台不允许声明数据包。
        let wrongPlatform = UpdateManifest(schema: 2, keyId: "k", version: "0.1.2", buildNumber: 10,
                                           channel: .stable, notes: "", assets: manifest().assets,
                                           dataPackage: UpdateDataPackage(platform: "ios", name: "x.pkg", size: 1,
                                                                          sha256: String(repeating: "b", count: 64),
                                                                          assetId: 8, dataVersion: "ab12cd34ef56ab12"))
        XCTAssertThrowsError(try UpdateManifestVerifier.validate(wrongPlatform))
        // dataVersion 必须 16 位十六进制。
        let shortVersion = UpdateManifest(schema: 2, keyId: "k", version: "0.1.2", buildNumber: 10,
                                          channel: .stable, notes: "", assets: manifest().assets,
                                          dataPackage: UpdateDataPackage(platform: "macos", name: "x.pkg", size: 1,
                                                                         sha256: String(repeating: "b", count: 64),
                                                                         assetId: 8, dataVersion: "short"))
        XCTAssertThrowsError(try UpdateManifestVerifier.validate(shortVersion))
    }

    func testRegistryBindsDataPackageDownloadRecord() async throws {
        let v2 = v2Manifest()
        let (v2Data, v2Sig) = try signedRelease(v2)
        let v1 = manifest()
        let (v1Data, v1Sig) = try signedRelease(v1)
        let releases = try releaseJSONWithV2(v2ManifestData: v2Data, v2SignatureData: v2Sig,
                                             v1ManifestData: v1Data, v1SignatureData: v1Sig)
        let transport = FakeTransport()
        routeManifest(transport, manifestData: v1Data, signatureData: v1Sig,
                      releasesJSON: releases, v2ManifestData: v2Data, v2SignatureData: v2Sig,
                      v2Status: 200)
        _ = await engine(transport).check(automatic: false)
        let resolved = UpdateEngine.dataPackageRegistry.lookup(
            manifestVersion: "0.1.2", buildNumber: 10, dataVersion: "ab12cd34ef56ab12")
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.sha256, dataPackage().sha256)
        XCTAssertNil(UpdateEngine.dataPackageRegistry.lookup(
            manifestVersion: "0.1.2", buildNumber: 10, dataVersion: "other"))
    }

    func testDataPackageDownloadVerifiesHashAndCachesByVersion() async throws {
        let payload = Data("data-zip-content".utf8)
        let hash = UpdateDownloader.sha256(of: payload)
        let asset = UpdateAsset(platform: "macos", arch: "x86_64", minOS: "26.0",
                                assetId: 9, name: "Gogaku-Data-0.1.2.pkg",
                                size: Int64(payload.count), sha256: hash)
        let manifest = UpdateManifest(keyId: "test-key", version: "0.1.2", buildNumber: 10,
                                      channel: .stable, notes: "", assets: [asset])
        let candidate = UpdateCandidate(releaseTag: "v0.1.2", releaseName: "x",
                                        manifest: manifest, asset: asset,
                                        downloadURL: URL(string: "https://github.com/g/d.pkg")!,
                                        publishedAt: nil)
        let dataPackage = UpdateDataPackage(platform: "macos", name: "Gogaku-Data-0.1.2.pkg",
                                            size: Int64(payload.count), sha256: hash,
                                            assetId: 9, dataVersion: "ab12cd34ef56ab12")
        let transport = FakeTransport()
        var downloads = 0
        transport.downloadHandler = { _ in
            downloads += 1
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("d-\(UUID().uuidString)")
            try payload.write(to: file)
            return (file, Int64(payload.count))
        }
        let downloader = UpdateDownloader(transport: transport,
                                          cacheRoot: root.appendingPathComponent("cache"))
        let resolved = (URL(string: "https://github.com/g/d.pkg")!, hash, Int64(payload.count))
        let file = try await downloader.downloadDataPackage(
            candidate: candidate, dataPackage: dataPackage, resolved: resolved) { _ in }
        XCTAssertEqual(try Data(contentsOf: file!), payload)
        XCTAssertEqual(downloads, 1)
        // 同 dataVersion 再请求：命中缓存不重新下载（数据未变跨版本复用）。
        _ = try await downloader.downloadDataPackage(
            candidate: candidate, dataPackage: dataPackage, resolved: resolved) { _ in }
        XCTAssertEqual(downloads, 1)
        // 清单哈希与 resolved 记录不一致：拒绝（绑定校验；不同 dataVersion
        // 走独立缓存目录，真正落到下载路径）。
        let stale = UpdateDataPackage(platform: "macos", name: dataPackage.name,
                                      size: dataPackage.size, sha256: dataPackage.sha256,
                                      assetId: dataPackage.assetId, dataVersion: "ffffffffffffffff")
        do {
            _ = try await downloader.downloadDataPackage(
                candidate: candidate, dataPackage: stale,
                resolved: (resolved.0, String(repeating: "0", count: 64), resolved.2)) { _ in }
            XCTFail("哈希绑定不一致应拒绝")
        } catch { }
        // 无数据包（schema 1）：直接返回 nil。
        let none = try await downloader.downloadDataPackage(
            candidate: candidate, dataPackage: nil, resolved: nil) { _ in }
        XCTAssertNil(none)
    }

    /// 下载总超时按资产大小自适应：固定 300s 在 ~80KB/s 慢速网络下下不完
    /// 36.7MB 数据包，且无字节级续传，重试从头下载导致永远超时
    /// （2026-11-20 用户 0.3.0→0.3.2 升级实测）。
    func testDownloadTimeoutScalesWithAssetSize() async throws {
        // 纯函数：小包保持 300s 下限；大包按 50KB/s 保底速度估算。
        XCTAssertEqual(UpdateDownloader.downloadTimeout(forBytes: 0), 300)
        XCTAssertEqual(UpdateDownloader.downloadTimeout(forBytes: 11_217_422), 300)
        XCTAssertEqual(UpdateDownloader.downloadTimeout(forBytes: 36_695_320), 733.9, accuracy: 0.1)
        XCTAssertEqual(UpdateDownloader.downloadTimeout(forBytes: 104_857_600), 2097.2, accuracy: 0.1)
        // 传输层实际收到的超时也随大小变化。
        let smallPayload = Data(repeating: 0x61, count: 1024)
        let smallHash = UpdateDownloader.sha256(of: smallPayload)
        let bigPayload = Data(repeating: 0x62, count: 20_000_000)
        let bigHash = UpdateDownloader.sha256(of: bigPayload)
        let mainPayload = Data(repeating: 0x63, count: 11_217_422)
        let mainHash = UpdateDownloader.sha256(of: mainPayload)
        let asset = UpdateAsset(platform: "macos", arch: "x86_64", minOS: "26.0",
                                assetId: 9, name: "Gogaku-Data-0.1.2.pkg",
                                size: Int64(bigPayload.count), sha256: bigHash)
        let manifest = UpdateManifest(keyId: "test-key", version: "0.1.2", buildNumber: 10,
                                      channel: .stable, notes: "", assets: [asset])
        let candidate = UpdateCandidate(releaseTag: "v0.1.2", releaseName: "x",
                                        manifest: manifest, asset: asset,
                                        downloadURL: URL(string: "https://github.com/g/d.pkg")!,
                                        publishedAt: nil)
        let dataPackage = UpdateDataPackage(platform: "macos", name: asset.name,
                                            size: Int64(bigPayload.count), sha256: bigHash,
                                            assetId: 9, dataVersion: "ab12cd34ef56ab12")
        let transport = FakeTransport()
        transport.downloadHandler = { url in
            let p: Data = url.path.contains("s.pkg") ? smallPayload
                : (url.path.contains("d.pkg") ? bigPayload : mainPayload)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dt-\(UUID().uuidString)")
            try p.write(to: file)
            return (file, Int64(p.count))
        }
        let downloader = UpdateDownloader(transport: transport,
                                          cacheRoot: root.appendingPathComponent("cache-scale"))
        let small = UpdateDataPackage(platform: "macos", name: asset.name,
                                      size: Int64(smallPayload.count), sha256: smallHash,
                                      assetId: 9, dataVersion: "0123456789abcdef")
        _ = try await downloader.downloadDataPackage(
            candidate: candidate, dataPackage: small,
            resolved: (URL(string: "https://github.com/g/s.pkg")!, smallHash, Int64(smallPayload.count))) { _ in }
        _ = try await downloader.downloadDataPackage(
            candidate: candidate, dataPackage: dataPackage,
            resolved: (URL(string: "https://github.com/g/d.pkg")!, bigHash, Int64(bigPayload.count))) { _ in }
        XCTAssertEqual(transport.downloadTimeouts.count, 2)
        XCTAssertEqual(transport.downloadTimeouts[0], 300, accuracy: 0.1,
                       "小包保持 300s 下限")
        XCTAssertEqual(transport.downloadTimeouts[1], 400, accuracy: 0.1,
                       "20MB 数据包按 50KB/s 保底估算总超时（400s）")
        _ = try await downloader.download(
            UpdateCandidate(releaseTag: "v0.1.2", releaseName: "x",
                                       manifest: manifest, asset: UpdateAsset(
                                        platform: "macos", arch: "x86_64", minOS: "26.0", assetId: 10,
                                        name: "Gogaku-0.1.2.pkg", size: 11_217_422, sha256: mainHash),
                                       downloadURL: URL(string: "https://github.com/g/m.pkg")!,
                                       publishedAt: nil)) { _ in }
        XCTAssertEqual(transport.downloadTimeouts[2], 300, accuracy: 0.1,
                       "11MB 主包仍在 300s 下限内")
    }

    func releaseJSONWithV2(tag: String = "v0.1.2", v2ManifestData: Data, v2SignatureData: Data,
                           v1ManifestData: Data?, v1SignatureData: Data?,
                           packageName: String = "Gogaku-0.1.2-b10.pkg",
                           packageSize: Int64 = 1_024, packageAssetId: Int64 = 7,
                           dataAssetId: Int64 = 8, prerelease: Bool = false) throws -> Data {
        var assets: [[String: Any]] = []
        func add(_ id: Int, _ name: String, _ data: Data) {
            assets.append(["id": id, "name": name, "size": data.count,
                           "browser_download_url": "https://github.com/gogaku/gogaku-releases/releases/download/\(tag)/\(name)"])
        }
        add(30, "update-manifest-v2.json", v2ManifestData)
        add(31, "update-manifest-v2.json.sig", v2SignatureData)
        if let v1ManifestData, let v1SignatureData {
            add(1, "update-manifest.json", v1ManifestData)
            add(2, "update-manifest.json.sig", v1SignatureData)
        }
        assets.append(["id": packageAssetId, "name": packageName, "size": packageSize,
                       "browser_download_url": "https://github.com/gogaku/gogaku-releases/releases/download/\(tag)/\(packageName)"])
        assets.append(["id": dataAssetId, "name": "Gogaku-Data-0.1.2.pkg", "size": 4_096,
                       "browser_download_url": "https://github.com/gogaku/gogaku-releases/releases/download/\(tag)/Gogaku-Data-0.1.2.pkg"])
        let release: [String: Any] = [
            "id": 42, "tag_name": tag, "name": tag, "body": "notes",
            "draft": false, "prerelease": prerelease,
            "published_at": "2026-11-06T10:00:00Z", "assets": assets,
        ]
        return try JSONSerialization.data(withJSONObject: [release])
    }

    func testManifestNameHelpers() {
        XCTAssertEqual(UpdateManifestSourcing.baseManifestName(), "update-manifest.json")
        XCTAssertEqual(UpdateManifestSourcing.baseManifestName(flavor: "lite"), "update-manifest-lite.json")
        XCTAssertEqual(UpdateManifestSourcing.v2ManifestName(), "update-manifest-v2.json")
        XCTAssertEqual(UpdateManifestSourcing.v2ManifestName(flavor: "lite"), "update-manifest-lite-v2.json")
    }
}
