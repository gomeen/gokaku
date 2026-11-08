import AppKit
import GogakuKit
import ImageIO

/// Candidate-panel visuals are data, so future themes can replace the palette
/// without changing candidate layout or input handling.
///
/// 默认主题按 2026-10-31 输入习惯原型裁决的 Gogaku 规格：候选 14 号（设置 12–16
/// 可调）、注释与拼音 −1、序号与页码 −3、行高 46×字号/21、高亮 #12996A 右扩 4
/// 圆角 4、注释琥珀色 #7D5800／深色 #E3A82E（选中行白字）。数值为独立选定，
/// 不复制青简 GPL 代码或素材。
struct CandidatePanelTheme {
    struct Metrics {
        // window
        let windowPadding: CGFloat
        let minimumWidth: CGFloat
        let maximumWidth: CGFloat
        let cornerRadius: CGFloat
        // preedit line: padding [4,0,4,0]
        let topLineVerticalPadding: CGFloat
        let preeditLineHeight: CGFloat
        // candidate rows
        let rowHeight: CGFloat
        let rowLeftPadding: CGFloat
        let indexTopMargin: CGFloat
        let indexLeftMargin: CGFloat
        let wordTopMargin: CGFloat
        let wordLeftMargin: CGFloat
        let annotationTopMargin: CGFloat
        let annotationLeftMargin: CGFloat
        // highlight: row box extended 4pt right, radius 4
        let highlightRightExtension: CGFloat
        let selectionRadius: CGFloat
        // page footer: margin-top 4, right-aligned
        let pageFooterTopMargin: CGFloat
        let pageLineHeight: CGFloat
        // fonts / line heights (pt): candidate 21/28, annotation 15/19, index 16/20
        let candidateSize: CGFloat
        let candidateLineHeight: CGFloat
        let annotationSize: CGFloat
        let annotationLineHeight: CGFloat
        let indexSize: CGFloat
        let indexLineHeight: CGFloat
        let maximumRows: Int
    }

    let id: CandidateThemeID
    let metrics: Metrics
    let panelBackground: NSColor
    let panelBorder: NSColor
    let sourceText: NSColor
    let typedText: NSColor
    let restText: NSColor
    let caretColor: NSColor
    let candidateText: NSColor
    let indexText: NSColor
    let annotationText: NSColor
    let selectedFill: NSColor
    let selectedText: NSColor
    let selectedAnnotation: NSColor
    let statusText: NSColor
    let pageText: NSColor
    let candidateFont: NSFont
    let annotationFont: NSFont
    let indexFont: NSFont
    let pageFont: NSFont
    let candidateEnglishFont: NSFont
    let annotationEnglishFont: NSFont
    let preeditFont: NSFont
    let preeditEnglishFont: NSFont
    let opacity: CGFloat
    let imageOpacity: CGFloat
    let backgroundImage: NSImage?
    private let source: CandidateTheme
    private let globalFontSize: CGFloat
    private let lightImage: NSImage?
    private let darkImage: NSImage?

    /// 按字符分配字体，英文候选和混排释义都遵循 fontEN，不靠系统字形回退猜语言。
    func text(_ string: String, font: NSFont, englishFont: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        var offset = 0
        for character in string {
            let part = String(character)
            let count = part.utf16.count
            if let scalar = part.unicodeScalars.first,
               scalar.value <= 0x024F || (0x1E00...0x1EFF).contains(scalar.value) {
                result.addAttribute(.font, value: englishFont, range: NSRange(location: offset, length: count))
            }
            offset += count
        }
        return result
    }

    func resolvingAppearance(_ appearance: NSAppearance) -> CandidatePanelTheme {
        Self.make(fontSize: globalFontSize, theme: source,
                  darkAppearance: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                  lightImage: lightImage, darkImage: darkImage)
    }

    static func resolve(_ id: CandidateThemeID, fontSize: CGFloat = 14) -> CandidatePanelTheme {
        resolve(BuiltinCandidateThemes.theme(id), fontSize: fontSize)
    }

