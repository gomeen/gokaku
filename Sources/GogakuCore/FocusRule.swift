import Foundation

/// 宿主身份与定位几何分别判断。空闲时允许重锚；组合中才校验原字段证据。
public enum FocusRule {
    public static let noMarkedRange = NSRange(location: NSNotFound, length: 0)

    public static func isSameField(
        application: String, pid: Int32, selection: NSRange, markedRange: NSRange,
        composing: Bool,
        anchorApplication: String, anchorPid: Int32, anchor: NSRange,
        expectsMarkedText: Bool = true
    ) -> Bool {
        guard application == anchorApplication, pid == anchorPid else { return false }
        guard composing else { return true }
        // 暂时读不到选区不等于换框；IMK 生命周期、鼠标事件与安全输入仍使组合失效。
        guard selection.location != NSNotFound, selection.length != NSNotFound else { return true }
        if expectsMarkedText {
            return markedRange.location != NSNotFound && markedRange.length > 0
                && (anchor.location == NSNotFound || markedRange.location == anchor.location)
        }
        // 关闭输入区字母时宿主不应持有 marked text；光标必须仍在组合锚点。
        return anchor.location == NSNotFound || selection == anchor
    }
}
