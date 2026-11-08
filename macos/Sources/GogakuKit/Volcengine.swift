import Foundation
import CryptoKit

/// 火山翻译（Volcengine TranslateText）客户端。
///
/// 设计边界（2026-11-06 双端功能统一计划）：
/// - 只保留云端火山翻译，不随包本地模型、CT2、SentencePiece、PyTorch；
/// - 以独立辅助进程 `GogakuTranslator --volcengine` 运行，输入法进程不持有网络；
/// - 凭据只从 0600 JSON 文件读取，不进设置导出、日志、主题包或安装包；
/// - 失败保留输入，由上层提示并允许明确原文上屏，不自动重试或切换语言。
///
/// 本文件同时提供可独立测试的签名器与请求构造：签名算法与既有
/// `scripts/volcengine_translate_worker.py` 逐字节对齐（V4 HMAC-SHA256）。
public enum VolcengineError: Error, Equatable {
    case credentialsMissing
    case invalidRequest
    case backend(status: Int)
    case emptyOutput
    case timeout
    case network
    case responseTooLarge
    case unsupportedHost
}

public struct VolcengineResult: Equatable, Sendable {
    public let target: String
    /// 服务端计费口径字符数（Extra.input_characters）；缺失时为 nil。
    public let characters: Int?
    public let milliseconds: Double
    public init(target: String, characters: Int?, milliseconds: Double) {
        self.target = target; self.characters = characters; self.milliseconds = milliseconds
    }
}

public struct VolcengineCredentials: Equatable, Sendable {
    public var accessKeyId: String
    public var secretAccessKey: String
    public var region: String
    public var host: String
    /// 可选请求体覆盖（垂类引擎／术语库等未来参数口子）；值按 JSON 原样合并。
    public var requestOverrides: [String: String]