    static func resolve(_ theme: CandidateTheme, fontSize: CGFloat = 14) -> CandidatePanelTheme {
        let light = decodeImage(theme.light.imageData)
        let dark = theme.dark?.imageData == theme.light.imageData ? light : decodeImage(theme.dark?.imageData)
        return make(fontSize: fontSize, theme: theme,
                    darkAppearance: NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                    lightImage: light, darkImage: dark)
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// The active Qingjian theme renders candidates in "Fira Code WenKai"
    /// (a kai-style OFL font the user has installed). Reference it by name
    /// without bundling; fall back to the system font when it is absent so
    /// other machines still get a readable panel.
    private static func kai(_ size: CGFloat) -> NSFont {
        NSFont(name: "Fira Code WenKai", size: size) ?? .systemFont(ofSize: size)
    }

    private static func font(_ name: String, size: CGFloat, legacy: Bool) -> NSFont {
        if name == "system-ui" { return legacy ? kai(size) : .systemFont(ofSize: size) }
        return NSFont(name: name, size: size)
            ?? NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size)
            ?? .systemFont(ofSize: size)
    }

    /// 只在 resolve（主题更新）执行；绘制及外观切换复用已解码的 CGImage。
    /// 不接受带外部引用的图片格式；UI/分享包仍负责导入验证。
    private static func decodeImage(_ data: Data?) -> NSImage? {
        guard let data, data.count <= 16 * 1024 * 1024,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              (1...4096).contains(width.intValue), (1...4096).contains(height.intValue),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// 默认主题继续遵循全局 12–16 字号，其余主题使用自身排版参数。
    static func gogakuSpec(fontSize: CGFloat, theme: CandidateTheme = BuiltinCandidateThemes.theme(.rimeMacOSLike)) -> CandidatePanelTheme {
        resolve(theme, fontSize: fontSize)
    }

    private static func make(fontSize: CGFloat, theme: CandidateTheme, darkAppearance: Bool,
                             lightImage: NSImage?, darkImage: NSImage?) -> CandidatePanelTheme {
        let id = theme.id
        func paletteColor(_ key: KeyPath<CandidatePalette, ThemeColor>) -> NSColor {
            adaptive(light: color(theme.light[keyPath: key].rgb),
                     dark: color(theme.palette(darkAppearance: true)[keyPath: key].rgb))
        }
        let legacy = id == .rimeMacOSLike
        let typography = theme.typography.isValid ? theme.typography : .init()
        let selectedVisual = theme.palette(darkAppearance: darkAppearance).visual
        let visual = selectedVisual.isValid ? selectedVisual : CandidateThemeVisual()
        let size = legacy ? min(16, max(12, fontSize.isFinite ? fontSize : 14)) : CGFloat(typography.fontSize)
        let annotationSize = size - (legacy ? 1 : 2)
        let indexSize = legacy ? size - 3 : CGFloat(typography.indexSize)
        let candidateFont = font(typography.fontCN, size: size, legacy: legacy)
        let candidateEnglishFont = font(typography.fontEN, size: size, legacy: legacy)
        let annotationFont = font(typography.fontCN, size: annotationSize, legacy: legacy)
        let annotationEnglishFont = font(typography.fontEN, size: annotationSize, legacy: legacy)
        let preeditFont = font(typography.fontCN, size: legacy ? annotationSize : 13, legacy: legacy)
        let preeditEnglishFont = font(typography.fontEN, size: legacy ? annotationSize : 13, legacy: legacy)
        let indexFont = font(typography.fontEN, size: indexSize, legacy: legacy)
        let pageFont = font(typography.fontEN, size: legacy ? indexSize : 11, legacy: legacy)
        func lineHeight(_ fonts: [NSFont]) -> CGFloat {
            ceil(fonts.map { $0.ascender - $0.descender + $0.leading }.max() ?? size)
        }
        let candidateLineHeight = legacy ? 28 * size / 21 : lineHeight([candidateFont, candidateEnglishFont])
        let annotationLineHeight = legacy ? 19 * annotationSize / 15 : lineHeight([annotationFont, annotationEnglishFont])
        let indexLineHeight = legacy ? 20 * indexSize / 16 : lineHeight([indexFont])
        let rowHeight = (legacy ? 46 * size / 21 : 30) * CGFloat(visual.rowHeight / 100)
        let contentHeight = max(rowHeight, candidateLineHeight, annotationLineHeight, indexLineHeight)
        let lightBackground = legacy ? color(0xFFFFFF) : color(theme.light.background.rgb)
        let darkPalette = theme.palette(darkAppearance: true)
        let darkBackground = legacy ? color(0x2D1E1F) : color(darkPalette.background.rgb)
        // 背景透明度不改变文字和高亮的透明度。
        let panelBackground = adaptive(
            light: lightBackground.withAlphaComponent(CGFloat(theme.light.visual.isValid ? theme.light.visual.bgOpacity / 100 : 1)),
            dark: darkBackground.withAlphaComponent(CGFloat(darkPalette.visual.isValid ? darkPalette.visual.bgOpacity / 100 : 1)))
        return CandidatePanelTheme(
            id: id,
            metrics: Metrics(
                windowPadding: CGFloat(visual.padding),
                minimumWidth: 180,
                maximumWidth: 440,
                cornerRadius: CGFloat(visual.radius),
                topLineVerticalPadding: 4,
                preeditLineHeight: legacy ? annotationLineHeight : lineHeight([preeditFont, preeditEnglishFont]),
                rowHeight: rowHeight,
                rowLeftPadding: legacy ? 5 : 0,
                // 2026-11-03 裁决：行内容垂直居中微调 −2pt（尾钩修复后行内不对称
                // 变得可见，用户要求居中；青简实测边距在此基础上 −2pt）。
                indexTopMargin: legacy ? 6 : max(0, (contentHeight - indexLineHeight) / 2),
                indexLeftMargin: 5,
                wordTopMargin: legacy ? 4.5 : max(0, (contentHeight - candidateLineHeight) / 2),
                wordLeftMargin: 8,
                annotationTopMargin: legacy ? 6 : max(0, (contentHeight - annotationLineHeight) / 2),
                annotationLeftMargin: 8,
                highlightRightExtension: legacy ? min(4, CGFloat(visual.padding)) : 0,
                selectionRadius: 4,
                pageFooterTopMargin: legacy ? 4 : 3,
                pageLineHeight: legacy ? indexLineHeight : lineHeight([pageFont]),
                candidateSize: size,
                candidateLineHeight: candidateLineHeight,
                annotationSize: annotationSize,
                annotationLineHeight: annotationLineHeight,
                indexSize: indexSize,
                indexLineHeight: indexLineHeight,
                maximumRows: CandidatePage.size
            ),
            panelBackground: panelBackground,
            panelBorder: legacy ? .clear : paletteColor(\.border),
            sourceText: legacy ? adaptive(light: color(0x3C3C3C), dark: color(0xEAE9E9)) : paletteColor(\.text),
            typedText: legacy ? adaptive(light: color(0x6B6B6B), dark: color(0xA3A09D)) : paletteColor(\.cursor),
            restText: legacy ? adaptive(light: color(0x757575), dark: color(0x999999)) : paletteColor(\.cursor),
            caretColor: legacy ? adaptive(light: color(0x3C3C3C), dark: color(0xEAE9E9)) : paletteColor(\.cursor),
            candidateText: legacy ? adaptive(light: color(0x3C3C3C), dark: color(0xEAE9E9)) : paletteColor(\.text),
            indexText: legacy ? adaptive(light: color(0x757575), dark: color(0x999999)) : paletteColor(\.index),
            annotationText: legacy ? adaptive(light: color(0x7D5800), dark: color(0xE3A82E)) : paletteColor(\.comment),
            selectedFill: legacy ? color(0x12996A) : paletteColor(\.highlight),
            selectedText: legacy ? color(0xFFFFFF) : paletteColor(\.highlightText),
            selectedAnnotation: legacy ? adaptive(light: color(0xFFFFFF), dark: color(0xEEFAF5)) : paletteColor(\.highlightComment),
            statusText: legacy ? adaptive(light: color(0x6B6B6B), dark: color(0xA3A09D)) : paletteColor(\.cursor),
            pageText: legacy ? adaptive(light: color(0x757575), dark: color(0x999999)) : paletteColor(\.page),
            candidateFont: candidateFont,
            annotationFont: annotationFont,
            indexFont: indexFont, pageFont: pageFont,
            candidateEnglishFont: candidateEnglishFont,
            annotationEnglishFont: annotationEnglishFont,
            preeditFont: preeditFont, preeditEnglishFont: preeditEnglishFont,
            opacity: CGFloat(visual.opacity / 100),
            imageOpacity: CGFloat(visual.imageOpacity / 100),
            backgroundImage: darkAppearance && theme.dark != nil ? darkImage : lightImage,
            source: theme, globalFontSize: fontSize, lightImage: lightImage, darkImage: darkImage
        )
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

enum CandidatePanelThemeCatalog {
    static func resolve(_ id: CandidateThemeID, fontSize: CGFloat = 14) -> CandidatePanelTheme {
        CandidatePanelTheme.resolve(id, fontSize: fontSize)
    }
}
