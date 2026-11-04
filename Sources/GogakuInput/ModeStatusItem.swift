import AppKit
import GogakuCore

/// kiho 式模式指示（2026-11-04 用户裁决）：Gogaku 激活时在菜单栏显示自绘
/// 状态项——学习模式＝填充胶囊（镂空两笔），普通模式＝仅镂空两笔不填充；
/// 切到其它输入源即隐藏。系统输入菜单里的图标由 TIS 启动时缓存，无法按
/// 模式动态刷新，因此自建状态项承担状态展示。
final class ModeStatusItem: NSObject {
    static let shared = ModeStatusItem()

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let normalIcon = ModeStatusItem.icon(filled: false)
    private let learningIcon = ModeStatusItem.icon(filled: true)
    private var shown = false

    private override init() {
        super.init()
        let menu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        item.menu = menu
        item.button?.image = normalIcon
    }

    /// 模式变化时刷新填充态。
    func update(mode: InputMode) {
        item.button?.image = mode == .learning ? learningIcon : normalIcon
    }

    /// Gogaku 成为当前输入源时显示。
    func show(mode: InputMode) {
        update(mode: mode)
        item.isVisible = true
        shown = true
    }

    /// 切走时隐藏，不留常驻。
    func hide() {
        item.isVisible = false
        shown = false
    }

    @objc private func openSettings(_ sender: Any?) {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Gogaku Settings.app"))
    }

    // MARK: - 图标绘制（与 icon.svg 两笔同构，模板单色）

    private static func icon(filled: Bool, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let s = size / 1024
            let context = NSGraphicsContext.current!.cgContext
            if filled {
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(origin: .zero, size: CGSize(width: size, height: size)),
                             xRadius: 230 * s, yRadius: 230 * s).fill()
            }
            // 填充态用 .clear 把两笔从胶囊里抠出（模板图 alpha 即形状）；
            // 非填充态直接画两笔，不填充。
            drawStrokes(in: context, scale: s, width: max(100 * s, 2.0),
                        blend: filled ? .clear : .normal)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// icon.svg 的镂空两笔（SVG y 向下，此处翻转；圆头）。
    private static func drawStrokes(in context: CGContext, scale s: CGFloat, width: CGFloat, blend: CGBlendMode) {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: (1024 - y) * s) }
        context.saveGState()
        context.setBlendMode(blend)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        // 上笔：M 369.5 446 C 388 444.5 447 440 480.5 437 C 514 434 555.5 429.5 570.5 428
        context.beginPath()
        context.move(to: pt(369.5, 446))
        context.addCurve(to: pt(480.5, 437),
                         control1: pt(388, 444.5), control2: pt(447, 440))
        context.addCurve(to: pt(570.5, 428),
                         control1: pt(514, 434), control2: pt(555.5, 429.5))
        context.strokePath()
        // 下笔：M 312.5 563 C 335.5 572.8 400 604.8 450.5 621.5 C 501 638.2 588 656.5 615.5 663.5
        context.beginPath()
        context.move(to: pt(312.5, 563))
        context.addCurve(to: pt(450.5, 621.5),
                         control1: pt(335.5, 572.8), control2: pt(400, 604.8))
        context.addCurve(to: pt(615.5, 663.5),
                         control1: pt(501, 638.2), control2: pt(588, 656.5))
        context.strokePath()
        context.restoreGState()
    }
}
