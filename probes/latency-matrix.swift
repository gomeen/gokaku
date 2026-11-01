// 全链路延迟矩阵探针：受控 AppKit 宿主内复现普通模式逐键管线，测量：
//   1) 宿主事实读取（selectedRange＋插入点矩形，等价 gg_read_host 的本地成本）
//   2) 共享核心逐键处理（engineQueue.sync → gc_normal_handle）
//   3) 面板更新（PanelLayout 构建＋窗口 setFrame＋提交给系统显示；
//      「提交」为止，不代表物理屏幕刷新，见报告边界说明）
//   4) 输入区字母更新（setMarkedText）
//   5) 空格确认 → 宿主收到文字（insertText 返回且 textStorage 长度变化）
// 场景：短词、长句、翻页、标点（来自冻结 120 条用例的真实小鹤序列）。
// 事件总数 ≥10,000；全部样本保留（无剔除）。
//
// 编译（与 probes/render-candidate-panel.swift 相同方式）：
//   xcrun swiftc -o .build/latency-matrix probes/latency-matrix.swift \
//     Sources/GogakuInput/CandidatePanel.swift Sources/GogakuInput/CandidatePanelTheme.swift \
//     .build/debug/GogakuCore.build/*.o -I .build/debug/Modules -I Sources/CGogakuCore \
//     -I Sources/CGogakuEngine -I Sources/CSQLite -L .build/core -L .build/native \
//     -lgogaku_core -lGogakuEngine -Xlinker -rpath -Xlinker "$PWD/.build/core" \
//     -Xlinker -rpath -Xlinker "$PWD/.build/native"
// 运行：GOGAKU_CORE_TEST_DATA=… .build/latency-matrix [--events 12000]
import AppKit
import Foundation
import GogakuCore

struct Sample {
    var hostNs: Int64 = 0
    var engineNs: Int64 = 0
    var panelNs: Int64 = 0
    var markedNs: Int64 = 0
    var commitNs: Int64 = 0   // 仅确认事件：核心返回 commit 到宿主文字变化
    var submitNs: Int64 = 0   // 窗口几何提交（setFrame display:false）
    var scenario: String
}

let engineQueue = DispatchQueue(label: "org.gogaku.latency", qos: .userInteractive)

func nowNs() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds) }

func percentile(_ xs: [Double], _ p: Double) -> Double {
    let sorted = xs.sorted()
    let idx = min(sorted.count - 1, max(0, Int(p * Double(sorted.count - 1))))
    return sorted[idx]
}

func runMeasurements() {
// ── 环境与引擎 ─────────────────────────────────────────────
    let dataDir = ProcessInfo.processInfo.environment["GOGAKU_CORE_TEST_DATA"]
    ?? (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent("Library/Caches/Gogaku/libime-1.1.17/data")
    var config = NormalEngineConfig(dictPath: (dataDir as NSString).appendingPathComponent("sc.dict"),
                                modelPath: (dataDir as NSString).appendingPathComponent("zh_CN.lm"))
    let cwd = FileManager.default.currentDirectoryPath
config.englishWordsPath = (cwd as NSString).appendingPathComponent("resources/english-words.txt")
config.glossPath = (cwd as NSString).appendingPathComponent("resources/gloss.tsv")
config.freqEnabled = true
config.englishEnabled = true
config.fullPinyinPreedit = true
    let coldStartStart = nowNs()
guard let engine = NormalEngine(config: config) else {
    fputs("engine create failed\n", stderr)
    exit(1)
}
    let coldEngineNs = nowNs() - coldStartStart

// ── 宿主 ──────────────────────────────────────────────────
    let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
    let host = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 400))
