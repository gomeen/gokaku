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

        func get(_ url: URL, headers: [String: String], timeout: TimeInterval,
                 maxBytes: Int) async throws -> UpdateHTTPResponse {
            requested.append(url)
            return handler(url, headers)
        }

        func download(_ url: URL, timeout: TimeInterval,
                      progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, UpdateHTTPResponse) {
            requested.append(url)
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
            UpdateManifest(schema: 2, keyId: "k", version: "0.1.2", buildNumber: 1,
                           channel: .stable, notes: "", assets: manifest().assets))) {
            XCTAssertEqual($0 as? UpdateManifestError, .unsupportedSchema(2))
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
        XCTAssertTrue(result.message.contains("构建 10"))
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
}
