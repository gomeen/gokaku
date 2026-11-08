import Foundation

public enum PreeditCaret {
    /// 核心的 UTF-8 字节偏移转为 AppKit 的 UTF-16 偏移；越界裁到末尾，半个标量裁到其前。
    public static func utf16Offset(in text: String, utf8Offset: Int) -> Int {
        let limit = max(0, min(utf8Offset, text.utf8.count))
        var bytes = 0, units = 0
        for scalar in text.unicodeScalars {
            let length = scalar.utf8.count
            if bytes + length > limit { break }
            bytes += length
            units += scalar.utf16.count
        }
        return units
    }
}
