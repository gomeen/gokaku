import AppKit
import CoreText
import GogakuCore

private extension NSAttributedString {
    func draw(inRect rect: NSRect) {
        draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
    var widthPt: CGFloat { ceil(size().width) }
}

/// 一次渲染的全部几何与富文本；绘制、命中测试与窗口尺寸都基于它。
/// 数值来自测量出的青简 rime-macos（翠绿）生效规格。
private final class PanelLayout {
    struct Row {
        let indexOfShown: Int
        let frame: NSRect
        let selected: Bool
        let index: NSAttributedString
        let indexWidth: CGFloat
        let wordX: CGFloat
        let word: NSAttributedString
        let wordWidth: CGFloat
        let annotation: NSAttributedString?
        let annotationX: CGFloat
        let annotationWidth: CGFloat
    }

    struct Button {
        let frame: NSRect
        let titleRect: NSRect
        let title: NSAttributedString
        let action: () -> Void
    }

    /// 长文本尾部截断加省略号（预编辑／注释共用规格）。
    static func truncate(_ text: NSAttributedString, maxWidth: CGFloat) -> (NSAttributedString, CGFloat) {
        if text.widthPt <= maxWidth { return (text, text.widthPt) }
        let attrs = text.attributes(at: 0, effectiveRange: nil)
        let ellipsis = "…"
        let ellipsisWidth = (ellipsis as NSString).size(withAttributes: attrs).width
        let limit = max(maxWidth - ellipsisWidth, 1)
        var count = max(1, Int((limit / max(text.widthPt, 1) * CGFloat(text.string.count)).rounded()))
        while count > 0 {
            let candidate = String(text.string.prefix(count)) + ellipsis
            let width = (candidate as NSString).size(withAttributes: attrs).width
            if width <= maxWidth {
                return (NSAttributedString(string: candidate, attributes: attrs), ceil(width))
            }
            count = max(count - 1, 0)
        }
        return (NSAttributedString(string: ellipsis, attributes: attrs), ceil(ellipsisWidth))
    }

    let innerWidth: CGFloat
    let panelWidth: CGFloat
    let totalHeight: CGFloat
    let header: NSAttributedString?
    let headerRect: NSRect
    let preedit: NSAttributedString?
    let preeditCaretX: CGFloat?
    /// 验收接口用：预编辑 UTF16 长度与插入点（仅数值，不含文字）。
    let preeditLengthUTF16: Int
    let preeditCaretUTF16: Int?
    let preeditTextRect: NSRect
    let preeditHitRect: NSRect
    let issueNotice: NSAttributedString?
    let noticeRect: NSRect
    let rows: [Row]
    private(set) var status: NSAttributedString?
    private(set) var statusRect: NSRect
    let page: NSAttributedString?
    let pageRect: NSRect
    let buttons: [Button]
    let pageLabel: String

    init(view: CompositionView, theme: CandidatePanelTheme,
         commitOriginal: (() -> Void)?, switchSource: (() -> Void)?) {
        let m = theme.metrics
        let learning = view.stamp.mode == .learning
        let pageStart = learning ? view.page * CandidatePage.size : 0
        let shown = Array(view.candidates.dropFirst(pageStart).prefix(m.maximumRows))
        let minInner = m.minimumWidth - m.windowPadding * 2
        let maxInner = m.maximumWidth - m.windowPadding * 2

        func attributes(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: color]
        }

