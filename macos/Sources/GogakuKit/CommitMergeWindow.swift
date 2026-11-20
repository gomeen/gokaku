import Foundation

/// 学习中→英「提交合并」等待窗口（2026-11 时序修复裁决 B）。
///
/// 背景：用户「输入四键＋空格」全流程常在 1s 内，旧预译防抖＋火山 RTT 使
/// eager 结果几乎总在提交之后才回来，且同一源文同时挂着 eager 与 commit
/// 两个重复请求。裁决后的合同：
/// - 空格提交时同一源文的预译正在飞 → 挂起提交（缓冲后续按键）等待结果，
///   结果回来直接完成上屏，不再自发 commit 请求；
/// - 超过 `waitLimit` 仍无结果 → 兜底回调触发，回退到自发 commit 请求
///   （原有路径，pending 与按键缓冲保持原状）；
/// - 已回退后迟到的 eager 结果只入译文缓存（原有行为）。
public final class CommitMergeWindow {
    /// 等待上限（秒）；超时回退自发 commit 请求。
    public let waitLimit: TimeInterval
    private let queue: DispatchQueue
    private var waitingSource: String?
    private var timeoutWork: DispatchWorkItem?
    private let onTimeout: (String) -> Void

    /// - Parameters:
    ///   - waitLimit: 等待上限（默认 400ms，与诊断书的火山 RTT 量级匹配）。
    ///   - queue: 计时队列；生产为主队列（输入法主线程状态）。
    ///   - onTimeout: 兜底回调，参数为仍在等待的源文；只在等待存续时触发。
    public init(waitLimit: TimeInterval = 0.4, queue: DispatchQueue = .main,
                onTimeout: @escaping @Sendable (String) -> Void) {
        self.waitLimit = waitLimit
        self.queue = queue
        self.onTimeout = onTimeout
    }

    /// 当前是否在等待预译结果。
    public var isWaiting: Bool { waitingSource != nil }

    /// 正在等待的源文；无等待时为 nil。
    public var waitingFor: String? { waitingSource }

    /// 开始等待该源文的预译结果；重复 begin 取消并重启计时。
    public func begin(source: String) {
        cancel()
        waitingSource = source
        let work = DispatchWorkItem { [weak self] in
            guard let self, let source = self.waitingSource else { return }
            self.waitingSource = nil
            self.timeoutWork = nil
            self.onTimeout(source)
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + waitLimit, execute: work)
    }

    /// 预译结果到达：等待中的源文匹配则结束等待并返回 true（调用方直接
    /// 完成提交上屏，不再等自发请求）；不匹配返回 false（等待与兜底继续）。
    /// 已回退（超时已触发）后的迟到结果返回 false——只入译文缓存。
    @discardableResult
    public func fulfilIfWaiting(source: String) -> Bool {
        guard waitingSource == source else { return false }
        cancel()
        return true
    }

    /// 结束等待（提交完成／挂起提交被取消／失焦等），兜底一并取消。
    public func cancel() {
        timeoutWork?.cancel()
        timeoutWork = nil
        waitingSource = nil
    }
}
