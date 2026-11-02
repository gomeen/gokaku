// 候选窗离线渲染比对：AppKit 2x 位图逐项核对 demo 规格，误差 ≤1pt。
//
// 覆盖项（docs/prototype-input-habits.md 裁决规格）：
// - 字号：候选 14／注释 13（−1）／序号与页码 11（−3）
// - 行高：46×字号/21 ＝ 30.67pt（14 号）
// - 内边距：窗口 8；高亮 #12996A 左起 x=8、右扩 4、高度＝行高、圆角 4
// - 注释琥珀色 #7D5800（浅色）／#E3A82E（深色）
// - 页码「1/2」多于一页才显示、右对齐
// - 长注释截断省略号且面板宽不超 440；单行短内容时面板 ≥180
// - 预编辑插入点存在；深色主题背景 #2D1E1F
// 产物：docs/validation/panel-render-{light,dark}-2x.png。
//
// 用法：先 swift build（提供 GogakuCore 模块），然后
//   swiftc probes/render-candidate-panel.swift Sources/GogakuInput/CandidatePanel.swift \
//         Sources/GogakuInput/CandidatePanelTheme.swift -I .build/debug/Modules \
//         -L .build/debug -L .build/core -lGogakuCore -lgogaku_core \
//         -Xlinker -rpath -Xlinker "$PWD/.build/core" -o .build/render-panel
//   .build/render-panel
import AppKit
import Foundation
import GogakuCore

var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: String) {
    checks += 1
    print((ok ? "  ok  " : "  FAIL") + " \(what)")
    if !ok { failures += 1 }
}

func approx(_ a: CGFloat, _ b: CGFloat, tol: CGFloat = 1.0) -> Bool { abs(a - b) <= tol }

func makeView(_ configure: (inout CompositionView) -> Void) -> PanelContent {
    var view = CompositionView(stamp: InputStamp(mode: .normal))
    configure(&view)
    let content = PanelContent(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    content.update(view)
    return content
}

func render(_ content: PanelContent, dark: Bool, path: String) -> NSBitmapImageRep {
    let size = content.layoutSize
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    content.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
    // 离线位图没有窗口外观链：把外观直接钉在视图上，adaptive 色按它解析。
    content.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    content.cacheDisplay(in: NSRect(x: 0, y: 0, width: size.width, height: size.height), to: rep)
    content.appearance = nil
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
    return rep
}

func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> (CGFloat, CGFloat, CGFloat) {
    // 输入位图坐标（2x 像素）；返回 0-1 RGB。
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (-1, -1, -1) }
    return (c.redComponent, c.greenComponent, c.blueComponent)
}

func near(_ p: (CGFloat, CGFloat, CGFloat), _ hex: UInt32, tol: CGFloat = 0.06) -> Bool {
    let r = CGFloat((hex >> 16) & 0xFF) / 255, g = CGFloat((hex >> 8) & 0xFF) / 255, b = CGFloat(hex & 0xFF) / 255
    return abs(p.0 - r) <= tol && abs(p.1 - g) <= tol && abs(p.2 - b) <= tol
}

func minColorDistance(_ rep: NSBitmapImageRep, hex: UInt32, rect: NSRect) -> CGFloat {
    // rect 为视图 pt 坐标；位图行序自上而下，两种 y 方向都试，取最小色距。
    let scale = Double(rep.pixelsWide) / Double(rep.size.width)
    let r = CGFloat((hex >> 16) & 0xFF) / 255, g = CGFloat((hex >> 8) & 0xFF) / 255, b = CGFloat(hex & 0xFF) / 255
    var best = CGFloat.greatestFiniteMagnitude
    let x0 = max(0, Int(rect.minX * CGFloat(scale))), x1 = min(rep.pixelsWide - 1, Int(rect.maxX * CGFloat(scale)))
    let y0 = max(0, Int(rect.minY * CGFloat(scale))), y1 = min(rep.pixelsHigh - 1, Int(rect.maxY * CGFloat(scale)))
    if y0 > y1 || x0 > x1 { return best }
    for py in y0...y1 {
        for px in x0...x1 {
            for y in [py, rep.pixelsHigh - 1 - py] {
                let p = pixel(rep, x: px, y: y)
                let d = max(abs(p.0 - r), abs(p.1 - g), abs(p.2 - b))
                if d < best { best = d }
            }
        }
        if best < 0.01 { break }
    }
    return best
}

func scanForColor(_ rep: NSBitmapImageRep, hex: UInt32, rect: NSRect, tol: CGFloat = 0.06) -> Bool {
    minColorDistance(rep, hex: hex, rect: rect) <= tol
}

let outDir = "docs/validation"

