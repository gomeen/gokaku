import AppKit
import CoreText
import CGogakuCore
import GogakuKit

struct SharedPanelHit {
    let action: Int32
    let argument: Int32
    let rect: CGRect
}

struct SharedPanelBitmap {
    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: CGFloat
    let hits: [SharedPanelHit]

    var pointSize: NSSize {
        NSSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
    }
}

struct PanelBitmapFont: Encodable {
    let path: String
    let index: Int
    let emoji: Bool
    let role: String?
    let postscriptName: String

    private enum CodingKeys: String, CodingKey { case path, index, emoji, role, postscriptName }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(index, forKey: .index)
        try container.encode(emoji, forKey: .emoji)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encode(postscriptName, forKey: .postscriptName)
    }
}

private struct PanelBitmapCandidate: Encodable {
    let text: String
    let gloss: String
}

private struct PanelBitmapIssue: Encodable {
    let location: Int
    let length: Int
    let explanation: String
}

private struct PanelBitmapFrame: Encodable {
    let fonts: [PanelBitmapFont]
    let fontSize: Double
    let candidates: [PanelBitmapCandidate]
    let selected: Int
    let page: Int
    let pageSize: Int
    let pageCount: Int
    let layout: String
    let glossRow: Bool
    let preedit: String
    let preeditCaretUTF16: Int
    let typedPrefixUTF16: Int
    let status: String
    let toast: String
    let hasRestore: Bool
    let hasOriginal: Bool
    let learning: Bool
    let direction: String
    let issues: [PanelBitmapIssue]

    init(view: CompositionView, theme: CandidatePanelTheme, fonts: [PanelBitmapFont], toast: String,
         statusOverride: String?, hasRestore: Bool, hasOriginal: Bool) {
        let horizontal = view.stamp.mode == .normal && view.candidateLayoutHorizontal
        let pageSize = view.stamp.mode == .normal
            ? (horizontal ? view.normalPageSize : CandidatePage.size)
            : CandidatePage.size
        let pageStart = max(0, view.page) * pageSize
        let pageCandidates: ArraySlice<Candidate>
        if view.stamp.mode == .learning {
            pageCandidates = view.candidates.dropFirst(min(pageStart, view.candidates.count)).prefix(pageSize)
        } else {
            pageCandidates = view.candidates.prefix(pageSize)
        }
        let total = view.stamp.mode == .learning
            ? view.candidates.count
            : max(view.totalCandidates, pageStart + pageCandidates.count)
        let pageCount = max(1, (total + pageSize - 1) / pageSize)
        let preedit = view.preedit.isEmpty ? view.raw : view.preedit
        let caret: Int
        if let supplied = view.preeditCaretUTF16 {
            caret = supplied
        } else if view.stamp.mode == .normal || view.stamp.direction == .enToZh {
            caret = preedit.utf16.count
        } else {
            caret = -1
        }
        self.fonts = fonts
        fontSize = Double(theme.metrics.candidateSize)
        candidates = pageCandidates.map { PanelBitmapCandidate(text: $0.target, gloss: $0.explanation) }
        selected = view.selected
        page = max(0, view.page)
        self.pageSize = pageSize
        self.pageCount = pageCount
        layout = horizontal ? "horizontal" : "vertical"
        glossRow = horizontal && view.horizontalGlossRowEnabled
        self.preedit = preedit
        preeditCaretUTF16 = caret
        typedPrefixUTF16 = view.typedPrefix.utf16.count
        status = statusOverride ?? view.status
        self.toast = toast
        self.hasRestore = hasRestore
        self.hasOriginal = hasOriginal
        learning = view.stamp.mode == .learning
        direction = view.stamp.direction.rawValue
        issues = view.issues.map {
            PanelBitmapIssue(location: $0.location, length: $0.length, explanation: $0.explanation)
        }
    }
}

enum SharedPanelBitmapError: Error, Equatable {
    case missingTheme
    case invalidFrame
    case core(Int32)
    case invalidResult
    case imageCreation
}

private final class PanelBitmapFontCache: @unchecked Sendable {
    static let shared = PanelBitmapFontCache()

    private let lock = NSLock()
    private var values: [String: PanelBitmapFont] = [:]

    func font(_ font: NSFont, role: String? = nil, emoji: Bool = false) -> PanelBitmapFont? {
        let key = "\(font.fontName)|\(role ?? "generic")|\(emoji)"
        lock.lock()
        let cached = values[key]
        lock.unlock()
        if let cached { return cached }

        let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        let descriptor = CTFontCopyFontDescriptor(ctFont)
        guard let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL else { return nil }
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: resolvedURL.path) else { return nil }
        let postscriptName = CTFontCopyPostScriptName(ctFont) as String
        let ext = resolvedURL.pathExtension.lowercased()
        let faceIndex = (ext == "ttc" || ext == "otc") ? -1 : 0
        let result = PanelBitmapFont(path: resolvedURL.path, index: faceIndex, emoji: emoji,
                                     role: role, postscriptName: postscriptName)

        lock.lock()
        values[key] = result
        lock.unlock()
        return result
    }
}

/// 主题更新时准备一次；核心拥有独立快照，最后一个 Swift 引用释放时销毁。
final class SharedPanelBitmapTheme {
    let handle: OpaquePointer