    public init(accessKeyId: String, secretAccessKey: String,
                region: String = "cn-north-1", host: String = VolcengineAPI.host,
                requestOverrides: [String: String] = [:]) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.region = region
        self.host = host
        self.requestOverrides = requestOverrides
    }

    public static func load(at path: URL) throws -> VolcengineCredentials {
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessKey = object["accessKeyId"] as? String, !accessKey.isEmpty,
              let secretKey = object["secretAccessKey"] as? String, !secretKey.isEmpty else {
            throw VolcengineError.credentialsMissing
        }
        let overrides = (object["requestOverrides"] as? [String: Any])?
            .compactMapValues { value -> String? in
                if let string = value as? String { return string }
                if let number = value as? NSNumber { return number.stringValue }
                if let bool = value as? Bool { return bool ? "true" : "false" }
                return nil
            } ?? [:]
        return VolcengineCredentials(
            accessKeyId: accessKey,
            secretAccessKey: secretKey,
            region: object["region"] as? String ?? "cn-north-1",
            host: object["host"] as? String ?? VolcengineAPI.host,
            requestOverrides: overrides)
    }

    /// 仅当前用户可读写的凭据文件；父目录 0700，文件 0600。
    public func save(at path: URL) throws {
        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var payload: [String: Any] = [
            "accessKeyId": accessKeyId,
            "secretAccessKey": secretAccessKey,
            "region": region,
            "host": host,
        ]
        if !requestOverrides.isEmpty { payload["requestOverrides"] = requestOverrides }
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    public static func remove(at path: URL) throws {
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}

public enum VolcengineAPI {
    public static let host = "translate.volcengineapi.com"
    public static let action = "TranslateText"
    public static let version = "2020-06-01"
    public static let service = "translate"

    public static func endpoint(for credentials: VolcengineCredentials) throws -> URL {
        // 凭据文件是用户可写的；只允许火山 API 域，防止误配把签名或正文发往他处。
        guard credentials.host == host || credentials.host.hasSuffix(".volcengineapi.com") else {
            throw VolcengineError.unsupportedHost
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = credentials.host
        components.queryItems = [URLQueryItem(name: "Action", value: action),
                                 URLQueryItem(name: "Version", value: version)]
        guard let url = components.url else { throw VolcengineError.invalidRequest }
        return url
    }
}

/// 火山 V4 签名（HMAC-SHA256＋派生密钥链）。
/// 独立成类型便于用固定向量与 Python 参考实现逐字节比对。
public enum VolcengineSigner {
    public struct Signed: Equatable, Sendable {
        public let authorization: String
        public let xDate: String
        public init(authorization: String, xDate: String) {
            self.authorization = authorization; self.xDate = xDate
        }
    }

    public static func sign(accessKeyId: String, secretAccessKey: String,
                            host: String, region: String, query: String,
                            body: Data, date: Date) -> Signed {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let xDate = formatter.string(from: date)
        let dateStamp = String(xDate.prefix(8))

        let canonicalHeaders = "content-type:application/json\nhost:\(host)\nx-date:\(xDate)\n"
        let signedHeaders = "content-type;host;x-date"
        let payloadHash = sha256Hex(body)
        let canonical = "POST\n/\n\(query)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let scope = "\(dateStamp)/\(region)/\(VolcengineAPI.service)/request"

        let kDate = hmac(key: Data(secretAccessKey.utf8), message: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, message: Data(region.utf8))
        let kService = hmac(key: kRegion, message: Data(VolcengineAPI.service.utf8))
        let kSigning = hmac(key: kService, message: Data("request".utf8))
        let stringToSign = ["HMAC-SHA256", xDate, scope, sha256Hex(Data(canonical.utf8))]
            .joined(separator: "\n")
        let signature = hmac(key: kSigning, message: Data(stringToSign.utf8)).hexString
        return Signed(
            authorization: "HMAC-SHA256 Credential=\(accessKeyId)/\(scope), "
                + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
            xDate: xDate)
    }

    public static func canonicalQuery() -> String {
        "Action=\(VolcengineAPI.action)&Version=\(VolcengineAPI.version)"
    }

    static func hmac(key: Data, message: Data) -> Data {
        let symmetric = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: symmetric))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 与 Python worker 同口的尾部孤立标点剥离。
public enum VolcengineText {
    private static let orphanTail: NSRegularExpression = {
        // Python: \s+[””’'"」』）)!？?。．，,；;：:…·]+\s*$
        try! NSRegularExpression(pattern: "\\s+[”’'\"」』）)!？?。．，,；;：:…·]+\\s*$")
    }()

    public static func stripTrailingOrphanPunctuation(_ text: String) -> String {
        var result = text
        while true {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            guard let match = orphanTail.firstMatch(in: result, options: [], range: range),
                  let swiftRange = Range(match.range, in: result) else { return result }
            result = String(result[result.startIndex..<swiftRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// 签名绑定原始主机与正文；任何重定向都不应转发正文或认证头。
/// 拒绝后 URLSession 返回原始 3xx，由 translate 按 backend 错误处理。
private final class VolcengineSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class VolcengineClient {
    private let credentialsPath: URL
    private let session: URLSession
    private let timeout: TimeInterval

    public convenience init(credentialsPath: URL, timeout: TimeInterval = 10) {
        self.init(credentialsPath: credentialsPath, timeout: timeout, protocolClasses: nil)
    }

    /// 仅供模块内离线 HTTP 测试替换 URLProtocol；会话策略与重定向保护不变。
    init(credentialsPath: URL, timeout: TimeInterval = 10, protocolClasses: [AnyClass]?) {
        self.credentialsPath = credentialsPath
        self.timeout = timeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpMaximumConnectionsPerHost = 1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { config.protocolClasses = protocolClasses }
        self.session = URLSession(configuration: config, delegate: VolcengineSessionDelegate(),
                                  delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func credentials() throws -> VolcengineCredentials {
        try VolcengineCredentials.load(at: credentialsPath)
    }

    /// 请求体构造独立成静态方法：签名以「实际发送的字节」为准，测试可逐字节
    /// 与 Python 参考 worker 比对（键排序、UTF-8 不转义、无多余空格）。
    public static func payload(source: String, direction: Direction,
                               overrides: [String: String] = [:]) throws -> Data {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.unicodeScalars.count <= 512 else {
            throw VolcengineError.invalidRequest
        }
        let (sourceLanguage, targetLanguage) = direction == .zhToEn ? ("zh", "en") : ("en", "zh")
        var body: [String: Any] = [
            "TargetLanguage": targetLanguage,
            "SourceLanguage": sourceLanguage,
            "TextList": [source],
        ]
        for (key, value) in overrides { body[key] = value }
        let payload = try JSONSerialization.data(withJSONObject: body,
                                                 options: [.sortedKeys, .withoutEscapingSlashes])
        guard payload.count < 65_536 else { throw VolcengineError.invalidRequest }
        return payload
    }

    public func translate(source: String, direction: Direction) async throws -> VolcengineResult {
        // 每次请求重读凭据：设置页保存或移除后无需重建辅助进程即生效。
        let credentials = try credentials()
        let payload = try Self.payload(source: source, direction: direction,
                                       overrides: credentials.requestOverrides)
        let query = VolcengineSigner.canonicalQuery()
        let signed = VolcengineSigner.sign(
            accessKeyId: credentials.accessKeyId,
            secretAccessKey: credentials.secretAccessKey,
            host: credentials.host, region: credentials.region,
            query: query, body: payload, date: Date())
        var request = URLRequest(url: try VolcengineAPI.endpoint(for: credentials))
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.host, forHTTPHeaderField: "Host")
        request.setValue(signed.xDate, forHTTPHeaderField: "X-Date")
        request.setValue(signed.authorization, forHTTPHeaderField: "Authorization")

        let started = DispatchTime.now().uptimeNanoseconds
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw VolcengineError.timeout
        } catch {
            throw VolcengineError.network
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        // data(for:) 已完整缓冲响应；这是解析前的大小检查，不是流式下载／内存上限。
        guard data.count < 60_000 else { throw VolcengineError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else { throw VolcengineError.network }
        guard http.statusCode == 200 else { throw VolcengineError.backend(status: http.statusCode) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["TranslationList"] as? [[String: Any]] else {
            throw VolcengineError.backend(status: http.statusCode)
        }
        guard let first = list.first else { throw VolcengineError.emptyOutput }
        let translation = (first["Translation"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = VolcengineText.stripTrailingOrphanPunctuation(translation)
        guard !stripped.isEmpty else { throw VolcengineError.emptyOutput }
        let characters = (first["Extra"] as? [String: Any])?["input_characters"] as? Int
        return VolcengineResult(target: stripped, characters: characters, milliseconds: elapsed)
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