func runChecks() {
// ── 字号与行高规格 ─────────────────────────────────────────────
    let theme = CandidatePanelThemeCatalog.resolve(.rimeMacOSLike, fontSize: 14)
    check(approx(theme.candidateFont.pointSize, 14, tol: 0.01), "候选字号 14（实际 \(theme.candidateFont.pointSize)）")
    check(approx(theme.annotationFont.pointSize, 13, tol: 0.01), "注释字号 13＝候选−1（实际 \(theme.annotationFont.pointSize)）")
    check(approx(theme.indexFont.pointSize, 11, tol: 0.01), "序号字号 11＝候选−3（实际 \(theme.indexFont.pointSize)）")
    check(approx(theme.metrics.rowHeight, 46.0 * 14.0 / 21.0, tol: 0.01), "行高 46×14/21＝30.67（实际 \(theme.metrics.rowHeight)）")
    check(approx(theme.metrics.windowPadding, 8, tol: 0.01), "窗口内边距 8")

// ── 正常 9 候选视图（浅色 2x）────────────────────────────────
    var view = CompositionView(stamp: InputStamp(mode: .normal))
view.raw = "nihc"; view.preedit = "ni'hao"; view.typedPrefix = ""
view.preeditCaretUTF16 = 6
view.totalCandidates = 18; view.page = 0; view.selected = 0
    let words = ["你好", "拟好", "你", "好", "号", "毫", "耗", "豪", "嚎"]
    let glosses = ["", "n. imitation", "n. hello · interj. hi", "", "", "", "", "", ""]  // 注释在非选中行（选中行注释按规格为白字）
for (i, w) in words.enumerated() {
    view.candidates.append(Candidate(stamp: view.stamp, sourceID: "t", source: "nihc",
                                     range: RawRange(start: 0, length: 0), target: w,
                                     explanation: glosses[i], resource: "t"))
}
    let content = PanelContent(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
content.update(view)
    check(content.debugRowFrames.count == 9, "渲染 9 行（实际 \(content.debugRowFrames.count)）")
    check(content.debugPageString == "1/2", "两页时绘制页码 1/2（实际 \(content.debugPageString)）")
    check(!content.debugPageRect.isEmpty, "两页时页码有绘制位置")
    if let caret = content.debugPreeditCaretX {
        let width = ("ni'hao" as NSString).size(withAttributes: [.font: theme.annotationFont]).width
        check(approx(caret, 8 + width, tol: 0.5), "展开拼音光标在末尾（x=\(caret)）")
    } else {
        check(false, "预编辑插入点存在")
    }
    // 分段选择场景：预编辑开头为已暂存中文，插入点画在其后。
    var staged = CompositionView(stamp: InputStamp(mode: .normal))
    staged.raw = "nihc"
    staged.preedit = "你好c"
    staged.typedPrefix = "你好"
    staged.preeditCaretUTF16 = 3
    staged.totalCandidates = 4
    staged.selected = 0
    let stagedContent = PanelContent(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    stagedContent.update(staged)
    if let caret = stagedContent.debugPreeditCaretX {
        let stagedWidth = ("你好c" as NSString).size(withAttributes: [.font: theme.annotationFont]).width
        check(approx(caret, 8 + stagedWidth, tol: 0.5),
              "分段选择后光标在剩余编码末尾（x=\(caret)，期望≈\(8 + stagedWidth)）")
    } else {
        check(false, "分段选择时预编辑插入点存在")
    }
    let lightRep = render(content, dark: false, path: "\(outDir)/panel-render-light-2x.png")
    check(lightRep.pixelsWide >= Int(content.layoutSize.width * 2), "2x 位图宽度（\(lightRep.pixelsWide)px / \(content.layoutSize.width)pt）")

// 高亮：第 0 行区域应存在实心 #12996A；行高一致。
    let selectedFrame = content.debugRowFrames[0]
    check(scanForColor(lightRep, hex: 0x12996A, rect: selectedFrame), "选中行高亮 #12996A 存在")
// 琥珀注释色出现在首行注释区域。
    let annotatedRow = content.debugRowFrames[1]
    check(scanForColor(lightRep, hex: 0x7D5800, rect: annotatedRow, tol: 0.16), "琥珀注释 #7D5800 存在于非选中行（最小色距 ≤0.16）")
    check(scanForColor(lightRep, hex: 0xFFFFFF, rect: selectedFrame, tol: 0.06), "选中行注释与文字为白字")
// 高亮高度＝行高（扫描选中行上下边界外 1pt 处无高亮色）。
    let outsideTop = NSRect(x: selectedFrame.minX, y: selectedFrame.maxY + 1, width: 10, height: 0.9)
    check(!scanForColor(lightRep, hex: 0x12996A, rect: outsideTop), "高亮不超过行高（上边界外无高亮色）")
    check(content.debugSelectedRow == 0, "高亮在第 0 行")

// ── 单页短内容：不显示页码，最小宽 180 ────────────────────────
    var small = CompositionView(stamp: InputStamp(mode: .normal))
small.totalCandidates = 1
small.candidates = [Candidate(stamp: small.stamp, sourceID: "t", source: "m",
                              range: RawRange(start: 0, length: 0), target: "你", explanation: "", resource: "t")]
    let smallContent = PanelContent(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
smallContent.update(small)
    check(smallContent.debugPageString == "" && smallContent.debugPageRect.isEmpty, "单页不渲染页码")
    check(approx(smallContent.debugPanelWidth, 180, tol: 0.01), "最小宽 180（实际 \(smallContent.debugPanelWidth)）")

// ── 长注释截断省略号 ─────────────────────────────────────────
    var longView = CompositionView(stamp: InputStamp(mode: .normal))
longView.raw = "mimt"; longView.preedit = "mimt"; longView.totalCandidates = 3
longView.candidates = [
    Candidate(stamp: longView.stamp, sourceID: "t", source: "mimt", range: RawRange(start: 0, length: 0),
              target: "明天下午开会", explanation: "n. meeting · n. conference · v. to hold a meeting · phr. attend the meeting tomorrow afternoon", resource: "t"),
    Candidate(stamp: longView.stamp, sourceID: "t", source: "mimt", range: RawRange(start: 0, length: 0),
              target: "明年", explanation: "n. next year", resource: "t"),
    Candidate(stamp: longView.stamp, sourceID: "t", source: "mimt", range: RawRange(start: 0, length: 0),
              target: "门", explanation: "", resource: "t"),
]
    let longContent = PanelContent(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
longContent.update(longView)
    let longAnnotations = longContent.debugRowAnnotations
    check(longAnnotations[0].contains("…"), "长注释截断含省略号（实际：\(longAnnotations.first ?? "")）")
    check(longContent.debugPanelWidth <= 440.01, "长注释面板宽 ≤440（实际 \(longContent.debugPanelWidth)）")

// ── 深色主题 ─────────────────────────────────────────────────
    let darkRep = render(content, dark: true, path: "\(outDir)/panel-render-dark-2x.png")
// 深色背景采样点避开圆角：pt (20, 4)。
    let bg = pixel(darkRep, x: 40, y: 8)
    check(near(bg, 0x2D1E1F, tol: 0.08), "深色背景 #2D1E1F（实际 RGB \(bg)）")
    check(scanForColor(darkRep, hex: 0x12996A, rect: selectedFrame), "深色高亮仍为 #12996A")
    check(scanForColor(darkRep, hex: 0xE3A82E, rect: annotatedRow, tol: 0.16), "深色注释琥珀 #E3A82E（最小色距 ≤0.16）")

    // 两种预编辑形式、中文暂存与 UTF-16 光标；每项都实际生成 2x 位图。
    for text in ["ni'hao", "nihc", "我jin'tian", "我jbtm"] {
        for offset in 0...(text as NSString).length {
            var caretView = CompositionView(stamp: InputStamp(mode: .normal))
            caretView.preedit = text
            caretView.typedPrefix = text.hasPrefix("我") ? "我" : ""
            caretView.preeditCaretUTF16 = offset
            let caretContent = PanelContent(frame: .zero)
            caretContent.update(caretView)
            let expected = 8 + ((text as NSString).substring(to: offset) as NSString).size(withAttributes: [.font: theme.annotationFont]).width
            check(approx(caretContent.debugPreeditCaretX ?? -1, expected, tol: 0.5), "\(text) 光标 UTF16=\(offset) 横坐标")
            _ = render(caretContent, dark: false, path: "\(outDir)/panel-caret-last-2x.png")
        }
    }

print("候选窗渲染比对：\(checks) 项检查，失败 \(failures) — \(failures == 0 ? "PASS" : "FAIL")")

}

@main
struct RenderPanelProbe {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.async {
            runChecks()
            let panel = CandidatePanel()
            var view = CompositionView(stamp: InputStamp(mode: .normal))
            view.preedit = "nihc"
            var callbacks = 0
            for _ in 0..<200 {
                panel.enqueue(view, at: .zero) { callbacks += 1 }
                panel.dismiss()
            }
            DispatchQueue.main.async {
                check(!panel.contentVisible && panel.alphaValue == 0, "隐藏在当前循环完成")
                check(panel.staleRenderCount == 200 && callbacks == 0, "200 次迟到渲染全部丢弃")
                // 放置几何（真实屏幕）：屏内锚点可布局；完全不在任何屏幕内的
                // 锚点与全零锚点不布局（面板隐藏，组合保留的控制器语义）。
                if let screen = NSScreen.main {
                    let visible = screen.visibleFrame
                    let anchor = NSRect(x: visible.midX, y: visible.midY, width: 0, height: 17)
                    let frame = panel.layoutPanel(view, at: anchor)
                    check(frame != nil, "屏内锚点布局返回 frame")
                    if let frame {
                        check(screen.visibleFrame.contains(frame), "面板落在锚点所在屏幕可视区内")
                    }
                    check(panel.layoutPanel(view, at: .zero) == nil, "全零锚点不布局")
                    check(panel.layoutPanel(view, at: NSRect(x: 99999, y: 99999, width: 0, height: 17)) == nil,
                          "不在任何屏幕内的锚点不布局")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    check(!panel.contentVisible && callbacks == 0, "2 秒内未重新弹出")
                    exit(failures == 0 ? 0 : 2)
                }
            }
        }
        app.run()
    }
}
