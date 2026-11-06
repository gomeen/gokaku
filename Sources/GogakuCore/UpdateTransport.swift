import Foundation

public struct UpdateHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public let finalURL: URL?

    public init(status: Int, headers: [String: String], body: Data, finalURL: URL?) {
        self.status = status; self.headers = headers; self.body = body; self.finalURL = finalURL
    }

    public var etag: String? { headers["etag"] }
    public var rateLimitRemaining: Int? { headers["x-ratelimit-remaining"].flatMap(Int.init) }
    public var rateLimitReset: Date? {
        headers["x-ratelimit-reset"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }
}

public enum UpdateTransportError: Error, Equatable, LocalizedError {
    case invalidURL
    case insecureURL
    case blockedHost(String)
    case timeout
    case offline
    case http(Int)
    case tooLarge
    case cancelled
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "更新地址非法"
        case .insecureURL: return "更新地址必须使用 HTTPS"
        case let .blockedHost(host): return "更新地址指向不受支持的主机：\(host)"
        case .timeout: return "连接更新服务超时"
        case .offline: return "无法连接更新服务"
        case let .http(status): return "更新服务返回 HTTP \(status)"
        case .tooLarge: return "更新响应超过大小上限"
        case .cancelled: return "已取消"
        case let .transport(message): return "更新传输失败：\(message)"
        }
    }
}

public protocol UpdateTransport: AnyObject {
    /// 拉取小型 JSON／签名（有大小上限）。
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval,
             maxBytes: Int) async throws -> UpdateHTTPResponse
    /// 拉取允许主机上的小型发布资产；API 列表仍使用 get。
    func getAsset(_ url: URL, headers: [String: String], timeout: TimeInterval,
                  maxBytes: Int) async throws -> UpdateHTTPResponse
    /// 下载安装资产到临时文件；返回临时文件 URL。调用方负责移动/删除。
    func download(_ url: URL, timeout: TimeInterval,
                  progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, UpdateHTTPResponse)
}

public extension UpdateTransport {
    func getAsset(_ url: URL, headers: [String: String], timeout: TimeInterval,
                  maxBytes: Int) async throws -> UpdateHTTPResponse {
        try URLSessionUpdateTransport.validate(url: url, requireAPIHost: false)
        return try await get(url, headers: headers, timeout: timeout, maxBytes: maxBytes)
    }
}

