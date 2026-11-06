// Vision OCR 一张图片，逐行输出识别文本（预译注释回归专用断言输入）。
// 用法：swift probes/panel-ocr.swift /path/to/capture.png
import Vision
import AppKit

guard CommandLine.arguments.count > 1,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot read image\n".data(using: .utf8)!)
    exit(3)
}
let request = VNRecognizeTextRequest { request, _ in
    guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
    for observation in observations {
        if let text = observation.topCandidates(1).first?.string { print(text) }
    }
}
request.recognitionLevel = .accurate
request.recognitionLanguages = ["zh-Hans", "en-US"]
request.usesLanguageCorrection = false
do { try VNImageRequestHandler(cgImage: cg).perform([request]) }
catch { FileHandle.standardError.write("ocr failed: \(error)\n".data(using: .utf8)!); exit(4) }
