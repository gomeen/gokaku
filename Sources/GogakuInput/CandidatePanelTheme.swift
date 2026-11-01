import AppKit
import GogakuCore

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
        // candidate rows
        let rowHeight: CGFloat
        let rowLeftPadding: CGFloat
        let indexTopMargin: CGFloat
        let indexLeftMargin: CGFloat
        let wordTopMargin: CGFloat
        let wordLeftMargin: CGFloat
        let annotationLeftMargin: CGFloat
        // highlight: row box extended 4pt right, radius 4
        let highlightRightExtension: CGFloat
        let selectionRadius: CGFloat
        // page footer: margin-top 4, right-aligned
        let pageFooterTopMargin: CGFloat
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

    static func resolve(_ id: CandidateThemeID, fontSize: CGFloat = 14) -> CandidatePanelTheme {
        // This is intentionally a catalog seam. Adding a theme only needs a
        // new palette here and a new CandidateThemeID in GogakuCore.
        switch id {
        case .rimeMacOSLike:
            return gogakuSpec(fontSize: fontSize)
        }
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

    /// 2026-10-31 裁决的候选窗规格：候选字号可调，注释 −1、序号/页码 −3，
    /// 行高 46×字号/21，候选行高 28×字号/21、注释行高 19×注释字号/15。
    static func gogakuSpec(fontSize: CGFloat) -> CandidatePanelTheme {
        let size = min(16, max(12, fontSize))
        let annotationSize = size - 1
        let indexSize = size - 3
        return CandidatePanelTheme(
            id: .rimeMacOSLike,
            metrics: Metrics(
                windowPadding: 8,
                minimumWidth: 180,
                maximumWidth: 440,
                cornerRadius: 8,
                topLineVerticalPadding: 4,
                rowHeight: 46.0 * size / 21.0,
                rowLeftPadding: 5,
                indexTopMargin: 8,
                indexLeftMargin: 5,
                wordTopMargin: 6.5,
                wordLeftMargin: 8,
                annotationLeftMargin: 8,
                highlightRightExtension: 4,
                selectionRadius: 4,
                pageFooterTopMargin: 4,
                candidateSize: size,
                candidateLineHeight: 28.0 * size / 21.0,
                annotationSize: annotationSize,
                annotationLineHeight: 19.0 * annotationSize / 15.0,
                indexSize: indexSize,
                indexLineHeight: 20.0 * indexSize / 16.0,
                maximumRows: CandidatePage.size
            ),
            panelBackground: adaptive(light: color(0xFFFFFF), dark: color(0x2D1E1F)),
            sourceText: adaptive(light: color(0x3C3C3C), dark: color(0xEAE9E9)),
            typedText: adaptive(light: color(0x6B6B6B), dark: color(0xA3A09D)),
            restText: adaptive(light: color(0x757575), dark: color(0x999999)),
            caretColor: adaptive(light: color(0x3C3C3C), dark: color(0xEAE9E9)),
            candidateText: adaptive(light: color(0x3C3C3C), dark: color(0xEAE9E9)),
            indexText: adaptive(light: color(0x757575), dark: color(0x999999)),
            annotationText: adaptive(light: color(0x7D5800), dark: color(0xE3A82E)),
            selectedFill: color(0x12996A),
            selectedText: color(0xFFFFFF),
            selectedAnnotation: adaptive(light: color(0xFFFFFF), dark: color(0xEEFAF5)),
            statusText: adaptive(light: color(0x6B6B6B), dark: color(0xA3A09D)),
            pageText: adaptive(light: color(0x757575), dark: color(0x999999)),
            candidateFont: kai(size),
            annotationFont: kai(annotationSize),
            indexFont: kai(indexSize)
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
