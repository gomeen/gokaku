import AppKit
import CoreGraphics
import Foundation

// A render check, not merely a file-existence check. Reject zero-page/blank
// PDFs, non-22x16 pages, and capsules that do not fill the page (they render
// undersized next to the other input-source icons in the system menu).
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
        ink += 1; xMin = min(xMin, x); yMin = min(y, y)
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
guard ink >= 14000, ink < 26000 else {
    print("FAIL: unexpected ink coverage (opaque pixels=\(ink))"); exit(1)
}
guard marginX <= Int(2 * scale), marginY <= Int(2 * scale) else {
    print("FAIL: icon does not fill the 22x16pt page (bounds=(\(xMin),\(yMin))-(\(xMax),\(yMax)))"); exit(1)
}
guard holes > 400 else {
    print("FAIL: glyph holes missing inside the cap (transparent pixels=\(holes))"); exit(1)
}
print("PASS: 22x16pt page, ink=\(ink), holes=\(holes), bounds=(\(xMin),\(yMin))-(\(xMax),\(yMax))")
