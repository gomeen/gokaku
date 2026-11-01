// Disposable controlled AppKit client, not an installed InputMethodKit front-end.
import AppKit
import Foundation

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let host = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 160))
host.isAutomaticSpellingCorrectionEnabled = false
host.isContinuousSpellCheckingEnabled = false
host.isGrammarCheckingEnabled = false
host.font = NSFont.systemFont(ofSize: 16)
let candidates = NSTextField(labelWithString: "")
candidates.frame = NSRect(x: 0, y: 0, width: 760, height: 260)
candidates.font = NSFont.systemFont(ofSize: 14)
candidates.maximumNumberOfLines = 10

func clearMarked() {
    if host.hasMarkedText() {
        host.insertText("", replacementRange: host.markedRange())
        host.unmarkText()
    }
}

while let line = readLine() {
    do {
        guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let op = request["op"] as? String else {
            throw NSError(domain: "probe.request", code: 1)
        }
        if op == "quit" {
            print("{\"ok\":true}")
            fflush(stdout)
            break
        }
        let start = DispatchTime.now().uptimeNanoseconds
        if op == "reset" {
            host.string = request["text"] as? String ?? ""
            host.setSelectedRange(NSRange(location: (host.string as NSString).length, length: 0))
            candidates.stringValue = ""
        } else if op == "render" {
            guard let state = request["state"] as? [String: Any],
                  let commit = state["commit"] as? String,
                  let preedit = state["preedit"] as? String,
                  let composing = state["composing"] as? Bool,
                  let texts = state["candidates"] as? [String] else {
                throw NSError(domain: "probe.state", code: 2)
            }
            if !commit.isEmpty {
                host.insertText(commit, replacementRange: NSRange(location: NSNotFound, length: 0))
                host.unmarkText()
            }
            if composing {
                host.setMarkedText(preedit,
                    selectedRange: NSRange(location: (preedit as NSString).length, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
            } else {
                clearMarked()
            }
            var lines: [String] = []
            for (index, text) in texts.enumerated() {
                lines.append(String(index + 1) + ". " + text)
            }
            candidates.stringValue = lines.joined(separator: "\n")
        } else {
            throw NSError(domain: "probe.operation", code: 3)
        }
        host.layoutManager?.ensureLayout(for: host.textContainer!)
        host.layoutSubtreeIfNeeded()
        candidates.layoutSubtreeIfNeeded()
        // Optional diagnostic only: production updates must not wait for screenshots.
        let rasterize = request["rasterize"] as? Bool ?? false
        if rasterize {
            guard let bitmap = candidates.bitmapImageRepForCachingDisplay(in: candidates.bounds) else {
                throw NSError(domain: "probe.bitmap", code: 4)
            }
            candidates.cacheDisplay(in: candidates.bounds, to: bitmap)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let mark = host.markedRange()
        var response: [String: Any] = [:]
        response["ok"] = true
        response["host_text"] = host.string
        response["has_marked_text"] = host.hasMarkedText()
        response["marked_location"] = mark.location == NSNotFound ? -1 : mark.location
        response["marked_length"] = mark.length
        response["native_ns"] = elapsed
        response["candidate_text"] = candidates.stringValue
        response["rasterized"] = rasterize
        response["scope"] = "Controlled NSTextView + AppKit layout preparation; optional offscreen raster; no IMK/external host/display"
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } catch {
        let data = try! JSONSerialization.data(withJSONObject: ["ok": false, "error": String(describing: error)])
        print(String(decoding: data, as: UTF8.self))
    }
    fflush(stdout)
}
