import Foundation
import CGogakuCore

/// 一种不透明 sRGB 色值；解码时拒绝超出 24 位的数值。
public struct ThemeColor: Codable, Equatable, Sendable {
    public let rgb: UInt32
    public init?(rgb: UInt32) {
        guard rgb <= 0xFFFFFF else { return nil }
        self.rgb = rgb
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(UInt32.self)
        guard let color = Self(rgb: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a 24-bit sRGB color")
        }
        self = color
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rgb)
    }
}

/// 字体名称使用 PostScript 名称或字体家族名；system-ui 表示系统字体。
public struct CandidateThemeTypography: Codable, Equatable, Sendable {
    public var fontCN: String
    public var fontEN: String
    public var fontSize: Double
    public var indexSize: Double

    public init(fontCN: String = "system-ui", fontEN: String = "system-ui", fontSize: Double = 14, indexSize: Double = 11) {
        self.fontCN = fontCN; self.fontEN = fontEN; self.fontSize = fontSize; self.indexSize = indexSize
    }
    public var isValid: Bool {
        [fontCN, fontEN].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 128 }
            && fontSize.isFinite && (12...24).contains(fontSize)
            && indexSize.isFinite && (8...20).contains(indexSize)
    }
    private enum CodingKeys: String, CodingKey { case fontCN, fontEN, fontSize, indexSize }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(fontCN: try c.decodeIfPresent(String.self, forKey: .fontCN) ?? "system-ui",
                  fontEN: try c.decodeIfPresent(String.self, forKey: .fontEN) ?? "system-ui",
                  fontSize: try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 14,
                  indexSize: try c.decodeIfPresent(Double.self, forKey: .indexSize) ?? 11)
        guard isValid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid theme typography")) }
    }
    public func encode(to encoder: Encoder) throws {
        guard isValid else { throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Invalid theme typography")) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fontCN, forKey: .fontCN); try c.encode(fontEN, forKey: .fontEN)
        try c.encode(fontSize, forKey: .fontSize); try c.encode(indexSize, forKey: .indexSize)
    }
}

/// rowHeight 与三种 opacity 均为百分比；每套明暗配色独立保存。
public struct CandidateThemeVisual: Codable, Equatable, Sendable {
    public var radius: Double
    public var padding: Double
    public var rowHeight: Double
    public var opacity: Double
    public var bgOpacity: Double
    public var imageOpacity: Double

    public init(radius: Double = 8, padding: Double = 8, rowHeight: Double = 100,
                opacity: Double = 100, bgOpacity: Double = 100, imageOpacity: Double = 25) {
        self.radius = radius; self.padding = padding; self.rowHeight = rowHeight
        self.opacity = opacity; self.bgOpacity = bgOpacity; self.imageOpacity = imageOpacity
    }
    public var isValid: Bool {
        [(radius, 0.0...20.0), (padding, 0.0...20.0), (rowHeight, 80.0...140.0),
         (opacity, 40.0...100.0), (bgOpacity, 0.0...100.0), (imageOpacity, 0.0...100.0)]
            .allSatisfy { $0.0.isFinite && $0.1.contains($0.0) }
    }
    private enum CodingKeys: String, CodingKey { case radius, padding, rowHeight, opacity, bgOpacity, imageOpacity }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(radius: try c.decodeIfPresent(Double.self, forKey: .radius) ?? 8,
                  padding: try c.decodeIfPresent(Double.self, forKey: .padding) ?? 8,
                  rowHeight: try c.decodeIfPresent(Double.self, forKey: .rowHeight) ?? 100,
                  opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 100,
                  bgOpacity: try c.decodeIfPresent(Double.self, forKey: .bgOpacity) ?? 100,
                  imageOpacity: try c.decodeIfPresent(Double.self, forKey: .imageOpacity) ?? 25)
        guard isValid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid theme visual metrics")) }
    }
    public func encode(to encoder: Encoder) throws {
        guard isValid else { throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Invalid theme visual metrics")) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(radius, forKey: .radius); try c.encode(padding, forKey: .padding)
        try c.encode(rowHeight, forKey: .rowHeight); try c.encode(opacity, forKey: .opacity)
        try c.encode(bgOpacity, forKey: .bgOpacity); try c.encode(imageOpacity, forKey: .imageOpacity)
    }
}

public struct CandidatePalette: Codable, Equatable, Sendable {
    public var background, border, text, comment, index, highlight, highlightText, highlightComment, cursor, page: ThemeColor
    public var visual: CandidateThemeVisual = .init()
    public var imageData: Data? = nil