        // 1. 行文本与行内容宽度（相对窗口内边距）
        struct RowContent {
            let indexOfShown: Int
            let selected: Bool
            let index: NSAttributedString
            let indexWidth: CGFloat
            let word: NSAttributedString
            let wordWidth: CGFloat
            let annotation: NSAttributedString?
            let annotationWidth: CGFloat
            let contentWidth: CGFloat
        }
        var contents: [RowContent] = []
        for (offset, candidate) in shown.enumerated() {
            let selected = (learning ? pageStart + offset : view.page * CandidatePage.size + offset) == view.selected
            let prefix = learning ? "⌥\(offset + 1)" : "\(offset + 1)"
            let index = NSAttributedString(string: prefix, attributes: attributes(theme.indexFont, selected ? theme.selectedText : theme.indexText))
            let word = NSAttributedString(string: candidate.target, attributes: attributes(theme.candidateFont, selected ? theme.selectedText : theme.candidateText))
            let annotation: NSAttributedString? = candidate.explanation.isEmpty ? nil
                : NSAttributedString(string: candidate.explanation, attributes: attributes(theme.annotationFont, selected ? theme.selectedAnnotation : theme.annotationText))
            var indexWidth = index.widthPt, wordWidth = word.widthPt, annotationWidth = annotation?.widthPt ?? 0
            // 长注释截断（省略号）：行内容不得超过最大内宽，只牺牲注释。
            if let text = annotation, annotationWidth > 0 {
                let fixed = m.rowLeftPadding + m.indexLeftMargin + indexWidth + m.wordLeftMargin + wordWidth + m.annotationLeftMargin
                let available = maxInner - fixed
                if available < annotationWidth {
                    let (truncated, width) = Self.truncate(text, maxWidth: max(available, 24))
                    annotationWidth = width
                    contents.append(RowContent(indexOfShown: offset, selected: selected, index: index, indexWidth: indexWidth,
                                               word: word, wordWidth: wordWidth, annotation: truncated, annotationWidth: annotationWidth,
                                               contentWidth: fixed + annotationWidth))
                    continue
                }
            }
            let contentWidth = m.rowLeftPadding + m.indexLeftMargin + indexWidth + m.wordLeftMargin + wordWidth
                + (annotation != nil ? m.annotationLeftMargin + annotationWidth : 0)
            contents.append(RowContent(indexOfShown: offset, selected: selected, index: index, indexWidth: indexWidth,
                                       word: word, wordWidth: wordWidth, annotation: annotation, annotationWidth: annotationWidth,
                                       contentWidth: contentWidth))
        }

        // 2. 预编辑：已转（gloss）＋插入点＋未转（faint）
        let preeditText = view.preedit.isEmpty ? view.raw : view.preedit
        var preeditString: NSAttributedString?
        var caretX: CGFloat?
        var caretUTF16: Int?
        var preeditWidth: CGFloat = 0
        if !preeditText.isEmpty {
            let typedCount = view.stamp.mode == .normal ? min(view.typedPrefix.count, preeditText.count) : 0
            let typed = String(preeditText.prefix(typedCount))
            let rest = String(preeditText.dropFirst(typedCount))
            let mutable = NSMutableAttributedString()
            mutable.append(NSAttributedString(string: typed, attributes: attributes(theme.annotationFont, theme.typedText)))
            mutable.append(NSAttributedString(string: rest, attributes: attributes(theme.annotationFont, theme.restText)))
            for issue in view.issues where issue.location + issue.length <= mutable.length {
                mutable.addAttributes([
                    .underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
                    .underlineColor: NSColor.systemRed
                ], range: NSRange(location: issue.location, length: issue.length))
            }
            preeditWidth = mutable.widthPt + 2
            preeditString = mutable
            if view.stamp.mode == .normal {
                let offset = max(0, min(view.preeditCaretUTF16 ?? mutable.length, mutable.length))
                let line = CTLineCreateWithAttributedString(mutable)
                caretX = m.windowPadding + CTLineGetOffsetForStringIndex(line, offset, nil)
                caretUTF16 = offset
            }
        }

        // 3. 文本附属
        let statusString = view.status.isEmpty ? nil
            : NSAttributedString(string: view.status, attributes: attributes(theme.annotationFont, theme.statusText))
        let headerString = learning
            ? NSAttributedString(string: "学习 · \(view.stamp.direction == .zhToEn ? "中 → 英" : "英 → 中")",
                                 attributes: attributes(theme.annotationFont, theme.annotationText))
            : nil
        issueNotice = view.issues.isEmpty ? nil
            : NSAttributedString(string: "疑似拼写问题：词典未识别，可能是专名或新词。可继续输入；忽略词可在设置中添加。",
                                 attributes: attributes(theme.annotationFont, theme.statusText))

        // 4. 宽度：按内容钳制（行内容已在上面按 maxInner 截断长注释）
        let widestRow = contents.map(\.contentWidth).max() ?? 0
        innerWidth = min(max(widestRow, preeditWidth, statusString?.widthPt ?? 0, headerString?.widthPt ?? 0, minInner), maxInner)
        panelWidth = innerWidth + m.windowPadding * 2

        // 5. 页码（多于一页才显示）
        let total = view.stamp.mode == .normal ? view.totalCandidates : view.candidates.count
        let totalPages = max(1, (max(total, 1) + CandidatePage.size - 1) / CandidatePage.size)
        pageLabel = "第 \(view.page + 1)/\(totalPages) 页"
        let pageString = totalPages > 1
            ? NSAttributedString(string: "\(view.page + 1)/\(totalPages)", attributes: attributes(theme.indexFont, theme.pageText))
            : nil

