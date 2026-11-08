import CoreGraphics
import Foundation

// Draw the identifying strokes as a full-color glyph so the capsule matches
// the black keyboard-cap icons used by the other system input sources.
final class MenuSVG: NSObject, XMLParserDelegate {
    var paths: [(String, CGFloat)] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if elementName == "path", let path = attributes["d"],
           let width = attributes["stroke-width"].flatMap(Double.init) {
            paths.append((path, CGFloat(width)))
        }
    }
}
let destination = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "macos/assets/app-icon/gogaku-menu.pdf")
let svg = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "shared/branding/menu.svg")
let parser = XMLParser(data: try Data(contentsOf: svg))
let source = MenuSVG(); parser.delegate = source
guard parser.parse(), source.paths.count == 2 else {
    fatalError("Expected the two cubic paths in menu.svg")
}
let tokenPattern = try NSRegularExpression(pattern: "[A-Za-z]|[-+]?(?:[0-9]*\\.)?[0-9]+")
func path(_ data: String) -> CGPath {
    let tokens = tokenPattern.matches(in: data, range: NSRange(data.startIndex..., in: data)).map {
        (data as NSString).substring(with: $0.range)
    }
    let result = CGMutablePath(); var index = 0; var command = ""
    func point() -> CGPoint {
        let x = Double(tokens[index])!, y = Double(tokens[index + 1])!
        index += 2; return CGPoint(x: x, y: y)
    }
    while index < tokens.count {
        if tokens[index] == "M" || tokens[index] == "C" { command = tokens[index]; index += 1 }
        switch command {
        case "M": result.move(to: point())
        case "C":
            let c1 = point(), c2 = point(), end = point()
            result.addCurve(to: end, control1: c1, control2: c2)
        default: fatalError("Unsupported menu SVG path command")
        }
    }
    return result
}
var box = CGRect(x: 0, y: 0, width: 22, height: 16)
guard let context = CGContext(destination as CFURL, mediaBox: &box, nil) else {
    fatalError("Cannot create menu PDF")
}
context.beginPDFPage(nil)
// The page is 22x16pt like the other input-source menu icons; a square page
// with a smaller capsule renders visibly undersized next to ABC or Qingjian.
context.translateBy(x: 0, y: 16)
context.scaleBy(x: 22 / 1408, y: -16 / 1024)
let capsule = CGPath(
    roundedRect: CGRect(x: 26, y: 26, width: 1356, height: 972),
    cornerWidth: 290,
    cornerHeight: 290,
    transform: nil
)
// Fill the capsule and subtract the stroked glyph outlines with an even-odd
// path. The glyph is a real transparent hole, so macOS cannot tint it away.
context.setLineCap(.round); context.setLineJoin(.round)
let combined = CGMutablePath()
combined.addPath(capsule)
for (data, width) in source.paths {
    context.beginPath()
    context.addPath(path(data))
    context.setLineWidth(width)
    context.replacePathWithStrokedPath()
    if let hole = context.path { combined.addPath(hole) }
}
context.beginPath()
context.addPath(combined)
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.drawPath(using: .eoFill)
context.endPDFPage()
context.closePDF()
print("已生成 \(destination.path)")
