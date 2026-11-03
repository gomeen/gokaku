import AppKit
import CoreText
import GogakuCore

private extension NSAttributedString {
    /// 修复降部被裁（2026-11-03）：面板为翻转视图，.usesLineFragmentOrigin 的
    /// 基线在 minY＋字体 boundingRect 上升高度处（13pt Fira Code WenKai ≈16pt），
    /// 而墨迹裁切线在矩形底边（minY＋rect.height）——默认行框高度小于
    /// 「基线＋降部」，g／y／j／p 尾钩只留短桩，增大高度不超过基线＋降部时
    /// 同样被裁。修复：保持 rect.minY（基线不变）而把高度扩到字体 boundingRect，
    /// 裁切边界随之下移，降部完整。超宽文本（状态栏长提示）保留旧换行路径。
    func draw(inRect rect: NSRect) {
        var r = rect
        if r.height < 30, let font = attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            let needed = ceil(font.boundingRectForFont.height) + 2
            if r.height < needed { r.size.height = needed }
        }
        draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
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
        let annotationLines: Int
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
            let annotationLines: Int
            let rowHeight: CGFloat
        }
        var contents: [RowContent] = []
        // 学习中→英：仅高亮候选显示英文注释；长译文在行内换行不截断
        //（2026-11 用户反馈：显示不全）。
        let learningZhToEn = learning && view.stamp.direction == .zhToEn
        for (offset, candidate) in shown.enumerated() {
            let selected = (learning ? pageStart + offset : view.page * CandidatePage.size + offset) == view.selected
            // 学习模式数字直接选词（2026-11 裁决：与普通模式同快捷键，不再用 ⌥数字）。
            let prefix = "\(offset + 1)"
            let index = NSAttributedString(string: prefix, attributes: attributes(theme.indexFont, selected ? theme.selectedText : theme.indexText))
            let word = NSAttributedString(string: candidate.target, attributes: attributes(theme.candidateFont, selected ? theme.selectedText : theme.candidateText))
            let annotation: NSAttributedString? = candidate.explanation.isEmpty ? nil
                : NSAttributedString(string: candidate.explanation, attributes: attributes(theme.annotationFont, selected ? theme.selectedAnnotation : theme.annotationText))
            var indexWidth = index.widthPt, wordWidth = word.widthPt, annotationWidth = annotation?.widthPt ?? 0
            let wrapAnnotation = learningZhToEn && selected
            var annotationLines = 1
            var rowHeight = m.rowHeight
            // 长注释截断（省略号）：行内容不得超过最大内宽，只牺牲注释；
            // 学习中→英高亮行例外：注释在行内换行（最多 3 行），不截断。
            if let text = annotation, annotationWidth > 0 {
                let fixed = m.rowLeftPadding + m.indexLeftMargin + indexWidth + m.wordLeftMargin + wordWidth + m.annotationLeftMargin
                if wrapAnnotation {
                    let available = max(maxInner - fixed, 24)
                    annotationWidth = available
                    annotationLines = min(3, max(1, Int(ceil(text.widthPt / available))))
                    if annotationLines > 1 {
                        rowHeight = m.rowHeight + CGFloat(annotationLines - 1) * m.annotationLineHeight
                    }
                    let contentWidth = fixed
                    contents.append(RowContent(indexOfShown: offset, selected: selected, index: index, indexWidth: indexWidth,
                                               word: word, wordWidth: wordWidth, annotation: annotation, annotationWidth: annotationWidth,
                                               contentWidth: contentWidth, annotationLines: annotationLines, rowHeight: rowHeight))
                    continue
                }
                let available = maxInner - fixed
                if available < annotationWidth {
                    let (truncated, width) = Self.truncate(text, maxWidth: max(available, 24))
                    annotationWidth = width
                    contents.append(RowContent(indexOfShown: offset, selected: selected, index: index, indexWidth: indexWidth,
                                               word: word, wordWidth: wordWidth, annotation: truncated, annotationWidth: annotationWidth,
                                               contentWidth: fixed + annotationWidth, annotationLines: 1, rowHeight: rowHeight))
                    continue
                }
            }
            let contentWidth = m.rowLeftPadding + m.indexLeftMargin + indexWidth + m.wordLeftMargin + wordWidth
                + (annotation != nil ? m.annotationLeftMargin + annotationWidth : 0)
            contents.append(RowContent(indexOfShown: offset, selected: selected, index: index, indexWidth: indexWidth,
                                       word: word, wordWidth: wordWidth, annotation: annotation, annotationWidth: annotationWidth,
                                       contentWidth: contentWidth, annotationLines: 1, rowHeight: rowHeight))
        }

        // 2. 预编辑：已转（gloss）＋插入点＋未转（faint）；长输入自动换行
        //（最多 4 行，超出截头保留尾部＋省略号——2026-11 用户反馈长输入显示不全）
        let preeditText = view.preedit.isEmpty ? view.raw : view.preedit
        var preeditString: NSAttributedString?
        var caretX: CGFloat?
        var caretUTF16: Int?
        var preeditWidth: CGFloat = 0
        var preeditLineCount = 1
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
            preeditLineCount = max(1, Int(ceil(preeditWidth / max(maxInner, 1))))
            if preeditLineCount > 4 {
                // 超过 4 行：按宽度比例截去头部，再微调至合规，头部补省略号。
                // 下划线属性随文字删除自动平移，无需单独换算。
                let targetWidth = CGFloat(4) * maxInner
                let remove = min(max(Int(CGFloat(mutable.length) * (1 - targetWidth / max(preeditWidth, 1))), 0),
                                 mutable.length - 1)
                mutable.deleteCharacters(in: NSRange(location: 0, length: remove))
                while mutable.widthPt + 2 > targetWidth, mutable.length > 1 {
                    mutable.deleteCharacters(in: NSRange(location: 0, length: max(1, mutable.length / 20)))
                }
                mutable.insert(NSAttributedString(string: "…", attributes: attributes(theme.annotationFont, theme.restText)), at: 0)
                preeditWidth = mutable.widthPt + 2
                preeditLineCount = 4
            }
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
        // 顶部「学习 · 方向」标题行已移除（2026-11 用户反馈：不显示）。
        let headerString: NSAttributedString? = nil
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
            let preeditHeight = CGFloat(preeditLineCount) * m.annotationLineHeight
            preeditTextRect = NSRect(x: m.windowPadding, y: y, width: innerWidth, height: preeditHeight)
            preeditHitRect = NSRect(x: 0, y: y - m.topLineVerticalPadding, width: panelWidth,
                                    height: preeditHeight + m.topLineVerticalPadding * 2)
            y += preeditHeight + m.topLineVerticalPadding * 2
        } else {
            preeditTextRect = .zero
            preeditHitRect = .zero
        }
        var placed: [Row] = []
        for content in contents {
            let wordX = m.windowPadding + m.rowLeftPadding + m.indexLeftMargin + content.indexWidth + m.wordLeftMargin
            placed.append(Row(indexOfShown: content.indexOfShown,
                              frame: NSRect(x: 0, y: y, width: panelWidth, height: content.rowHeight),
                              selected: content.selected,
                              index: content.index, indexWidth: content.indexWidth,
                              wordX: wordX, word: content.word, wordWidth: content.wordWidth,
                              annotation: content.annotation,
                              annotationX: wordX + content.wordWidth + m.annotationLeftMargin,
                              annotationWidth: content.annotationWidth,
                              annotationLines: content.annotationLines))
            y += content.rowHeight
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
        // 原文上屏／切换来源按钮行已移除（2026-11 用户裁决：学习面板底部与
        // 中→英界面保持一致）；原文上屏保留 ⌘↩ 隐藏快捷键。
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
                                                width: row.annotationWidth,
                                                height: m.annotationLineHeight * CGFloat(row.annotationLines)))
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
        // isFloatingPanel 的 setter 会把 level 覆写为 floating(3)（实测 AppKit
        // 行为，见 PanelLevelTests 与 2026-11-02 真机核查）：必须先设它再设
        // level，否则候选窗基准层级被钳在 floating，被 Bob 等层级 ≥modalPanel
        // (8) 的宿主浮窗遮挡（用户报告的遮挡根因之一）。
        isFloatingPanel = true
        level = .popUpMenu
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

    /// 延迟矩阵探针专用：只做布局计算，返回目标窗口 frame；无法安全显示时返回 nil。
    func layoutPanel(_ view: CompositionView, at anchor: NSRect) -> NSRect? {
        content.update(view)
        let size = content.layoutSize
        let screens = NSScreen.screens.map { ScreenFrame(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        guard let proposed = PanelPlacement.origin(anchor: anchor, panelSize: size, screens: screens) else { return nil }
        // 同一坐标不重复布局：同锚点复用上次 origin，但重算尺寸后必须仍在
        // 屏幕可视区内，越界时回退到重新计算的位置。
        var origin = (isVisible && placementAnchor == anchor && placementOrigin != nil)
            ? placementOrigin! : proposed
        if !PanelPlacement.isContained(origin: origin, panelSize: size, screens: screens) {
            origin = proposed
        }
        content.frame = NSRect(origin: .zero, size: size)
        return NSRect(origin: origin, size: size)
    }

    /// 延迟矩阵探针专用：布局＋几何提交（不触发窗口排序；真实路径中排序发生在
    /// 启动预热，且逐键 render 在目标层级变化时重排一次——本探针路径不传层级、
    /// 不排序，只更新位置与透明度）。无效位置不显示。
    func renderLayoutOnly(_ view: CompositionView, at anchor: NSRect) {
        if let frame = layoutPanel(view, at: anchor) {
            setFrame(frame, display: false)
            placementAnchor = anchor
            placementOrigin = frame.origin
        }
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

    /// 普通按键只排队；新快照、隐藏或取消都会使旧代次失效。目标层级随快照
    /// 一起排队：迟到代次被整代拒绝，不会把旧层级套在新渲染上。
    /// targetWindowLevel＝已按宿主层级算好的最终目标层级（GogakuHost
    /// GGPanelTargetLevel 的结果；nil＝不改层级，离线探针等不传参路径行为不变）。
    func enqueue(_ view: CompositionView, at anchor: NSRect,
                 targetWindowLevel: Int? = nil, submitted: (() -> Void)? = nil) {
        generation &+= 1
        let expected = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.generation == expected else {
                self.staleRenderCount &+= 1
                self.stateChanged?()
                return
            }
            self.render(view, at: anchor, targetWindowLevel: targetWindowLevel)
            submitted?()
        }
    }

    /// 渲染当前组合视图并把窗口排序修正到给定目标层级（调用方已按宿主层级算好；
    /// 策略纯函数 GGPanelTargetLevel 在 GogakuHost，由 HostTests／PanelLevelTests
    /// 覆盖）。层级变化必须先设 level 再重新排序才对 WindowServer 生效；层级
    /// 相同不置前，避免逐键无条件置前。只改排序，不触碰位置与透明度。
    private func applyClientWindowLevel(targetLevel: Int) {
        guard targetLevel != level.rawValue else { return }
        level = NSWindow.Level(rawValue: targetLevel)
        orderFrontRegardless()
    }

    /// 渲染当前组合视图并按目标层级修正排序（nil＝不改层级）。隐藏恢复走同一
    /// 路径：层级不同才置前一次。
    func render(_ view: CompositionView, at anchor: NSRect,
                targetWindowLevel: Int? = nil) {
        guard let nextFrame = layoutPanel(view, at: anchor) else {
            // 无有效坐标（锚点不在任何屏幕内等）：不显示，交由控制器保留组合。
            dismiss()
            return
        }
        prime()
        if let target = targetWindowLevel { applyClientWindowLevel(targetLevel: target) }
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
