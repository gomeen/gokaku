import Foundation

/// 同一组合内候选窗锚点的可信度判定（2026-11-03）。
///
/// 背景：用户报告在 Orca 打字时候选窗位置正确，随后无规律瞬移到无关位置。
/// Orca（Electron/Chromium）在布局抖动／选择索引闪断时会短暂回报「非零但
/// 错误」的插入点矩形（控件原点、缓冲区首行等）；零矩形冻结保护拦不住它，
/// 面板随即被瞬移。
///
/// 判定按轴向建模（打字的光标轨迹有结构，瞬移没有）：
/// - 组合刚开始（无上次有效锚点）→ 采纳：起点必须信任宿主，否则无处起显。
/// - 纵向 ±一个行高内且 ≈0（同一行）→ 横向只允许打字方向与小幅回退
///   （拼音增减字母）；同行大幅向左跳到行首／原点是选择闪断的特征 → 可疑。
/// - 纵向 ≈ 一个行高（相邻行）→ 横向任意：换行回到下一行行首是正常路径，
///   dx 可以合法地大跳；终端逐行滚动也在这一档。
/// - 纵向超过一个行高（跨多行跳变）→ 可疑：打字只会换一行，滚动逐行。
/// - 可疑 → 冻结在原锚点（不更新、不重排）；连续 escapeAfter 拍仍报新
///   位置才接受——窗口真实拖动／滚动到远处的逃生门（真实移动持续稳定，
///   瞬时误报一两拍内消失，永远到不了逃生门）。
public enum AnchorPlausibility {
    /// 同行内允许的最大向左回退（pt）：拼音删字母时插入点小幅左移。
    public static let backstepLimit: CGFloat = 100
    /// 连续可疑达到该次数后接受新锚点（真实移动的逃生门）。100ms 复查＋逐键
    /// 刷新下，约 0.3–0.8 秒的持续新位置才会触发。
    public static let escapeAfter = 8

    public enum Decision: Equatable {
        /// 采纳新锚点，清零可疑计数。
        case accept
        /// 冻结在原锚点：不更新锚点、不重排面板；可疑计数 +1。
        case freeze
        /// 连续可疑到限：接受新锚点（视为真实移动），清零计数。
        case escapeAccept
    }

    public static func classify(previous: NSRect?, next: NSRect, suspectStreak: Int) -> Decision {
        guard let previous else { return .accept }
        let line = max(previous.height, next.height, 12)
        let dy = next.midY - previous.midY
        if abs(dy) <= line * 0.25 {
            // 同一行：横向只认打字方向与小幅回退。
            if next.minX - previous.minX >= -backstepLimit { return .accept }
        } else if abs(dy) <= line + 8 {
            // 相邻行：换行回行首 dx 任意；逐行滚动也在这一档。
            return .accept
        } else {
            // 跨多行跳变：打字不产生。
        }
        return suspectStreak + 1 >= escapeAfter ? .escapeAccept : .freeze
    }
}
