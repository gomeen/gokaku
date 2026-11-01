import Foundation
import Darwin

public struct TranslationRequest: Codable, Equatable, Sendable {
    public var protocolVersion = 1
    public let id: UUID
    public let stamp: InputStamp
    public let sourceID: String
    public let source: String
    public let resource: String
    public var ignoredWords: [String]?
    public init(id: UUID = UUID(), stamp: InputStamp, sourceID: String, source: String, resource: String, ignoredWords: [String]? = nil) {
        self.id = id; self.stamp = stamp; self.sourceID = sourceID; self.source = source; self.resource = resource; self.ignoredWords = ignoredWords
    }
}
public struct TranslationResult: Codable, Sendable {
    public var protocolVersion = 1
    public let id: UUID
    public let stamp: InputStamp
    public let sourceID: String
    public let source: String
    public let resource: String
    public let target: String?
    public let error: String?
    public let milliseconds: Double
    public let issues: [SpellingIssue]?
    public init(request: TranslationRequest, target: String? = nil, error: String? = nil, milliseconds: Double = 0, issues: [SpellingIssue]? = nil) {
        id = request.id; stamp = request.stamp; sourceID = request.sourceID; source = request.source
        resource = request.resource; self.target = target; self.error = error; self.milliseconds = milliseconds; self.issues = issues
    }
}
/// 无文本日志、无端口。此对象只能由自己的串行队列访问。
public final class TranslationService {
    private let executable: URL
    private let arguments: [String]
    private let writer = DispatchQueue(label: "org.gogaku.pipe-write", qos: .userInitiated)
    private let queue = DispatchQueue(label: "org.gogaku.translation")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var running: TranslationRequest?
    private var stopping = false
    private var pending: TranslationRequest?
    private var valid = Set<UUID>()
    private var buffer = Data()
    private var timeout: DispatchWorkItem?
    private var debounce: DispatchWorkItem?
    private var cache: [String: (Date, TranslationResult)] = [:]
    private var cacheBytes = 0
    public var onResult: ((TranslationResult) -> Void)?
    public init(executable: URL, arguments: [String] = []) { self.executable = executable; self.arguments = arguments }
    deinit { process?.terminate() }
    public func request(_ request: TranslationRequest) {
        queue.async {
            self.valid.removeAll(); self.valid.insert(request.id)
            self.pending = nil; self.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.enqueue(request) }
            self.debounce = work; self.queue.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
        }
    }
    public func invalidate() {
        queue.async {
            self.valid.removeAll(); self.pending = nil; self.debounce?.cancel()
            self.cache.removeAll(); self.cacheBytes = 0
            // 逻辑取消不表示当前计算已退出；running 直到收到响应或超时才释放。
        }
    }
    private func key(_ r: TranslationRequest) -> String { "\(r.stamp.direction.rawValue)\u{0}\(r.resource)\u{0}\(r.source)" }
    private func enqueue(_ r: TranslationRequest) {
        guard valid.contains(r.id) else { return }
        if let (date, cached) = cache[key(r)], Date().timeIntervalSince(date) < 300 {
            onResult?(TranslationResult(request: r, target: cached.target, error: cached.error)); return
        }
        if running != nil || stopping { pending = r; return }
        do {
            if process == nil { try start() }
            let data = try JSONEncoder().encode(r)
            guard data.count < 65_536, r.source.unicodeScalars.count <= 512 else {
                onResult?(TranslationResult(request: r, error: "input_limit")); return
            }
            running = r
            guard let input, let worker = process else { throw CocoaError(.fileWriteUnknown) }
            // 管道满或helper尚未读取时，写入不能阻塞失效／超时所在的状态队列。
            writer.async { [weak self] in
                do { try input.write(contentsOf: data + Data([10])) }
                catch {
                    self?.queue.async { [weak self] in
                        guard let self, self.process === worker, self.running?.id == r.id else { return }
                        self.fail("service_unavailable")
                    }
                }
            }
            let work = DispatchWorkItem { [weak self] in self?.fail("timeout") }
            timeout = work; queue.asyncAfter(deadline: .now() + 10, execute: work)
        } catch { running = r; fail("service_unavailable") }
    }
    private func start() throws {
        let p = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        p.executableURL = executable; p.arguments = arguments
        p.standardInput = stdinPipe; p.standardOutput = stdoutPipe; p.standardError = stderrPipe
        // 丢弃 runtime stderr，避免系统错误携带原文进入日志。
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, weak p] handle in
            let data = handle.availableData
            self?.queue.async {
                guard let self, self.process === p, !self.stopping else { return }
                self.read(data)
            }
        }
        p.terminationHandler = { [weak self, weak p] _ in
            self?.queue.async {
                guard let self, self.process === p else { return }
                self.process = nil; self.stopping = false
                self.output?.readabilityHandler = nil; self.output = nil; self.input = nil
                if self.running != nil { self.fail("service_exited") }
                else if let next = self.pending { self.pending = nil; self.enqueue(next) }
            }
        }
        try p.run()
        process = p; input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading
    }
    private func read(_ data: Data) {
        guard !data.isEmpty else { fail("service_eof"); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard line.count < 65_536, let result = try? JSONDecoder().decode(TranslationResult.self, from: line),
                  result.protocolVersion == 1, let r = running, result.id == r.id,
                  result.stamp == r.stamp, result.source == r.source, result.sourceID == r.sourceID,
                  result.resource == r.resource else { fail("invalid_response"); return }
            timeout?.cancel(); timeout = nil; running = nil
            if valid.contains(result.id) {
                if let target = result.target, result.error == nil {
                    let cost = result.source.utf8.count + target.utf8.count
                    if cacheBytes + cost > 1_048_576 { cache.removeAll(); cacheBytes = 0 }
                    self.cache[self.key(r)] = (Date(), result); self.cacheBytes += cost
                    self.queue.asyncAfter(deadline: .now() + 300) { [weak self] in
                        guard let self else { return }
                        self.cache = self.cache.filter { Date().timeIntervalSince($0.value.0) < 300 }
                        self.cacheBytes = self.cache.values.reduce(0) { $0 + $1.1.source.utf8.count + ($1.1.target?.utf8.count ?? 0) }
                    }
                }
                onResult?(result)
            }
            if let next = pending { pending = nil; enqueue(next) }
        }
        if buffer.count >= 65_536 { fail("response_limit") }
    }
    private func fail(_ error: String) {
        timeout?.cancel(); timeout = nil
        if let r = running, valid.contains(r.id) { onResult?(TranslationResult(request: r, error: error)) }
        running = nil; buffer.removeAll()
        output?.readabilityHandler = nil; output = nil; input = nil
        if let old = process, old.isRunning {
            // 仅终止自己创建的辅助进程；实际退出前不启动第二项计算。
            stopping = true
            kill(old.processIdentifier, SIGKILL)
            return
        }
        process = nil; stopping = false
        if let next = pending { pending = nil; enqueue(next) }
    }
}
