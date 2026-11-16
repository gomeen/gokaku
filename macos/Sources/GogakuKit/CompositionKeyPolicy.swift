import Foundation

/// 组合期间按键归属（2026-11-13 用户事故后的合同）。
///
/// 事故：候选窗显示时按退格，删掉的是**之前已提交的正文**。真因有两条：
/// ① 宿主瞬时读不到应用身份时输入法把按键漏给宿主；② 前向删除
/// （keyCode 117）未映射，走「先上屏原编码再交还宿主」分支——宿主随即把
/// 刚上屏的字删掉。
///
/// 合同：**组合存在时，破坏性按键由输入法拥有**，永远不交给宿主。
/// 这是唯一实现，`InputController` 的两条路径都调用它。
public enum CompositionKeyPolicy {
    /// 退格（删前一个字）与前向删除（删后一个字）。
    public static let destructiveKeyCodes: Set<UInt16> = [51, 117]

    public static func isDestructive(_ keyCode: UInt16) -> Bool {
        destructiveKeyCodes.contains(keyCode)
    }

    /// 组合中遇到该键时是否必须由输入法吞掉（不交还宿主）。
    public static func keepsKeyOwned(keyCode: UInt16, composing: Bool) -> Bool {
        composing && isDestructive(keyCode)
    }
}
