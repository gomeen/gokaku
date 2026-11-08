import Foundation
import XCTest
@testable import GogakuKit

/// 所有请求都由 URLProtocol 接管；未配置路由也直接失败，绝不回退到网络。
private final class UpdateStubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let lock = NSLock()
    private static var handler: Handler?

    static func setHandler(_ handler: Handler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.resourceUnavailable) }
            let (response, body) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension UpdateTests {
    private func realTransport(_ handler: @escaping UpdateStubURLProtocol.Handler) -> URLSessionUpdateTransport {
        UpdateStubURLProtocol.setHandler(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateStubURLProtocol.self]
        return URLSessionUpdateTransport(configuration: configuration)
    }

    func testRealTransportChecksReleaseAndSmallAssetsWithoutNetwork() async throws {
        let (data, sig) = try signedRelease(manifest())
        let releases = try releaseJSON(manifestData: data, signatureData: sig)
        var requested: [URL] = []
        let transport = realTransport { request in
            let url = try XCTUnwrap(request.url)
            requested.append(url)
            let body: Data
            if url.host == "api.github.com" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
                body = releases
            } else {
                XCTAssertEqual(url.host, "github.com")
                body = url.pathExtension == "sig" ? sig : data
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                    headerFields: ["ETag": "\"real-v1\""])!, body)
        }
        defer { UpdateStubURLProtocol.setHandler(nil) }
        let engine = UpdateEngine(config: config(), installation: installation(), transport: transport,
                                  preferences: UpdatePreferencesStore(url: preferencesURL))
        let result = await engine.check(automatic: false)
        XCTAssertEqual(result.kind, .available, result.message)
        XCTAssertEqual(result.candidate?.manifest.buildNumber, 10)
        XCTAssertEqual(requested.map(\.host), ["api.github.com", "github.com", "github.com"])
    }

    func testRealTransportEnforcesAPIAndAssetHostBoundaries() async throws {
        var requests = 0
        let transport = realTransport { request in
            requests += 1
            let url = try XCTUnwrap(request.url)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("abc".utf8))
        }
        defer { UpdateStubURLProtocol.setHandler(nil) }
        for host in URLSessionUpdateTransport.allowedHosts.sorted() {
            let url = URL(string: "https://\(host)/asset")!
            let response = try await transport.getAsset(url, headers: [:], timeout: 1, maxBytes: 3)
            XCTAssertEqual(response.body, Data("abc".utf8))
            if host != URLSessionUpdateTransport.apiHost {
                do {
                    _ = try await transport.get(url, headers: [:], timeout: 1, maxBytes: 3)
                    XCTFail("API 请求不应接受资产主机 \(host)")
                } catch {
                    XCTAssertEqual(error as? UpdateTransportError, .blockedHost(host))
                }
            }
        }
        XCTAssertEqual(requests, URLSessionUpdateTransport.allowedHosts.count)
        for address in ["http://github.com/asset", "https://evil.example/asset",
                        "https://github.com.evil.example/asset"] {
            do {
                _ = try await transport.getAsset(URL(string: address)!, headers: [:], timeout: 1, maxBytes: 3)
                XCTFail("不应接受 \(address)")
            } catch {
                let expected: UpdateTransportError = address.hasPrefix("http:")
                    ? .insecureURL : .blockedHost(URL(string: address)!.host!)
                XCTAssertEqual(error as? UpdateTransportError, expected)
            }
        }
        XCTAssertEqual(requests, URLSessionUpdateTransport.allowedHosts.count, "非法地址必须在传输前拒绝")
        do {
            _ = try await transport.getAsset(URL(string: "https://github.com/asset")!,
                                              headers: [:], timeout: 1, maxBytes: 2)
            XCTFail("超出大小上限")
        } catch {
            XCTAssertEqual(error as? UpdateTransportError, .tooLarge)
        }
    }

    func testRealTransportRejectsUnsafeFinalResponseURL() async throws {
        let transport = realTransport { _ in
            (HTTPURLResponse(url: URL(string: "https://evil.example/asset")!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { UpdateStubURLProtocol.setHandler(nil) }
        do {
            _ = try await transport.getAsset(URL(string: "https://github.com/asset")!,
                                              headers: [:], timeout: 1, maxBytes: 3)
            XCTFail("最终响应主机仍须校验")
        } catch {
            XCTAssertEqual(error as? UpdateTransportError, .blockedHost("evil.example"))
        }
    }

    func testRealTransportRedirectDelegateKeepsHTTPSAllowlist() throws {
        // Delegate 使用同一判定函数；这里直接测边界，避免未启动 URLSessionTask 的系统崩溃。
        let accepted = URLSessionUpdateTransport.allowedHosts.map { "https://\($0)/asset" }
        let rejected = ["http://github.com/asset", "https://evil.example/asset",
                        "https://github.com.evil.example/asset", "file:///tmp/asset"]
        for address in accepted + rejected {
            let request = URLRequest(url: URL(string: address)!)
            XCTAssertEqual(URLSessionUpdateTransport.redirectAllowed(request), accepted.contains(address))
        }
    }
}
