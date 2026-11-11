import AppKit

/// 模式切换提示浮层（「中／英」「学习·中→英」「普通」等）的锚点解析
/// （2026-11-11，用户裁决：与候选窗同一套位置逻辑）。
///
/// 背景：候选窗定位修好之后，Orca 终端里的切换提示照样会甩到屏幕左上角或
/// 别的位置。原因同候选窗那次：该宿主在**无组合**时按选区读到的矩形不可信
/// （pi 启动前 shell 行的位置、甚至屏幕外的坐标），而组合期间才有的索引 0
/// 读数在这里不可用（Host.m 按契约只对组合期做索引 0 回退，无组合时索引 0
/// 在相邻字符格间循环）。提示恰好总在无组合时触发（Shift 单击切中英、
/// ⌃⇧M／⌃⇧J 切模式），于是把坏读数当成了光标——几何层再把它钳进屏幕，
/// 就成了「提示跑到屏幕左上角」。
///
/// 与候选窗首键（`applyNormal` 里 `displayRect == nil` 那一支）逐条对齐：
/// 1. 组合中的显示锚点（`displayRect`）已在调用方优先使用——它过了瞬移过滤器
///    与无锚点回退，最可信。
/// 2. 首键 pre-read 与面板同源（宿主按选区读到的矩形）且同一条有效性规则：
///    必须落在某块屏幕的可视区内。面板遇到屏幕外锚点时 `PanelPlacement`
///    返回 nil、干脆不显示；提示必须显示，于是把这种读数当作「没有读数」。
/// 3. 无锚点回退与 `AnchorFallback` 同序：pre-read ＞ 同一输入框上一组合的
///    显示锚点（换字段／失焦即清空）＞ 鼠标位置。
/// 4. pre-read 与上一组合锚点相差超过可解释范围（跨多行跳变）时，按
///    `AnchorPlausibility` 判为陈旧／误报并保留上一锚点——提示只活 1 秒，
///    等不到面板那套连续 3–8 拍的逃生门。
public enum ToastAnchor {
    /// - Parameters:
    ///   - preRead: 本次宿主读取的光标矩形（无效时为 .zero；与候选窗首键同源）
    ///   - carried: 同一输入框上一组合的显示锚点（nil＝本字段尚无）
    ///   - mouseCaret: 鼠标位置光标矩形（nil＝不提供）
    ///   - screens: 当前屏幕几何（与候选窗同一份 ScreenFrame 列表）
    /// - Returns: 提示浮层的锚点；nil＝不显示（调用方无处可放）。
    public static func resolve(preRead: NSRect, carried: NSRect?,
                               mouseCaret: NSRect?, screens: [ScreenFrame]) -> NSRect? {
        let preReadUsable = isOnScreen(preRead, screens)
        let carriedUsable = carried.flatMap { isOnScreen($0, screens) ? $0 : nil }
        if let carried = carriedUsable {
            // 与上一组合锚点相容（同行或相邻行）＝本次读数可信且更精确。
            if preReadUsable,
               AnchorPlausibility.classify(previous: carried, next: preRead, suspectStreak: 0) != .freeze {
                return preRead
            }
            return carried
        }
        if preReadUsable { return preRead }
        return mouseCaret
    }

    /// 屏幕外／非有限／负尺寸的读数不可用（零宽矩形合法，零矩形不行）。
    static func isOnScreen(_ rect: NSRect, _ screens: [ScreenFrame]) -> Bool {
        guard rect != .zero,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width >= 0, rect.size.height >= 0 else { return false }
        return screens.contains { frame in
            frame.visibleFrame.origin.x.isFinite && frame.visibleFrame.origin.y.isFinite
                && frame.visibleFrame.intersects(rect)
        }
    }
}