        // 6. 纵向排布
        var y = m.windowPadding
        if let headerString {
            header = headerString
            headerRect = NSRect(x: m.windowPadding, y: y, width: innerWidth, height: m.annotationLineHeight)
            y += m.annotationLineHeight
        } else {
            header = nil
            headerRect = .zero
        }
        if preeditString != nil {
            preeditTextRect = NSRect(x: m.windowPadding, y: y, width: innerWidth, height: m.annotationLineHeight)
            preeditHitRect = NSRect(x: 0, y: y - m.topLineVerticalPadding, width: panelWidth,
                                    height: m.annotationLineHeight + m.topLineVerticalPadding * 2)
            y += m.annotationLineHeight + m.topLineVerticalPadding * 2
        } else {
            preeditTextRect = .zero
            preeditHitRect = .zero
        }
        var placed: [Row] = []
        for content in contents {
            let wordX = m.windowPadding + m.rowLeftPadding + m.indexLeftMargin + content.indexWidth + m.wordLeftMargin
            placed.append(Row(indexOfShown: content.indexOfShown,
                              frame: NSRect(x: 0, y: y, width: panelWidth, height: m.rowHeight),
                              selected: content.selected,
                              index: content.index, indexWidth: content.indexWidth,
                              wordX: wordX, word: content.word, wordWidth: content.wordWidth,
                              annotation: content.annotation,
                              annotationX: wordX + content.wordWidth + m.annotationLeftMargin,
                              annotationWidth: content.annotationWidth))
            y += m.rowHeight
        }
        rows = placed
        if let statusString {
            let lines = max(1, Int(ceil(statusString.widthPt / max(innerWidth, 1))))
            let height = CGFloat(lines) * m.annotationLineHeight
            status = statusString
            statusRect = NSRect(x: m.windowPadding, y: y, width: innerWidth, height: height)
            y += height
        } else {
            status = nil
            statusRect = .zero
        }
        if let pageString {
            pageRect = NSRect(x: m.windowPadding + innerWidth - pageString.widthPt,
                              y: y + m.pageFooterTopMargin, width: pageString.widthPt, height: m.indexLineHeight)
            y += m.pageFooterTopMargin + m.indexLineHeight
        } else {
            pageRect = .zero
        }
        var placedButtons: [Button] = []
        if learning {
            let style = attributes(theme.annotationFont, theme.sourceText)
            var titles = [NSAttributedString(string: "原文上屏 ⌘↩", attributes: style)]
            if view.stamp.direction == .zhToEn {
                titles.append(NSAttributedString(string: "切换中文来源", attributes: style))
            }
            var x = m.windowPadding
            for title in titles {
                let width = title.widthPt + 16
                let frame = NSRect(x: x, y: y + 4, width: width, height: m.annotationLineHeight + 8)
                placedButtons.append(Button(frame: frame,
                                            titleRect: NSRect(x: x + 8, y: frame.minY + 4, width: title.widthPt, height: m.annotationLineHeight),
                                            title: title,
                                            action: title.string.hasPrefix("原文") ? (commitOriginal ?? {}) : (switchSource ?? {})))
                x += width + 8
            }
            y += m.annotationLineHeight + 16
        }
        buttons = placedButtons
        if issueNotice != nil {
            noticeRect = NSRect(x: m.windowPadding, y: y, width: innerWidth, height: m.annotationLineHeight * 2)
            y += m.annotationLineHeight * 2
        } else {
            noticeRect = .zero
        }
        preedit = preeditString
        preeditCaretX = caretX
        preeditLengthUTF16 = preeditString?.length ?? 0
        preeditCaretUTF16 = caretUTF16
        totalHeight = y + m.windowPadding
        self.page = pageString
    }
}

/// 候选窗内容视图：按 PanelLayout 逐项自绘；翻转坐标（原点左上）。
final class PanelContent: NSView {
    private(set) var theme = CandidatePanelThemeCatalog.resolve(.rimeMacOSLike)
    private var layout: PanelLayout?
    private var issueNoticeVisible = false
    var choose: ((Int) -> Void)?
    var commitOriginal: (() -> Void)?
    var switchSource: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func updateTheme(_ value: CandidatePanelTheme) {
        theme = value
        needsDisplay = true
    }

    func update(_ view: CompositionView) {
        layout = PanelLayout(view: view, theme: theme,
                             commitOriginal: commitOriginal, switchSource: switchSource)
        setAccessibilityLabel("候选列表，\(layout?.rows.count ?? 0) 项，\(layout?.pageLabel ?? "")")
        needsDisplay = true
    }

