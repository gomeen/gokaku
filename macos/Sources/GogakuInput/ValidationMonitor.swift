#if GOGAKU_VALIDATION
import AppKit
import Darwin

/// 仅验收构建包含；私有开关显式启用。只导出事件类别、耗时和面板状态，不接收或记录文字。
final class ValidationMonitor {
    static let shared = ValidationMonitor()
    private let queue = DispatchQueue(label: "org.gogaku.validation.socket")
    private var source: DispatchSourceRead?
    private var descriptor: Int32 = -1
    private(set) var enabled = false
    private var samples: [[String: Any]] = []
    private var starts: [UInt64: UInt64] = [:]
    private var eventStarts: [UInt64: UInt64] = [:]
    private var positions: [UInt64: Int] = [:]
    private var nextID: UInt64 = 0
    private(set) var currentEvent: UInt64?
    private var confirmationCount = 0
    private var confirmationHideFailures = 0
    private var scenarioName = ""

    private init() {}

    func start() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Gogaku")
        let marker = directory.appendingPathComponent("validation-enabled")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: marker.path),
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent("validation.sock").path
        guard path.utf8.count < 104 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyBytes(from: $0) }
        }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        unlink(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor); descriptor = -1; return
        }
        enabled = true
        let stream = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        stream.setEventHandler { [weak self] in self?.acceptRequest() }
        source = stream
        stream.resume()
    }

    private func acceptRequest() {
        let connection = accept(descriptor, nil, nil)
        guard connection >= 0 else { return }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = Darwin.read(connection, &bytes, bytes.count)
        guard count > 0 else { Darwin.close(connection); return }
        let command = String(decoding: bytes.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // scenario <name>：给后续样本打场景标识（只允许无空格的安全字符）。
        if command.hasPrefix("scenario ") {
            let name = String(command.dropFirst("scenario ".count))
            let allowed = name.count <= 64 && !name.isEmpty
                && name.allSatisfy { c in c.isLetter || c.isNumber || "_.:/-".contains(c) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { Darwin.close(connection); return }
                if allowed { self.scenarioName = name }
                let ack: [String: Any] = ["scenario": allowed ? name : "", "accepted": allowed]
                let data = (try? JSONSerialization.data(withJSONObject: ack, options: [.sortedKeys])) ?? Data("{}".utf8)
                self.queue.async {
                    var payload = data; payload.append(10)
                    payload.withUnsafeBytes { buffer in
                        _ = Darwin.write(connection, buffer.baseAddress!, buffer.count)
                    }
                    Darwin.close(connection)
                }
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { Darwin.close(connection); return }
            let panel = CandidatePanel.shared
            var response: [String: Any] = [
                "visible": panel.contentVisible, "generation": panel.generation,
                "hideCount": panel.hideCount, "staleRenderCount": panel.staleRenderCount,
                "renderCount": panel.renderCount,
                "confirmationCount": self.confirmationCount,
                "confirmationHideFailures": self.confirmationHideFailures,
                "scenario": self.scenarioName,
                "panelPreeditCaret": panel.validationPreeditCaret ?? NSNull(),
                "panelWindowNumber": panel.validationWindowNumber,
                "panelFrame": panel.validationFrame,
                "events": self.samples.count
            ]
            if command == "metrics" { response["samples"] = self.samples }
            if command == "reset" {
                self.samples.removeAll(keepingCapacity: true); self.positions.removeAll(); self.starts.removeAll(); self.eventStarts.removeAll()
                self.confirmationCount = 0; self.confirmationHideFailures = 0
            }
            let data = (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data("{}".utf8)
            self.queue.async {
                var payload = data; payload.append(10)
                payload.withUnsafeBytes { buffer in
                    var written = 0
                    while written < buffer.count {
                        let n = Darwin.write(connection, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                        if n <= 0 { break }
                        written += n
                    }
                }
                Darwin.close(connection)
            }
        }
    }

    func begin(type: UInt, timestamp: TimeInterval, keyCode: Int = -1) -> UInt64? {
        guard enabled else { return nil }
        nextID &+= 1
        let id = nextID, now = DispatchTime.now().uptimeNanoseconds
        currentEvent = id
        starts[id] = now
        let eventStart = UInt64(max(0, timestamp) * 1_000_000_000)
        eventStarts[id] = eventStart
        positions[id] = samples.count
        var sample: [String: Any] = ["id": id, "type": type, "startNs": now,
                        "eventNs": eventStart, "queueNs": now >= eventStart ? now - eventStart : 0,
                        "clockValid": eventStart > 0 && eventStart <= now]
        if keyCode >= 0 { sample["keyCode"] = keyCode }
        if !scenarioName.isEmpty { sample["scenario"] = scenarioName }
        samples.append(sample)
        return id
    }

    func startTime(_ id: UInt64?) -> UInt64? { id.flatMap { eventStarts[$0] } }

    func end(_ id: UInt64?, consumed: Bool) {
        guard let id, let index = positions[id], let start = starts[id] else { return }
        samples[index]["callbackNs"] = DispatchTime.now().uptimeNanoseconds - start
        samples[index]["consumed"] = consumed
        samples[index]["visibleAtReturn"] = CandidatePanel.shared.contentVisible
        currentEvent = nil
    }

    func phase(_ field: String, duration: UInt64) {
        guard let id = currentEvent, let index = positions[id] else { return }
        samples[index][field] = (samples[index][field] as? UInt64 ?? 0) + duration
    }

    func core(_ duration: UInt64) {
        guard let id = currentEvent, let index = positions[id] else { return }
        samples[index]["coreNs"] = duration
    }

    /// 事件内最后一次读到的宿主选区（仅数值，不含文字）。
    func selectionRead(_ range: NSRange) {
        guard let id = currentEvent, let index = positions[id] else { return }
        samples[index]["hostSelection"] = [range.location, range.length]
    }

    func commit(_ duration: UInt64) {
        guard let id = currentEvent, let index = positions[id] else { return }
        let hidden = !CandidatePanel.shared.contentVisible
        samples[index]["commitCallNs"] = duration
        samples[index]["commitCount"] = (samples[index]["commitCount"] as? Int ?? 0) + 1
        samples[index]["confirmationHidden"] = hidden
        confirmationCount += 1
        if !hidden { confirmationHideFailures += 1 }
    }

    func rendered(_ id: UInt64?, compositionStart: UInt64?, first: Bool) {
        guard let id, let index = positions[id], let start = eventStarts[id] else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard start > 0, now >= start else { return }
        samples[index]["renderNs"] = now - start
        samples[index]["firstDisplay"] = first
        if first, let compositionStart { samples[index]["firstDisplayNs"] = now - compositionStart }
    }
}
#endif
