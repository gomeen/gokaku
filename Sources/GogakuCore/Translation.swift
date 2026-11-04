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
    /// 云端后端的服务端计费字符数（如火山 Extra.input_characters）；本地后端不发。
    public var characters: Int?
    public init(request: TranslationRequest, target: String? = nil, error: String? = nil, milliseconds: Double = 0, issues: [SpellingIssue]? = nil, characters: Int? = nil) {
        id = request.id; stamp = request.stamp; sourceID = request.sourceID; source = request.source
        resource = request.resource; self.target = target; self.error = error; self.milliseconds = milliseconds; self.issues = issues
        self.characters = characters
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
    private var burst: TranslationRequest?
    private var hardDeadline: DispatchWorkItem?
    private var cache: [String: (Date, TranslationResult)] = [:]
    private var cacheBytes = 0
    public var onResult: ((TranslationResult) -> Void)?
    /// 连续请求的空闲防抖间隔；requestImmediately 不防抖（提交路径）。
    public var debounceInterval: TimeInterval
    /// 是否仍有未完成的请求链（防抖定时／排队／在飞）——任一存在都可能有
    /// 结果随后到达，调用方（面板宽限隐藏）据此顺延，不因云端时延先隐后显。
    public var hasPendingWork: Bool {
        queue.sync {
            burst != nil || pending != nil || running != nil || debounce != nil || hardDeadline != nil
        }
    }
    /// worker 进程是否已就绪（冷启动时为 false——云端 worker 首次请求含
    /// TLS／签名握手，激活期预热可避免首句承担该时延）。
    public var workerRunning: Bool {
        queue.sync { process != nil }
    }
    public init(executable: URL, arguments: [String] = [], debounceInterval: TimeInterval = 0.12) {
        self.executable = executable; self.arguments = arguments; self.debounceInterval = debounceInterval
    }
    deinit { process?.terminate() }
    public func request(_ request: TranslationRequest) {
        queue.async {
            self.valid.removeAll(); self.valid.insert(request.id)
            self.pending = nil; self.burst = request
            self.debounce?.cancel()
            let fire = DispatchWorkItem { [weak self] in self?.fireBurst() }
            self.debounce = fire
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: fire)
            // 连续输入硬上限：纯空闲防抖在键间隔小于防抖时长时会被每键无限顺延
            //（2026-11-04 用户反馈：停顿了很长时间不出来）；慢速连续打字期间
            // 每 2×防抖间隔至少发出一次最新请求。
            if self.hardDeadline == nil {
                let hard = DispatchWorkItem { [weak self] in self?.fireBurst() }
                self.hardDeadline = hard
                self.queue.asyncAfter(deadline: .now() + self.debounceInterval * 2, execute: hard)
            }
        }
    }

    /// 发出当前 burst 的最新请求（空闲防抖与硬上限共用出口）。
    private func fireBurst() {
        debounce?.cancel(); debounce = nil
        hardDeadline?.cancel(); hardDeadline = nil
        guard let r = burst else { return }
        burst = nil
        enqueue(r)
    }
    /// 提交路径免抖动：选词上屏的译文替换不等防抖间隔。
    public func requestImmediately(_ request: TranslationRequest) {
        queue.async {
            self.valid.removeAll(); self.valid.insert(request.id)
            self.pending = nil; self.burst = nil
            self.debounce?.cancel(); self.debounce = nil
            self.hardDeadline?.cancel(); self.hardDeadline = nil
            self.enqueue(request)
        }
    }
    public func invalidate() {
        queue.async {
            self.valid.removeAll(); self.pending = nil; self.burst = nil
            self.debounce?.cancel(); self.debounce = nil
            self.hardDeadline?.cancel(); self.hardDeadline = nil
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