    var layoutSize: NSSize {
        guard let layout else { return NSSize(width: theme.metrics.minimumWidth, height: 120) }
        return NSSize(width: layout.panelWidth, height: layout.totalHeight)
    }

    // MARK: 离线渲染检查专用（probes/render-candidate-panel.swift）；输入热路径不调用。
    var debugRowAnnotations: [String] { layout?.rows.map { $0.annotation?.string ?? "" } ?? [] }
    var debugRowFrames: [NSRect] { layout?.rows.map(\.frame) ?? [] }
    var debugSelectedRow: Int { layout?.rows.first(where: \.selected)?.indexOfShown ?? -1 }
    var debugPageLabel: String { layout?.pageLabel ?? "" }
    var debugPageString: String { layout?.page?.string ?? "" }
    var debugPageRect: NSRect { layout?.pageRect ?? .zero }
    var debugPreeditCaretX: CGFloat? { layout?.preeditCaretX }
    var debugPanelWidth: CGFloat { CGFloat(layout?.panelWidth ?? 0) }
    var debugTheme: CandidatePanelTheme { theme }

    #if GOGAKU_VALIDATION
    /// 验收接口：真实窗口当前渲染的拼音插入点（UTF16 长度＋插入点，仅数值）。
    var validationPreeditCaret: [Int]? {
        guard let layout, let caret = layout.preeditCaretUTF16 else { return nil }
        return [layout.preeditLengthUTF16, caret]
    }
    #endif

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layout else { return }
        let m = theme.metrics
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: m.cornerRadius, yRadius: m.cornerRadius)
        theme.panelBackground.setFill()
        background.fill()
        layout.header?.draw(inRect: layout.headerRect)
        layout.preedit?.draw(inRect: layout.preeditTextRect)
        if let caretX = layout.preeditCaretX {
            theme.caretColor.setFill()
            NSBezierPath(rect: NSRect(x: caretX, y: layout.preeditTextRect.minY + 1,
                                      width: 1.5, height: m.annotationLineHeight - 2)).fill()
        }
        for row in layout.rows {
            if row.selected {
                let highlight = NSBezierPath(
                    roundedRect: NSRect(x: m.windowPadding, y: row.frame.minY,
                                        width: layout.innerWidth + m.highlightRightExtension,
                                        height: row.frame.height),
                    xRadius: m.selectionRadius, yRadius: m.selectionRadius)
                theme.selectedFill.setFill()
                highlight.fill()
            }
            row.index.draw(inRect: NSRect(x: m.windowPadding + m.rowLeftPadding + m.indexLeftMargin,
                                          y: row.frame.minY + m.indexTopMargin,
                                          width: row.indexWidth, height: m.indexLineHeight))
            row.word.draw(inRect: NSRect(x: row.wordX, y: row.frame.minY + m.wordTopMargin,
                                         width: row.wordWidth, height: m.candidateLineHeight))
            row.annotation?.draw(inRect: NSRect(x: row.annotationX, y: row.frame.minY + m.indexTopMargin,
                                                width: row.annotationWidth, height: m.annotationLineHeight))
        }
        layout.status?.draw(inRect: layout.statusRect)
        layout.page?.draw(inRect: layout.pageRect)
        if issueNoticeVisible {
            layout.issueNotice?.draw(inRect: layout.noticeRect)
        }
        for button in layout.buttons {
            let box = NSBezierPath(roundedRect: button.frame, xRadius: 4, yRadius: 4)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            box.fill()
            button.title.draw(inRect: button.titleRect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let layout else { return }
        let point = convert(event.locationInWindow, from: nil)
        for row in layout.rows where row.frame.contains(point) {
            choose?(row.indexOfShown)
            return
        }
        for button in layout.buttons where button.frame.contains(point) {
            button.action()
            return
        }
        if layout.issueNotice != nil, layout.preeditHitRect.contains(point) {
            issueNoticeVisible.toggle()
            needsDisplay = true
        }
    }
}

final class CandidatePanel: NSPanel {
    static let shared = CandidatePanel()
    private let content = PanelContent()
    private(set) var generation: UInt64 = 0
    private(set) var contentVisible = false
    private(set) var hideCount: UInt64 = 0
    private(set) var staleRenderCount: UInt64 = 0
    private(set) var renderCount: UInt64 = 0
    private var primed = false
    var stateChanged: (() -> Void)?
    private(set) var theme: CandidatePanelTheme
    private var placementAnchor: NSRect?
    private var placementOrigin: NSPoint?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var choose: ((Int) -> Void)?
    var original: (() -> Void)?
    var switchSource: (() -> Void)?

