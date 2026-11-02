import AppKit
import CoreGraphics
import Foundation

// A render check, not merely a file-existence check. Reject zero-page/blank
// PDFs, non-22x16 pages, and capsules that do not fill the page (they render
// undersized next to the other input-source icons in the system menu).
//
// 2026-11 强化：输入源切换 HUD 曾显示过期缓存图标（见 probes/tis-icon-probe.swift
// 与 probes/render-hud-paths.swift 的证据），为防「键帽外框丢失、只剩裸笔画」的
// 产物回归，除总墨量外还校验四条边带都有键帽墨量、中心区确有透明字形洞。
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let document = CGPDFDocument(url as CFURL), document.numberOfPages == 1,
      let page = document.page(at: 1) else {
    print("FAIL: menu icon must have exactly one PDF page"); exit(1)
}
let box = page.getBoxRect(.mediaBox)
guard box.size == CGSize(width: 22, height: 16) else {
    print("FAIL: menu icon page must be 22x16pt, got \(box)"); exit(1)
}
let scale: CGFloat = 8
let sideX = Int(box.width * scale), sideY = Int(box.height * scale)
guard let bitmap = CGContext(data: nil, width: sideX, height: sideY, bitsPerComponent: 8,
    bytesPerRow: sideX * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = bitmap.data else { exit(2) }
bitmap.scaleBy(x: scale, y: scale)
bitmap.drawPDFPage(page)
let pixels = data.bindMemory(to: UInt8.self, capacity: sideX * sideY * 4)
var ink = 0, holes = 0, xMin = sideX, yMin = sideY, xMax = 0, yMax = 0
for y in 0..<sideY { for x in 0..<sideX {
    if pixels[(y * sideX + x) * 4 + 3] > 128 {
        ink += 1; xMin = min(xMin, x); yMin = min(yMin, y)
        xMax = max(xMax, x); yMax = max(yMax, y)
    }
} }
// The transparent glyph strokes must exist inside the cap; without them the
// icon degrades into an anonymous black blob.
for y in Int(CGFloat(sideY) * 0.25)..<Int(CGFloat(sideY) * 0.8) {
    for x in Int(CGFloat(sideX) * 0.28)..<Int(CGFloat(sideX) * 0.72) {
        if pixels[(y * sideX + x) * 4 + 3] == 0 { holes += 1 }
    }
}
let marginX = min(xMin, sideX - 1 - xMax), marginY = min(yMin, sideY - 1 - yMax)
guard ink >= 12500, ink < 26000 else {
    // 下限 12500：字形放大后（2026-11-02，对齐鼠须管／青简的字形填充比例）
    // 镔空变大，实测真品墨量 13950；裸笔画产物仍在数千以内被拒。
    print("FAIL: unexpected ink coverage (opaque pixels=\(ink))"); exit(1)
}
guard marginX <= Int(2 * scale), marginY <= Int(2 * scale) else {
    print("FAIL: icon does not fill the 22x16pt page (bounds=(\(xMin),\(yMin))-(\(xMax),\(yMax)))"); exit(1)
}
guard holes > 400 else {
    print("FAIL: glyph holes missing inside the cap (transparent pixels=\(holes))"); exit(1)
}
// 键帽四条边带各占页面 ≤2pt 边距内的墨量必须成规模：裸笔画产物在左右边带
// 几乎无墨，会被这里拦下。阈值按当前带外框产物实测留 40% 余量。
let band = Int(2 * scale)
func bandInk(_ rows: [Range<Int>], _ columns: [Range<Int>]) -> Int {
    var count = 0
    for y in rows.flatMap({ $0 }) {
        for x in columns.flatMap({ $0 }) where pixels[(y * sideX + x) * 4 + 3] > 128 { count += 1 }
    }
    return count
}
let bandTotal = 2 * band * sideX + 2 * band * sideY
let bandPixels = bandInk([0..<band, (sideY - band)..<sideY], [0..<sideX])
    + bandInk([band..<(sideY - band)], [0..<band, (sideX - band)..<sideX])
guard Double(bandPixels) >= Double(bandTotal) * 0.20 else {
    print("FAIL: keycap frame ink missing near page edges (band ink=\(bandPixels)/\(bandTotal)); bare strokes?")
    exit(1)
}
let holeRatio = Double(holes) / Double((Int(CGFloat(sideY) * 0.55)) * (Int(CGFloat(sideX) * 0.44)))
guard holeRatio >= 0.02 else {
    print("FAIL: glyph hole ratio too low inside the cap (\(holeRatio))"); exit(1)
}
print("PASS: 22x16pt page, ink=\(ink), holes=\(holes) (\(String(format: "%.1f", holeRatio * 100))%), band=\(bandPixels)/\(bandTotal), bounds=(\(xMin),\(yMin))-(\(xMax),\(yMax))")