public final class URLSessionUpdateTransport: NSObject, UpdateTransport, URLSessionTaskDelegate {
    public static let apiHost = "api.github.com"
    public static let downloadHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com",
        "release-assets.githubusercontent.com", "github-releases.githubusercontent.com",
    ]
    public static let allowedHosts = downloadHosts.union([apiHost])

    private let configuration: URLSessionConfiguration
    private lazy var session: URLSession = {
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public override init() {
        configuration = .ephemeral
        super.init()
    }

    /// 测试可注入 URLProtocol；生产仍只用隔离的 ephemeral session。
    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        super.init()
    }

    deinit { session.invalidateAndCancel() }

    public func get(_ url: URL, headers: [String: String], timeout: TimeInterval,
                    maxBytes: Int) async throws -> UpdateHTTPResponse {
        try await getSmall(url, headers: headers, timeout: timeout,
                           maxBytes: maxBytes, requireAPIHost: true)
    }

    public func getAsset(_ url: URL, headers: [String: String], timeout: TimeInterval,
                         maxBytes: Int) async throws -> UpdateHTTPResponse {
        try await getSmall(url, headers: headers, timeout: timeout,
                           maxBytes: maxBytes, requireAPIHost: false)
    }

    private func getSmall(_ url: URL, headers: [String: String], timeout: TimeInterval,
                          maxBytes: Int, requireAPIHost: Bool) async throws -> UpdateHTTPResponse {
        try Self.validate(url: url, requireAPIHost: requireAPIHost)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.map(error)
        } catch {
            throw UpdateTransportError.transport(error.localizedDescription)
        }
        guard data.count <= maxBytes else { throw UpdateTransportError.tooLarge }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateTransportError.transport("非 HTTP 响应")
        }
        try Self.validate(url: http.url ?? url, requireAPIHost: false)
        return UpdateHTTPResponse(status: http.statusCode,
                                  headers: Self.headers(http),
                                  body: data, finalURL: http.url)
    }

    public func download(_ url: URL, timeout: TimeInterval,
                         progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, UpdateHTTPResponse) {
        try Self.validate(url: url, requireAPIHost: false)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        let delegate = DownloadDelegate(progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout, 300)
        config.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await delegate.start(session: session, request: request)
        } onCancel: {
            // 取消 Swift Task 时立即取消底层下载；delegate 会以 .cancelled 结束。
            delegate.cancel()
            session.invalidateAndCancel()
        }
    }

    // MARK: 重定向白名单（GET）

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.redirectAllowed(request) ? request : nil)
    }

    static func redirectAllowed(_ request: URLRequest) -> Bool {
        guard let url = request.url, url.scheme == "https", let host = url.host else { return false }
        return allowedHosts.contains(host)
    }

    static func validate(url: URL, requireAPIHost: Bool) throws {
        guard url.scheme == "https" else { throw UpdateTransportError.insecureURL }
        guard let host = url.host else { throw UpdateTransportError.invalidURL }
        if requireAPIHost {
            guard host == apiHost else { throw UpdateTransportError.blockedHost(host) }
        } else {
            guard allowedHosts.contains(host) else { throw UpdateTransportError.blockedHost(host) }
        }
    }

    static func map(_ error: URLError) -> UpdateTransportError {
        switch error.code {
        case .timedOut: return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed: return .offline
        case .cancelled: return .cancelled
        default: return .transport(error.localizedDescription)
        }
    }

    static func headers(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            result[String(describing: key).lowercased()] = String(describing: value)
        }
        return result
    }
}

/// 单次下载的独立 URLSession delegate：进度、重定向白名单与临时文件接管。
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, UpdateHTTPResponse), Error>?
    private var movedFile: URL?
    private var failure: Error?
    private var cancelled = false

    init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    func start(session: URLSession, request: URLRequest) async throws -> (URL, UpdateHTTPResponse) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let cancelled = self.cancelled
            lock.unlock()
            if cancelled {
                continuation.resume(throwing: UpdateTransportError.cancelled)
                return
            }
            session.downloadTask(with: request).resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // 系统在 delegate 返回后会删除 location；立即移动到自己拥有的临时文件。
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("gogaku-update-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: target)
            lock.lock(); movedFile = target; lock.unlock()
        } catch {
            lock.lock(); failure = UpdateTransportError.transport("无法接管下载文件"); lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let moved = movedFile
        let cancelled = self.cancelled
        let failure = cancelled ? UpdateTransportError.cancelled
            : (self.failure ?? error.map { error -> UpdateTransportError in
                if let urlError = error as? URLError { return URLSessionUpdateTransport.map(urlError) }
                return .transport(error.localizedDescription)
            })
        lock.unlock()
        guard let continuation else { return }
        if let failure {
            if let moved { try? FileManager.default.removeItem(at: moved) }
            continuation.resume(throwing: failure)
            return
        }
        guard let moved, let response = task.response as? HTTPURLResponse else {
            continuation.resume(throwing: UpdateTransportError.transport("下载未完成"))
            return
        }
        do {
            try URLSessionUpdateTransport.validate(url: response.url ?? task.originalRequest?.url
                                                   ?? URL(string: "https://github.com")!,
                                                   requireAPIHost: false)
        } catch {
            try? FileManager.default.removeItem(at: moved)
            continuation.resume(throwing: error)
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: moved)
            continuation.resume(throwing: UpdateTransportError.http(response.statusCode))
            return
        }
        continuation.resume(returning: (moved,
            UpdateHTTPResponse(status: response.statusCode,
                               headers: URLSessionUpdateTransport.headers(response),
                               body: Data(), finalURL: response.url)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(URLSessionUpdateTransport.redirectAllowed(request) ? request : nil)
    }
}