    #if GOGAKU_VALIDATION
    /// 验收接口：当前布局的拼音插入点（仅数值）与窗口号（真实窗口截图用）。
    var validationPreeditCaret: [Int]? { content.validationPreeditCaret }
    var validationWindowNumber: Int { Int(windowNumber) }
    var validationFrame: [Int] { [Int(frame.minX), Int(frame.minY), Int(frame.width), Int(frame.height)] }
    #endif

    init(themeID: CandidateThemeID = .rimeMacOSLike, fontSize: CGFloat = 14) {
        theme = CandidatePanelThemeCatalog.resolve(themeID, fontSize: fontSize)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: theme.metrics.minimumWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        content.updateTheme(theme)
        content.choose = { [weak self] row in self?.choose?(row) }
        content.commitOriginal = { [weak self] in self?.original?() }
        content.switchSource = { [weak self] in self?.switchSource?() }
        contentView = content
    }

    func updateTheme(_ id: CandidateThemeID, fontSize: CGFloat = 14) {
        if theme.id == id, theme.candidateFont.pointSize == fontSize { return }
        theme = CandidatePanelThemeCatalog.resolve(id, fontSize: fontSize)
        content.updateTheme(theme)
        dismiss()
    }

    /// 延迟矩阵探针专用：只做布局计算，返回目标窗口 frame；不触碰窗口服务器。
    func layoutPanel(_ view: CompositionView, at anchor: NSRect) -> NSRect {
        content.update(view)
        let size = content.layoutSize
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let proposedX = min(max(anchor.minX, visible.minX + 8), visible.maxX - size.width - 8)
        let proposedY: CGFloat
        if anchor.minY - size.height - 8 >= visible.minY {
            proposedY = anchor.minY - size.height - 8
        } else {
            proposedY = min(visible.maxY - size.height - 8, anchor.maxY + 8)
        }
        var origin = (isVisible && placementAnchor == anchor && placementOrigin != nil)
            ? placementOrigin! : NSPoint(x: proposedX, y: proposedY)
        if origin.x + size.width > visible.maxX - 8 {
            origin.x = max(visible.minX + 8, visible.maxX - 8 - size.width)
        }
        content.frame = NSRect(origin: .zero, size: size)
        return NSRect(origin: origin, size: size)
    }

    /// 延迟矩阵探针专用：布局＋几何提交（不触发窗口排序；真实路径中排序
    /// 只发生在启动预热，逐键路径只更新透明度与位置）。
    func renderLayoutOnly(_ view: CompositionView, at anchor: NSRect) {
        let frame = layoutPanel(view, at: anchor)
        setFrame(frame, display: false)
        placementAnchor = anchor
        placementOrigin = frame.origin
    }

    /// 启动时建立 WindowServer 窗口，此后隐藏只改透明度与位置，不重新排序。
    func prime() {
        guard !primed else { return }
        alphaValue = 0
        setFrameOrigin(NSPoint(x: -10000, y: -10000))
        orderFrontRegardless()
        primed = true
    }

    func dismiss() {
        generation &+= 1
        hideCount &+= 1
        placementAnchor = nil
        placementOrigin = nil
        contentVisible = false
        alphaValue = 0
        if primed, frame.origin != NSPoint(x: -10000, y: -10000) {
            setFrameOrigin(NSPoint(x: -10000, y: -10000))
        }
        stateChanged?()
    }

    /// 普通按键只排队；新快照、隐藏或取消都会使旧代次失效。
    func enqueue(_ view: CompositionView, at anchor: NSRect, submitted: (() -> Void)? = nil) {
        generation &+= 1
        let expected = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.generation == expected else {
                self.staleRenderCount &+= 1
                self.stateChanged?()
                return
            }
            self.render(view, at: anchor)
            submitted?()
        }
    }

    func render(_ view: CompositionView, at anchor: NSRect) {
        prime()
        let nextFrame = layoutPanel(view, at: anchor)
        if nextFrame != frame { setFrame(nextFrame, display: false) }
        placementAnchor = anchor
        placementOrigin = nextFrame.origin
        content.displayIfNeeded()
        contentVisible = true
        renderCount &+= 1
        alphaValue = 1
        stateChanged?()
    }
}
