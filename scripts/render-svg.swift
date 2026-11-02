// 用 NSImage（系统 CoreSVG）把 SVG 光栅化为带透明通道的 PNG。
// 替代 qlmanage：qlmanage 生成的是 Finder 白底缩略图，会把 SVG 的
// 透明边距压成不透明白色，应用图标因此多出一圈白框。
// 用法：render-svg.swift <input.svg> <output.png> <size>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 4, let size = Int(arguments[3]), size > 0 else {
    fatalError("用法：render-svg.swift <input.svg> <output.png> <size>")
}
guard let image = NSImage(contentsOf: URL(fileURLWithPath: arguments[1])) else {
    fatalError("无法读取 SVG：\(arguments[1])")
}
let side = CGFloat(size)
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: side, height: side)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG 编码失败")
}
try data.write(to: URL(fileURLWithPath: arguments[2]))
