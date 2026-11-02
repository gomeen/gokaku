import Foundation
import AppKit

/// 屏幕几何的值类型：离线几何测试可用假屏幕，不必创建真实 NSScreen。
public struct ScreenFrame: Equatable, Sendable {
    public let frame: NSRect
    public let visibleFrame: NSRect
    public init(frame: NSRect, visibleFrame: NSRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// 候选窗放置的纯几何计算（2026-11-03 定稿）：
/// - 只在包含锚点的屏幕内显示；锚点完全不在任何屏幕内 → 不显示。
/// - 非有限值、负尺寸的锚点或面板尺寸 → 不显示；零宽光标矩形有效。
/// - 默认插入点右下（margin 8pt）；下方空间不足时上翻；上翻越界时回推。
/// - 最终 origin 钳制在屏幕可视区内，支持负坐标与不同缩放。
public enum PanelPlacement {
    public static let margin: CGFloat = 8

    /// 粘性 origin 复用前的越界检查：面板完全落在某一屏幕可视区内才可复用。
    public static func isContained(origin: NSPoint, panelSize: NSSize, screens: [ScreenFrame]) -> Bool {
        let frame = NSRect(origin: origin, size: panelSize)
        guard isFinite(frame) else { return false }
        return screens.contains { isFinite($0.visibleFrame) && $0.visibleFrame.contains(frame) }
    }

    static func isFinite(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
    }

    /// 返回面板 origin（左下角，AppKit 坐标）；无法安全显示时返回 nil。
    public static func origin(anchor: NSRect, panelSize: NSSize, screens: [ScreenFrame]) -> NSPoint? {
        // 注意：NSRect 的 .width/.height/.minX 是规范化值（负尺寸会被展示层翻转），
        // 负尺寸必须检查原始 size 字段。
        guard isFinite(anchor), anchor.size.width >= 0, anchor.size.height >= 0,
              anchor.size.width.isFinite, anchor.size.height.isFinite,
              isFinite(NSRect(origin: .zero, size: panelSize)),
              panelSize.width > 0, panelSize.height > 0,
              anchor != .zero else { return nil }
        // 完全不在任何屏幕内的锚点不得显示（无「任意屏幕」回退）。
        guard let screen = screens.first(where: { isFinite($0.frame) && $0.frame.intersects(anchor) }) else { return nil }
        let visible = screen.visibleFrame
        guard isFinite(visible), visible.width >= panelSize.width, visible.height >= panelSize.height else { return nil }

        let maxX = max(visible.minX + margin, visible.maxX - margin - panelSize.width)
        let x = min(max(anchor.minX, visible.minX + margin), maxX)
        // 默认插入点右下；下方放不下时上翻（锚点上方 + margin）。
        let fitsBelow = anchor.minY - panelSize.height - margin >= visible.minY
        let y: CGFloat
        if fitsBelow {
            y = anchor.minY - panelSize.height - margin
        } else {
            // 上翻；若上翻后超出屏幕顶部，回推到顶部内边界。
            y = min(anchor.maxY + margin, visible.maxY - margin - panelSize.height)
        }
        return NSPoint(x: x, y: max(visible.minY + margin, min(y, visible.maxY - margin - panelSize.height)))
    }
}
