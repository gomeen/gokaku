// 渲染路径对比探针：把输入源菜单 PDF 走多个疑似 HUD 渲染路径并光栅化成 PNG，
// 配合像素统计判断「裸笔画/白色方块」在哪个路径出现。
// 用法：swift probes/render-hud-paths.swift <icon.pdf> <outdir>
// 只读本地文件，不触碰系统状态。
import AppKit
import CoreGraphics
import Foundation
import PDFKit

let pdfPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "probes/results"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let name = (pdfPath as NSString).lastPathComponent.replacingOccurrences(of: ".pdf", with: "")

func png(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

func stats(_ image: CGImage, label: String) {
    let width = image.width, height = image.height
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let buffer = context.data else { return }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)
    var opaque = 0, black = 0, transparent = 0
    for i in 0..<(width * height) {
        let a = pixels[i * 4 + 3]
        let r = pixels[i * 4], g = pixels[i * 4 + 1], b = pixels[i * 4 + 2]
        if a > 200 { opaque += 1 }
        if a < 50 { transparent += 1 }
        if a > 200 && r < 50 && g < 50 && b < 50 { black += 1 }
    }
    let total = width * height
    print(String(format: "%@: opaque=%.1f%% black=%.1f%% transparent=%.1f%%",
                 label, Double(opaque) / Double(total) * 100,
                 Double(black) / Double(total) * 100,
                 Double(transparent) / Double(total) * 100))
}

func loadIconCG() -> CGImage? {
    guard let image = NSImage(contentsOfFile: pdfPath), let tiff = image.tiffRepresentation,
          let source = NSBitmapImageRep(data: tiff), let cg = source.cgImage else { return nil }
    return cg
}

func alphaOnlyMask(_ cg: CGImage) -> CGImage? {
    let width = cg.width, height = cg.height
    guard let maskContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
    maskContext.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    return maskContext.makeImage()
}

// 路径 A：NSImage 全彩直出（菜单栏/正常渲染路径）
func pathA() {
    guard let cg = loadIconCG() else { print("A: NSImage load failed"); return }
    stats(cg, label: "A NSImage fullcolor \(cg.width)x\(cg.height)")
    png(cg, to: "\(outDir)/\(name)-A-nsimage-fullcolor.png")
}

// 路径 B：模板化——alpha-only 蒙版 + clip 后按纯色填充（HUD templateView 假设）
func pathB() {
    guard let cg = loadIconCG(), let mask = alphaOnlyMask(cg) else { print("B: load/mask failed"); return }
    let width = cg.width, height = cg.height
    func tinted(_ fill: (CGFloat, CGFloat, CGFloat), suffix: String) {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // 先 clip 再 fill：clip 只影响后续绘制，顺序反了会把整幅填满。
        context.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: mask)
        context.setFillColor(CGColor(red: fill.0, green: fill.1, blue: fill.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let out = context.makeImage() {
            stats(out, label: "B clip-to-mask fill(\(fill.0),\(fill.1),\(fill.2))")
            png(out, to: "\(outDir)/\(name)-B-\(suffix).png")
        }
    }
    tinted((0, 0, 0), suffix: "template-blackfill")
    tinted((1, 1, 1), suffix: "template-whitefill")
}

// 路径 B2：蒙版语义反差——alpha 直接当 image mask（sample 1 = 不着色）。
// 若 HUD 取反失败，capsule 被擦掉、字形镂空区被填充，即「裸笔画」的一种可能形态。
func pathB2() {
    guard let cg = loadIconCG(), let mask = alphaOnlyMask(cg) else { return }
    let width = cg.width, height = cg.height
    guard let invContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return }
    invContext.setFillColor(CGColor(gray: 1, alpha: 1))
    invContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
    invContext.setBlendMode(CGBlendMode.clear)
    invContext.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: mask)
    invContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let inverted = invContext.makeImage() else { return }
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: inverted)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if let out = context.makeImage() {
        stats(out, label: "B2 inverted-mask blackfill")
        png(out, to: "\(outDir)/\(name)-B2-inverted-mask.png")
    }
}

// 路径 C：PDFKit 光栅化（白底嫌疑——HUD 若经 PDFKit 缩略图，透明区会变白）
func pathC() {
    guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)),
          let page = document.page(at: 0) else { print("C: PDFKit load failed"); return }
    let bounds = page.bounds(for: .mediaBox)
    let scale: CGFloat = 8
    let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    let image = page.thumbnail(of: size, for: .mediaBox)
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let cg = rep.cgImage else { print("C: raster failed"); return }
    stats(cg, label: "C PDFKit thumbnail \(cg.width)x\(cg.height)")
    png(cg, to: "\(outDir)/\(name)-C-pdfkit-white.png")
}

// 路径 D：CGContext.drawPDFPage（Preview/Quartz 参考路径）
func pathD() {
    guard let document = CGPDFDocument(URL(fileURLWithPath: pdfPath) as CFURL),
          let page = document.page(at: 1) else { print("D: load failed"); return }
    let box = page.getBoxRect(.mediaBox)
    let scale: CGFloat = 8
    guard let context = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
        bitsPerComponent: 8, bytesPerRow: Int(box.width * scale) * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    context.scaleBy(x: scale, y: scale)
    context.drawPDFPage(page)
    if let cg = context.makeImage() {
        stats(cg, label: "D CGPDF drawPDFPage \(cg.width)x\(cg.height)")
        png(cg, to: "\(outDir)/\(name)-D-cgpdf.png")
    }
}

print("==== \(pdfPath)")
pathA()
pathB()
pathB2()
pathC()
pathD()
