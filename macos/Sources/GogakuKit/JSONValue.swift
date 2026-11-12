import Foundation

/// 原样保存的 JSON 值。
///
/// 内置主题的覆盖补丁是相对出厂数据的 JSON Merge Patch（RFC 7386），规则
/// 只有共享核心一份实现（`gc_themes_effective` / `gc_theme_override_make`）。
/// Swift 侧只负责把它存进 `settings.json` 并原样传回去，不解构补丁语义。
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        // 顺序即类型判定顺序：Bool 必须早于数值（JSONDecoder 对两者区分严格）。
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "不支持的 JSON 值")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            // 整数值按整数写回：颜色等字段在 settings.json 里要保持 1218922，
            // 不能变成 1218922.0000001 之类的浮点写法。
            if value.rounded() == value, abs(value) <= 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    /// 对象值；补丁的顶层一定是对象，其余情况返回 nil。
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// 传给共享核心的 JSON 文本；字典键排序，便于缓存与比较。
    public var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}
