import XCTest
import AppKit
import GogakuKit
@testable import GogakuInput

/// 把横排布局按真实几何画成 PNG，供人工核对序号与页码（不依赖真实宿主）。
final class HorizontalRenderDumpTests: XCTestCase {
    func testDumpHorizontalRender() throws {
        var view = CompositionView(stamp: InputStamp(mode: .normal, direction: .zhToEn))
        view.candidateLayoutHorizontal = true
        view.normalPageSize = 8
        view.horizontalGlossRowEnabled = false
        view.page = 0
        view.selected = 0
        view.totalCandidates = 40
        view.preedit = "heng"
        let words = ["橫", "行", "恒", "哼", "衡", "亨", "隈", "蘅"]
        view.candidates = words.enumerated().map { i, w in
            Candidate(stamp: view.stamp, sourceID: "t", source: w, range: RawRange(start: 0, length: 0),
                      target: w, explanation: "", resource: "test")
        }
        let theme = CandidatePanelTheme.resolve(.rimeMacOSLike, fontSize: 14)
        let layout = PanelLayout.horizontalNormal(view: view, theme: theme)
        let m = theme.metrics
        let size = NSSize(width: layout.panelWidth, height: layout.totalHeight)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        // 翻转坐标系与面板一致
        NSGraphicsContext.current?.imageInterpolation = .high
        layout.preedit?.draw(in: layout.preeditTextRect)
        for row in layout.rows {
            if row.selected {
                theme.selectedFill.setFill()
                NSBezierPath(roundedRect: row.frame, xRadius: m.selectionRadius, yRadius: m.selectionRadius).fill()
            }
            row.index.draw(in: NSRect(x: row.indexX, y: row.frame.minY + m.indexTopMargin,
                                          width: row.indexWidth, height: m.indexLineHeight))
            row.word.draw(in: NSRect(x: row.wordX, y: row.frame.minY + m.wordTopMargin,
                                         width: row.wordWidth, height: m.candidateLineHeight))
        }
        layout.page?.draw(in: layout.pageRect)
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let out = URL(fileURLWithPath: "/tmp/horizontal-render.png")
        try rep.representation(using: .png, properties: [:])!.write(to: out)
        print("渲染输出:", out.path, "尺寸:", size)
        XCTAssertEqual(layout.rows.count, 8)
    }
}
