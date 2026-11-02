import SwiftUI
import GogakuCore

/// 设置页共用样式（2026-11-03 定稿，对应 prototypes/settings-final.html 已选视觉）：
/// 青绿强调色（浅 #12996a／深 #34c48c）、平面卡片分组、左标签右控件行、
/// 固定底部状态栏。间距、字号、行高以原型为准；不嵌入 HTML。
enum SettingsPalette {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 52 / 255.0, green: 196 / 255.0, blue: 140 / 255.0, alpha: 1)
            : NSColor(srgbRed: 18 / 255.0, green: 153 / 255.0, blue: 106 / 255.0, alpha: 1)
    })
    static let accentText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 90 / 255.0, green: 217 / 255.0, blue: 164 / 255.0, alpha: 1)
            : NSColor(srgbRed: 13 / 255.0, green: 122 / 255.0, blue: 83 / 255.0, alpha: 1)
    })
    static let accentSoft = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 52 / 255.0, green: 196 / 255.0, blue: 140 / 255.0, alpha: 0.16)
            : NSColor(srgbRed: 18 / 255.0, green: 153 / 255.0, blue: 106 / 255.0, alpha: 0.12)
    })
    static let cardCornerRadius: CGFloat = 8
}

/// 平面分组卡片（标题＋内容）。
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            content
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: SettingsPalette.cardCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: SettingsPalette.cardCornerRadius)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

/// 左标签（含可选说明）右控件的设置行。
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String = ""
    let control: Control
    init(_ title: String, detail: String = "", @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.vertical, 9)
    }
}

/// 搜索框。
struct SettingsSearchField: View {
    @Binding var text: String
    let placeholder: String
    var accessibilityName: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityName)
    }
}

/// 底部状态栏状态。
enum SaveStatus: Equatable {
    case idle
    case saving
    case saved
    case failed(String)

    init(storeStatus: GogakuCore.SettingsStore.Status) {
        switch storeStatus {
        case .idle: self = .idle
        case .saving: self = .saving
        case .saved: self = .saved
        case .failed(let reason): self = .failed(reason)
        }
    }

    var text: String {
        switch self {
        case .idle: return ""
        case .saving: return "正在保存…"
        case .saved: return "已保存"
        case .failed: return "保存失败：目录不可写或权限不足。改动已保留，可重试。"
        }
    }

    var tone: NSColor {
        switch self {
        case .idle: return .systemGray
        case .saving: return .systemOrange
        case .saved: return .systemGreen
        case .failed: return .systemRed
        }
    }
}