host.font = NSFont.systemFont(ofSize: 16)
    let panel = CandidatePanel(themeID: .rimeMacOSLike, fontSize: 14)

    func hostFacts() -> (NSRange, NSRect) {
    let selection = host.selectedRange()
    var actual = NSRange(location: 0, length: 0)
    let rect = host.firstRect(forCharacterRange: selection, actualRange: &actual)
    return (selection, rect)
}

    func applyAndMeasure(_ snap: NormalSnapshot, scenario: String) -> Sample {
    var sample = Sample(scenario: scenario)
    let t0 = nowNs()
    let (selection, rect) = hostFacts()
    sample.hostNs = nowNs() - t0
    sample.engineNs = 0  // 已在外层计入
    // 提交：测量从确认事件返回到宿主文字变化。
    if !snap.commit.isEmpty {
        let c0 = nowNs()
        if host.hasMarkedText() {
            host.insertText("", replacementRange: host.markedRange())
            host.unmarkText()
        }
        let before = (host.string as NSString).length
        host.insertText(snap.commit, replacementRange: NSRange(location: NSNotFound, length: 0))
        let after = (host.string as NSString).length
        assert(after >= before, "宿主文字长度未增长")
        sample.commitNs = nowNs() - c0
    }
    let m0 = nowNs()
    if snap.marked.isEmpty {
        if host.hasMarkedText() {
            host.insertText("", replacementRange: host.markedRange())
            host.unmarkText()
        }
    } else {
        host.setMarkedText(snap.marked, selectedRange: NSRange(location: (snap.marked as NSString).length, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    sample.markedNs = nowNs() - m0
    var submitNs: Int64 = 0
    let p0 = nowNs()
    if snap.composing {
        var view = CompositionView(stamp: InputStamp(mode: .normal))
        view.raw = snap.marked
        view.preedit = snap.preedit
        view.typedPrefix = String(snap.preedit.prefix(snap.typedPrefixLen))
        view.totalCandidates = snap.total
        view.page = snap.page
        view.selected = snap.selected
        view.candidates = snap.candidates.map { item in
            Candidate(stamp: view.stamp, sourceID: "normal:\(item.kind)", source: item.text,
                      range: RawRange(start: 0, length: 0), target: item.text,
                      explanation: item.gloss, resource: "latency-probe")
        }
        view.status = snap.status
        panel.updateTheme(.rimeMacOSLike, fontSize: 14)
        // 与真实输入法一致：面板在组合开始时显示一次；后续逐键只做布局＋几何提交。
        // 布局与窗口几何提交分开计量：几何提交依赖窗口服务器与显示器状态，
        // 在显示器非交互状态下会显著膨胀（报告单独注明）。
        let frame = panel.layoutPanel(view, at: rect)
        let s0 = nowNs()
        panel.setFrame(frame, display: false)
        submitNs = nowNs() - s0
        if !panelVisible {
            let o0 = nowNs()
            panel.orderFrontRegardless()
            orderOnceNs = nowNs() - o0
            panelVisible = true
        }
    } else {
        if panelVisible {
            panel.dismiss()
            panelVisible = false
        }
    }
    sample.panelNs = nowNs() - p0
    return sample
}

// ── 场景脚本 ───────────────────────────────────────────────
// 冻结用例的代表性按键（覆盖短词／长句；标点与翻页另行注入）。
    let shortKeys = ["nihc", "xixi", "zjjm", "kdhv", "mtsj", "feiv", "jihe", "sxae"]
    let longKeys = ["qkjqxtbgkdhvdejwjfawo", "woxlmxtmydjymsjxjy", "hcjqbujmhkjv"]
    var samples: [Sample] = []
var panelVisible = false
var orderOnceNs: Int64 = 0
    var events = 0
    var timeMs: Int64 = 0
    var rng = SystemRandomNumberGenerator()

// 冷启动：引擎创建（词库加载）耗时单列；随后先做一次首键可用性检查。
    let firstKeyStart = nowNs()
    var firstSnapshot: NormalSnapshot?
engineQueue.sync {
    firstSnapshot = engine.handle(.text("n"), app: "latency.app", field: "f", timeMs: { timeMs += 1; return timeMs }())
}
    let firstKeyNs = nowNs() - firstKeyStart
if firstSnapshot != nil { samples.append(applyAndMeasure(firstSnapshot!, scenario: "cold-first-key")) }

    let target = CommandLine.arguments.first(where: { $0.hasPrefix("--events") }).flatMap { Int($0.dropFirst(9)) } ?? 12000

while samples.count < target {
    let roll = Int.random(in: 0..<10, using: &rng)
    var keys: [Character]
    var scenario: String
    if roll < 6 { keys = Array(shortKeys.randomElement()!); scenario = "short" }
    else if roll < 8 { keys = Array(longKeys.randomElement()!); scenario = "long" }
    else if roll < 9 { keys = Array(shortKeys.randomElement()!); scenario = "paging" }
    else { keys = Array(shortKeys.randomElement()!); scenario = "punct" }

    func dispatch(_ event: NormalEvent, label: String) {
        // 主线程循环内逐事件排空 autorelease：与真实 IMK 逐键回到 runloop 一致。
        autoreleasepool {
            let e0 = nowNs()
            var snap: NormalSnapshot?
            engineQueue.sync {
                timeMs += 1
                snap = engine.handle(event, app: "latency.app", field: "f", timeMs: timeMs)
            }
            let engineNs = nowNs() - e0
            guard let s = snap else { return }
            var sample = applyAndMeasure(s, scenario: label)
            sample.engineNs = engineNs
            events += 1
            samples.append(sample)
        }
    }

    for key in keys { dispatch(.text(String(key)), label: scenario) }
    switch scenario {
    case "paging":
        dispatch(.pageDown, label: scenario)
        dispatch(.pageUp, label: scenario)
        dispatch(.space, label: scenario)
    case "punct":
        dispatch(.text(","), label: scenario)
        dispatch(.text("2"), label: scenario)
        dispatch(.text("0"), label: scenario)
        dispatch(.text("."), label: scenario)
    default:
        dispatch(.space, label: scenario)
    }
}

// ── 汇总 ──────────────────────────────────────────────────
    func ms(_ ns: Int64) -> Double { Double(ns) / 1e6 }

    var report: [String: Any] = [
    "checkedAt": ISO8601DateFormatter().string(from: Date()),
    "events": samples.count,
    "engineCreateMs": ms(coldEngineNs),
    "panelOrderOnceMs": ms(orderOnceNs),
    "firstKeyMs": ms(firstKeyNs),
    "loadAverage": ProcessInfo.processInfo.systemUptime,
    "activeProcessors": ProcessInfo.processInfo.activeProcessorCount,
    "note": "候选窗延迟测到窗口提交（setFrame＋orderFront）为止；不含物理屏幕刷新。宿主为受控 NSTextView，非 IMK 客户端。",
]

    func bucket(_ name: String, _ subset: [Sample]) {
    guard !subset.isEmpty else { return }
    func stats(_ get: (Sample) -> Int64) -> [String: Any] {
        let values = subset.map { ms(get($0)) }
        let mean = values.reduce(0, +) / Double(values.count)
        return ["mean": mean, "p50": percentile(values, 0.50), "p95": percentile(values, 0.95),
                "p99": percentile(values, 0.99), "max": values.max() ?? 0]
    }
    let total = stats({ $0.hostNs + $0.engineNs + $0.panelNs + $0.markedNs })
    report[name] = [
        "n": subset.count,
        "totalPerKey": total,
        "hostRead": stats({ $0.hostNs }),
        "engine": stats({ $0.engineNs }),
        "panel": stats({ $0.panelNs }),
        "panelLayoutOnly": stats({ $0.panelNs - $0.submitNs }),
        "panelSubmit": stats({ $0.submitNs }),
        "marked": stats({ $0.markedNs }),
        "commitToHost": stats({ $0.commitNs }),
    ]
}

bucket("all", samples)
for scenario in ["cold-first-key", "short", "long", "paging", "punct"] {
    bucket(scenario, samples.filter { $0.scenario == scenario })
}
// 主线程逐键（核心＋面板排版＋字母更新，不含宿主读取——真实 IMK 中由系统回调提供）：
    let mainThread = samples.map { ms($0.engineNs + $0.panelNs + $0.markedNs) }
report["mainThreadPerKey"] = ["mean": mainThread.reduce(0, +) / Double(mainThread.count),
                              "p50": percentile(mainThread, 0.50), "p95": percentile(mainThread, 0.95),
                              "p99": percentile(mainThread, 0.99), "max": mainThread.max() ?? 0]

    let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let outPath = (cwd as NSString).appendingPathComponent("probes/results/latency-matrix-summary.json")
try! data.write(to: URL(fileURLWithPath: outPath))
print(String(data: data, encoding: .utf8)!)
print("latency matrix: \(samples.count) events → \(outPath)")

}

@main
struct LatencyMatrixProbe {
    static func main() {
        // 窗口／面板操作必须在 AppKit 事件循环启动后进行（runLoop 未启动时
        // orderFront／setFrame 会与 WindowServer 同步异常）。
        let app = NSApplication.shared
        DispatchQueue.main.async {
            runMeasurements()
            exit(0)
        }
        app.run()
    }
}
