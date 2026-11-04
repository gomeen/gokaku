import AppKit
import GogakuCore

/// 临时诊断日志（2026-11-04 英→中「停止输入后译文不出／面板立即消失」排查）。
/// NSLog 在 imklaunchagent 拉起的 IME 进程里进不了统一日志（实测昨晚与今天
/// 均为零命中），故直写文件：~/Library/Application Support/Gogaku/diag.log。
/// 定位后整文件移除。
enum DiagFile {
    private static let queue = DispatchQueue(label: "org.gogaku.diagfile")
    private static var url: URL {
        Paths.support.appendingPathComponent("diag.log")
    }

    static func log(_ message: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "\(formatter.string(from: Date())) [pid \(pid)] \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
    }
}
