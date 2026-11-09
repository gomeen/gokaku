import AppKit

/// 候选窗无锚点回退（2026-11 企业微信兼容，用户裁决：普通模式必须始终有
/// 候选窗）。背景：round-build6 裁决「缺可信定位就隐藏、保留组合」在某类
/// 宿主上产生「整词无候选窗」——词首 pre-read 是全组合唯一的锚点机会，
/// 企业微信等宿主对插入点的矩形查询随段落增长／中文提交后开始返回无效值，
/// 且组合期间不恢复（同 Orca 的组合期零矩形行为），一次失败即整词隐藏，
/// 而组合与空格上屏不受影响（用户观察：无弹框但输入正常）。
/// 回退顺序：词首 pre-read（有效时原样）＞ 同一输入框上一组合的显示锚点
/// （连续输入光标只前进几个字，位置偏差最小）＞ 鼠标位置光标矩形（与切换
/// 提示同一兜底语义）。组合中读到真实矩形后由既有位置复查与瞬移过滤器
/// （AnchorPlausibility）接管纠正。
public enum AnchorFallback {
    /// - Parameters:
    ///   - preRead: 词首宿主矩形（无效时为 .zero）
    ///   - carried: 上一组合的显示锚点（nil＝本会话尚无）
    ///   - mouseCaret: 鼠标位置光标矩形（nil＝不提供）
    /// - Returns: 本组合的显示锚点；nil＝维持隐藏（无处可显）。
    public static func resolve(preRead: NSRect, carried: NSRect?, mouseCaret: NSRect?) -> NSRect? {
        if preRead != NSRect.zero { return preRead }
        if let carried, carried != NSRect.zero { return carried }
        return mouseCaret
    }
}