    init(_ theme: CandidateTheme) throws {
        let data = try JSONEncoder().encode(theme)
        var value: OpaquePointer?
        let code = data.withUnsafeBytes { bytes in
            gc_panel_theme_create(bytes.bindMemory(to: CChar.self).baseAddress, data.count, &value)
        }
        guard code == 0, let value else { throw SharedPanelBitmapError.core(code) }
        handle = value
    }

    deinit { gc_panel_theme_free(handle) }
}

enum SharedPanelBitmapRenderer {
    static func render(view: CompositionView, theme: CandidatePanelTheme, scale: CGFloat,
                       dark: Bool, toast: String = "", statusOverride: String? = nil,
                       hasRestore: Bool = false, hasOriginal: Bool = false) throws -> SharedPanelBitmap {
        guard let preparedTheme = theme.coreTheme else { throw SharedPanelBitmapError.missingTheme }
        guard scale.isFinite, (0.5...4).contains(scale) else { throw SharedPanelBitmapError.invalidFrame }

        let fonts = fontList(theme: theme)
        guard !fonts.isEmpty else { throw SharedPanelBitmapError.invalidFrame }
        let frame = PanelBitmapFrame(view: view, theme: theme, fonts: fonts, toast: toast,
                                     statusOverride: statusOverride,
                                     hasRestore: hasRestore, hasOriginal: hasOriginal)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let frameData = try? encoder.encode(frame) else {
            throw SharedPanelBitmapError.invalidFrame
        }

        var result: UnsafeMutablePointer<GcPanelResult>?
        let code = frameData.withUnsafeBytes { bytes in
            gc_panel_render_prepared(bytes.bindMemory(to: CChar.self).baseAddress, frameData.count,
                                     preparedTheme.handle, Double(scale), dark ? 1 : 0, &result)
        }
        guard code == 0 else { throw SharedPanelBitmapError.core(code) }
        guard let result else { throw SharedPanelBitmapError.invalidResult }
        defer { gc_panel_result_free(result) }
        let raw = result.pointee
        guard raw.width > 0, raw.height > 0, let pixels = raw.pixels,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SharedPanelBitmapError.invalidResult
        }
        let width = Int(raw.width), height = Int(raw.height)
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow, pixelCount > 0, pixelCount <= 4 * 1024 * 1024,
              pixelCount <= Int.max / 4 else { throw SharedPanelBitmapError.invalidResult }
        let byteCount = pixelCount * 4
        let data = Data(bytes: pixels, count: byteCount)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: width, height: height,
                                    bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: colorSpace,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                                        .union(.byteOrder32Big), provider: provider,
                                    decode: nil, shouldInterpolate: true,
                                    intent: .defaultIntent) else {
            throw SharedPanelBitmapError.imageCreation
        }
        let image = NSImage(cgImage: cgImage,
                            size: NSSize(width: CGFloat(raw.width) / scale,
                                         height: CGFloat(raw.height) / scale))
        var hits: [SharedPanelHit] = []
        if let rawHits = raw.hits {
            hits.reserveCapacity(raw.hit_count)
            for index in 0..<raw.hit_count {
                let hit = rawHits[index]
                hits.append(SharedPanelHit(action: hit.action, argument: hit.arg,
                                           rect: CGRect(x: Int(hit.x), y: Int(hit.y),
                                                        width: Int(hit.w), height: Int(hit.h))))
            }
        }
        return SharedPanelBitmap(image: image, pixelWidth: Int(raw.width), pixelHeight: Int(raw.height),
                                 scale: scale, hits: hits)
    }

    private static func appendUnique(_ font: PanelBitmapFont, to result: inout [PanelBitmapFont]) {
        guard let index = result.firstIndex(where: {
            $0.path == font.path && $0.postscriptName == font.postscriptName
        }) else {
            result.append(font)
            return
        }

        let existing = result[index]
        result[index] = PanelBitmapFont(
            path: existing.path,
            index: existing.index,
            emoji: existing.emoji || font.emoji,
            role: existing.role == "latin" || font.role == "latin" ? "latin" : nil,
            postscriptName: existing.postscriptName
        )
    }

    static func fontList(theme: CandidatePanelTheme) -> [PanelBitmapFont] {
        let cache = PanelBitmapFontCache.shared
        var result: [PanelBitmapFont] = []
        if let font = cache.font(theme.candidateFont) { appendUnique(font, to: &result) }
        if let font = cache.font(theme.candidateEnglishFont, role: "latin") { appendUnique(font, to: &result) }

        let size = theme.metrics.candidateSize
        let pingfang = NSFont(name: "PingFangSC-Regular", size: size).flatMap { cache.font($0) }
        guard let pingfang,
              URL(fileURLWithPath: pingfang.path).lastPathComponent == "PingFang.ttc",
              pingfang.postscriptName == "PingFangSC-Regular" else {
            return []
        }
        appendUnique(pingfang, to: &result)
        if let system = cache.font(NSFont.systemFont(ofSize: size)) {
            appendUnique(system, to: &result)
        }
        if let emoji = NSFont(name: "Apple Color Emoji", size: size),
           let face = cache.font(emoji, emoji: true) {
            appendUnique(face, to: &result)
        }
        return result
    }
}