    private enum CodingKeys: String, CodingKey {
        case background, border, text, comment, index, highlight, highlightText, highlightComment, cursor, page, visual, imageData
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        background = try c.decode(ThemeColor.self, forKey: .background)
        border = try c.decode(ThemeColor.self, forKey: .border)
        text = try c.decode(ThemeColor.self, forKey: .text)
        comment = try c.decode(ThemeColor.self, forKey: .comment)
        index = try c.decode(ThemeColor.self, forKey: .index)
        highlight = try c.decode(ThemeColor.self, forKey: .highlight)
        highlightText = try c.decode(ThemeColor.self, forKey: .highlightText)
        highlightComment = try c.decode(ThemeColor.self, forKey: .highlightComment)
        cursor = try c.decode(ThemeColor.self, forKey: .cursor)
        page = try c.decode(ThemeColor.self, forKey: .page)
        visual = try c.decodeIfPresent(CandidateThemeVisual.self, forKey: .visual) ?? .init()
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
    }

    fileprivate init(_ values: [UInt32]) {
        precondition(values.count == 10)
        let c = values.map { ThemeColor(rgb: $0)! }
        (background, border, text, comment, index, highlight, highlightText, highlightComment, cursor, page) =
            (c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9])
    }
}

/// 单色主题 dark 为 nil；双色主题由系统外观选择，不存两份选中状态。
public struct CandidateTheme: Codable, Equatable, Sendable {
    public let id: CandidateThemeID
    public var name: String
    public var light: CandidatePalette
    public var dark: CandidatePalette?
    public var typography: CandidateThemeTypography

    public init(id: CandidateThemeID, name: String, light: CandidatePalette, dark: CandidatePalette?, typography: CandidateThemeTypography = .init()) {
        self.id = id; self.name = name; self.light = light; self.dark = dark; self.typography = typography
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 128
            && typography.isValid && light.visual.isValid && (dark?.visual.isValid ?? true)
    }

    private enum CodingKeys: String, CodingKey { case id, name, light, dark, typography }
    public func encode(to encoder: Encoder) throws {
        guard isValid else { throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Invalid theme")) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(light, forKey: .light)
        try c.encodeIfPresent(dark, forKey: .dark)
        try c.encode(typography, forKey: .typography)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 128 else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "Invalid theme name")
        }
        self.init(id: try c.decode(CandidateThemeID.self, forKey: .id), name: name,
                  light: try c.decode(CandidatePalette.self, forKey: .light),
                  dark: try c.decodeIfPresent(CandidatePalette.self, forKey: .dark),
                  typography: try c.decodeIfPresent(CandidateThemeTypography.self, forKey: .typography) ?? .init())
    }

    public func palette(darkAppearance: Bool) -> CandidatePalette {
        darkAppearance ? (dark ?? light) : light
    }
}

/// 解码单个损坏条目不影响其他主题或设置；保留第一个有效的非内置 ID。
struct LossyCandidateThemes: Decodable {
    let values: [CandidateTheme]
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [CandidateTheme] = []
        var seen = Set(BuiltinCandidateThemes.all.map(\.id) + [.rimeMacOSLike])
        while !container.isAtEnd {
            let item = try container.superDecoder()
            if let theme = try? CandidateTheme(from: item), seen.insert(theme.id).inserted {
                result.append(theme)
            }
        }
        values = result
    }
}

public enum BuiltinCandidateThemes {
    /// 数据源是共享核心的 gc_themes_builtin（shared/GogakuCore/theme_contract.cpp）。
    /// 这里只把规范 JSON 解码成本端类型，不携带调色板数据；锚点色由两端的
    /// theme_contract_test 冻结，改调色板必须改那一份并同步两处向量。
    public static let all: [CandidateTheme] = {
        var buffer: UnsafeMutablePointer<CChar>?
        var length = 0
        let code = gc_themes_builtin(&buffer, &length)
        guard code == 0, let output = buffer else {
            fatalError("内置主题契约不可用（gc_themes_builtin 返回 \(code)）")
        }
        defer { gc_contract_free(output) }
        let data = Data(bytes: output, count: length)
        guard let themes = try? JSONDecoder().decode([CandidateTheme].self, from: data),
              themes.count == 4 else {
            fatalError("内置主题契约输出无法解码为本端主题类型")
        }
        return themes
    }()

    public static func theme(_ id: CandidateThemeID) -> CandidateTheme {
        if id == .rimeMacOSLike {
            let value = all[0]
            return CandidateTheme(id: .rimeMacOSLike, name: value.name, light: value.light, dark: value.dark)
        }
        return all.first(where: { $0.id == id }) ?? theme(.rimeMacOSLike)
    }
}
