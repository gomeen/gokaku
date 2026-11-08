import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GogakuKit

/// 目录选择和编辑副本分离；只有写入成功才改变正在使用的主题。
struct SkinPage: View {
    @Binding var settings: GogakuKit.Settings
    @ObservedObject var editor: SkinEditorSession
    @State private var selected: CandidateThemeID = .gogaku
    @State private var dark = false
    @State private var busy = false
    @State private var failure: String?
    @Environment(\.colorScheme) private var colorScheme

    private var themes: [CandidateTheme] { BuiltinCandidateThemes.all + settings.userCandidateThemes }
    private var theme: CandidateTheme { themes.first(where: { $0.id == selected }) ?? BuiltinCandidateThemes.theme(.gogaku) }
    private var builtin: Bool { BuiltinCandidateThemes.all.contains { $0.id == selected } }

    var body: some View {
        Group {
            if editor.draft != nil { editorPage } else { catalog }
        }
        .font(.system(size: 14))
        .buttonStyle(SkinButtonStyle())
        .onAppear {
            let id = settings.resolvedCandidateTheme.id
            selected = id == .rimeMacOSLike ? .gogaku : id
            dark = colorScheme == .dark
        }
        .onChange(of: editor.draft?.id) { _, _ in failure = nil }
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                pageTitle("皮肤")
                Spacer()
                Button("导入主题…", action: importTheme)
                Button("＋ 新建主题") { editor.begin(theme, copy: true, new: true); dark = false }
                    .buttonStyle(SkinButtonStyle(prominent: true))
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("主题列表").font(.headline)
                    ScrollView {
                        VStack(spacing: 7) {
                            ForEach(themes, id: \.id) { item in themeRow(item) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollIndicators(.never).frame(height: min(465, CGFloat(themes.count) * 61 - 7))
                    HStack(spacing: 8) {
                        Button("应用主题", action: apply).buttonStyle(SkinButtonStyle(prominent: true))
                        Button(builtin ? "复制并编辑" : "编辑") { editor.begin(theme, copy: builtin); dark = false }
                        Button("删除", action: deleteTheme).disabled(builtin)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                previewColumn(theme)
            }.frame(maxHeight: .infinity, alignment: .top)
            errorMessage
        }.disabled(busy || editor.saving)
    }

    private func themeRow(_ item: CandidateTheme) -> some View {
        let p = item.palette(darkAppearance: dark)
        return Button { selected = item.id } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(stops: [.init(color: skinColor(p.background), location: 0.5), .init(color: skinColor(p.highlight), location: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).fontWeight(.semibold).lineLimit(1)
                    Text((BuiltinCandidateThemes.all.contains { $0.id == item.id } ? "内置" : "自定义") + " · " + (item.dark == nil ? "单色" : "浅深双色")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if settings.candidateTheme == item.id { Text("当前使用").font(.caption).foregroundStyle(SettingsPalette.accent) }
            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected == item.id ? SettingsPalette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected == item.id ? SettingsPalette.accent : SettingsPalette.border))
        }.buttonStyle(.plain).accessibilityLabel(item.name + (settings.candidateTheme == item.id ? "，当前使用" : ""))
    }

    private var editorPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button("‹ 返回皮肤") {
                guard editor.mayLeave() else { return }
                editor.discard(); failure = nil
            }.buttonStyle(.plain).foregroundStyle(SettingsPalette.accent).padding(.bottom, 14)
            HStack(spacing: 12) {
                pageTitle("编辑主题")
                Spacer()
                Button("导出主题…") { if let draft = editor.draft { exportTheme(draft) } }
                Button("保存主题", action: saveDraft).disabled(!(editor.draft?.isValid ?? false))
                    .buttonStyle(SkinButtonStyle(prominent: true))
                    .keyboardShortcut("s", modifiers: .command)
            }
            Text(editor.draft?.dark == nil ? "单色 · 浅深外观共用配色" : "双色 · 跟随系统外观")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            errorMessage
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        editorSection("主题与字体") {
                            labeled("主题名称") { TextField("主题名称", text: nameBinding).labelsHidden().accessibilityLabel("主题名称") }
                            labeled("中文字体") { TextField("字体家族", text: fontBinding(\.fontCN)).accessibilityLabel("中文字体") }
                            labeled("英文字体") { TextField("字体家族", text: fontBinding(\.fontEN)).accessibilityLabel("英文字体") }
                            sizeSlider("候选字号", key: \.fontSize, range: 12...24, unit: " px")
                            sizeSlider("序号字号", key: \.indexSize, range: 8...20, unit: " px")
                        }
                        Divider()
                        editorSection("形状与间距") {
                            visualSlider("圆角", key: \.radius, range: 0...20, unit: " px")
                            visualSlider("内边距", key: \.padding, range: 0...20, unit: " px")
                            visualSlider("行高比例", key: \.rowHeight, range: 80...140)
                        }
                        Divider()
                        editorSection("背景与透明度") {
                            visualSlider("窗口不透明度", key: \.opacity, range: 40...100)
                            visualSlider("背景色不透明度", key: \.bgOpacity, range: 0...100)
                            visualSlider("背景图不透明度", key: \.imageOpacity, range: 0...100)
                            labeled("背景图片") {
                                HStack(spacing: 6) {
                                    Button(editor.draft?.palette(darkAppearance: dark).imageData == nil ? "选择图片" : "更换图片", action: chooseImage)
                                    Button("移除") { updatePalette { $0.imageData = nil } }
                                        .disabled(editor.draft?.palette(darkAppearance: dark).imageData == nil)
                                }.controlSize(.small)
                            }
                        }
                        Divider()
                        editorSection("颜色") {
                            ForEach(colorFields, id: \.0) { name, key in
                                labeled(name) {
                                    ColorPicker(name, selection: colorBinding(key), supportsOpacity: false)
                                        .labelsHidden().accessibilityLabel(name)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                            }
                        }
                        if let draft = editor.draft {
                            let p = draft.palette(darkAppearance: dark)
                            if let warning = contrastWarning(p) { Text(warning).font(.caption).foregroundStyle(.orange).accessibilityLabel(warning) }
                        }
                    }.padding(.trailing, 16).frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.never).frame(maxWidth: .infinity)
                Divider()
                if let draft = editor.draft { previewColumn(draft, editing: true) }
            }.frame(maxHeight: .infinity, alignment: .top).padding(.top, 18)
        }.disabled(busy || editor.saving)
    }

    private func previewColumn(_ value: CandidateTheme, editing: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("候选窗预览").font(.headline).padding(.bottom, editing ? 8 : 14)
            if editing {
                HStack(alignment: .center, spacing: 6) {
                    appearanceTabs
                    Spacer(minLength: 0)
                    Button(value.dark == nil ? "添加深色配色" : "改为单色…", action: toggleDark)
                }
            } else {
                HStack(spacing: 8) {
                    simulationButton("模拟浅色", value: false)
                    simulationButton("模拟深色", value: true)
                }
            }
            // 只有配置列滚动。较小窗口或极端字号时预览有自己的滚动空间，不挤压页脚。
            ScrollView {
                SkinPreview(theme: value, dark: dark)
                    .frame(width: 240)
                    .padding(.horizontal, 4).padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
            }.scrollIndicators(.never).padding(.top, 24)
        }.frame(width: editing ? 293 : 270).frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private func simulationButton(_ title: String, value: Bool) -> some View {
        if dark == value {
            Button(title) { dark = value }.buttonStyle(SkinButtonStyle(prominent: true))
        } else {
            Button(title) { dark = value }
        }
    }

    private func pageTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 23, weight: .bold))
            .foregroundStyle(SettingsPalette.primaryText).accessibilityAddTraits(.isHeader)
    }

    private var appearanceTabs: some View {
        HStack(spacing: 6) {
            appearanceTab("浅色", value: false)
            appearanceTab("深色", value: true)
        }
    }
    private func appearanceTab(_ title: String, value: Bool) -> some View {
        Button { dark = value } label: {
            Text(title).fontWeight(dark == value ? .semibold : .regular)
                .foregroundStyle(dark == value ? SettingsPalette.accent : SettingsPalette.secondaryText)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .overlay(alignment: .bottom) { if dark == value { Rectangle().fill(SettingsPalette.accent).frame(height: 2) } }
        }.buttonStyle(.plain).accessibilityLabel("编辑配色：" + title)
            .accessibilityAddTraits(dark == value ? .isSelected : [])
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { _ in
                dark.toggle()
                return .handled
            }
    }

    @ViewBuilder private var errorMessage: some View {
        if let failure { Text(failure).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
    }
    private func editorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { Text(title).font(.headline).padding(.bottom, 10); content() }
    }
    private func labeled<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            control().frame(width: 160)
        }.frame(minHeight: 42)
    }
    private var nameBinding: Binding<String> {
        Binding(get: { editor.draft?.name ?? "" }, set: { editor.draft?.name = $0 })
    }
    private func fontBinding(_ key: WritableKeyPath<CandidateThemeTypography, String>) -> Binding<String> {
        Binding(get: { editor.draft?.typography[keyPath: key] ?? "system-ui" }, set: { editor.draft?.typography[keyPath: key] = $0 })
    }
    // 两个字号由浅深配色共用。
    private func sizeSlider(_ label: String, key: WritableKeyPath<CandidateThemeTypography, Double>, range: ClosedRange<Double>, unit: String) -> some View {
        let binding = Binding(get: { editor.draft?.typography[keyPath: key] ?? range.lowerBound }, set: { editor.draft?.typography[keyPath: key] = $0 })
        return slider(label, value: binding, range: range, unit: unit)
    }
    private func visualSlider(_ label: String, key: WritableKeyPath<CandidateThemeVisual, Double>, range: ClosedRange<Double>, unit: String = "%") -> some View {
        let binding = Binding(get: { editor.draft?.palette(darkAppearance: dark).visual[keyPath: key] ?? range.lowerBound }, set: { value in updatePalette { $0.visual[keyPath: key] = value } })
        return slider(label, value: binding, range: range, unit: unit)
    }
    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        labeled(label) {
            HStack(spacing: 5) {
                Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), in: range).accessibilityLabel(label)
                Text("\(Int(value.wrappedValue))\(unit)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
            }
        }
    }

    private var colorFields: [(String, WritableKeyPath<CandidatePalette, ThemeColor>)] {
        [("背景", \.background), ("边框", \.border), ("候选文字", \.text), ("翻译文字", \.comment),
         ("序号", \.index), ("高亮背景", \.highlight), ("高亮文字", \.highlightText),
         ("选中时翻译文字", \.highlightComment), ("输入与光标", \.cursor), ("页码", \.page)]
    }
    private func updatePalette(_ update: (inout CandidatePalette) -> Void) {
        guard var draft = editor.draft else { return }
        if dark, var p = draft.dark { update(&p); draft.dark = p }
        else { update(&draft.light) }
        editor.draft = draft
    }
    private func colorBinding(_ key: WritableKeyPath<CandidatePalette, ThemeColor>) -> Binding<Color> {
        Binding(get: { skinColor(editor.draft?.palette(darkAppearance: dark)[keyPath: key] ?? ThemeColor(rgb: 0)!) }, set: { value in
            guard let c = NSColor(value).usingColorSpace(.sRGB) else { return }
            let rgb = (UInt32((c.redComponent * 255).rounded()) << 16) | (UInt32((c.greenComponent * 255).rounded()) << 8) | UInt32((c.blueComponent * 255).rounded())
            guard let color = ThemeColor(rgb: rgb) else { return }
            updatePalette { $0[keyPath: key] = color }
        })
    }
    private func toggleDark() {
        guard var draft = editor.draft else { return }
        if draft.dark == nil { draft.dark = draft.light; dark = true }
        else {
            guard confirm("改为单色？", detail: "保留当前配色，移除另一套。", action: "改为单色") else { return }
            draft.light = draft.palette(darkAppearance: dark); draft.dark = nil; dark = false
        }
        editor.draft = draft
    }
    private func confirm(_ title: String, detail: String = "", action: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }
    private func persist(_ next: GogakuKit.Settings, success: @escaping () -> Void) {
        busy = true; editor.saving = true; failure = nil
        SettingsStore.shared.submit(next) { outcome in
            busy = false; editor.saving = false
            switch outcome {
            case .success: settings = Settings.load(); success()
            case .failure(let message): SettingsStore.shared.discardPending(next); failure = message
            }
        }
    }
    private func apply() {
        var next = settings; next.candidateTheme = selected
        persist(next) {}
    }
    private func saveDraft() {
        guard var draft = editor.draft, draft.isValid else { return }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = settings
        if let i = next.userCandidateThemes.firstIndex(where: { $0.id == draft.id }) { next.userCandidateThemes[i] = draft }
        else { next.userCandidateThemes.append(draft) }
        persist(next) { selected = draft.id; editor.discard() }
    }
    private func deleteTheme() {
        guard !builtin, confirm("删除“\(theme.name)”？", action: "删除") else { return }
        var next = settings
        next.userCandidateThemes.removeAll { $0.id == selected }
        if next.candidateTheme == selected { next.candidateTheme = .gogaku }
        persist(next) { selected = next.candidateTheme == .rimeMacOSLike ? .gogaku : next.candidateTheme }
    }

    /// 包和图片的读取、校验在后台执行；UI 只接受完整校验后的结果。
    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .webP]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        assetOperation {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8 * 1024 * 1024 else { throw SkinFileError("图片文件超过 8 MiB") }
            return try CandidateThemePackage.validatedImage(Data(contentsOf: url))
        } success: { data in updatePalette { $0.imageData = data } }
    }
    private func importTheme() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "gogakutheme") ?? .data]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        assetOperation { try CandidateThemePackage.read(from: url) } success: { imported in
            editor.begin(imported, copy: true)
            editor.draft?.name = imported.name
            dark = false
        }
    }
    private func exportTheme(_ value: CandidateTheme) {
        guard value.isValid else { failure = "请先填写有效的主题名称和字体。"; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "gogakutheme") ?? .data]; panel.nameFieldStringValue = value.name + ".gogakutheme"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        assetOperation { try CandidateThemePackage.write(value, to: url) } success: { _ in }
    }
    private func assetOperation<T>(_ work: @escaping () throws -> T, success: @escaping (T) -> Void) {
        busy = true; editor.saving = true; failure = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                busy = false; editor.saving = false
                switch result {
                case .success(let value): success(value)
                case .failure(let error): failure = error.localizedDescription
                }
            }
        }
    }
}

private struct SkinButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundStyle(prominent ? SettingsPalette.accentForeground : SettingsPalette.primaryText)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(prominent ? SettingsPalette.accent : SettingsPalette.cardBackground, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(prominent ? SettingsPalette.accent : SettingsPalette.border))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct SkinFileError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func skinColor(_ value: ThemeColor) -> Color {
    let rgb = value.rgb
    return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
}

private func contrastWarning(_ p: CandidatePalette) -> String? {
    func luminance(_ rgb: UInt32) -> Double {
        let c = [16, 8, 0].map { shift -> Double in
            let x = Double((rgb >> shift) & 255) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722
    }
    func ratio(_ a: ThemeColor, _ b: ThemeColor) -> Double {
        let x = luminance(a.rgb), y = luminance(b.rgb)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    var messages: [String] = []
    let value = ratio(p.text, p.background)
    if value < 4.5 {
        messages.append(String(format: "候选文字与纯色背景对比度 %.2f:1，低于 4.5:1。", value))
    }
    if p.imageData != nil || p.visual.opacity < 100 || p.visual.bgOpacity < 100 {
        messages.append("透明度或背景图会影响实际对比，请检查可读性。")
    }
    return messages.isEmpty ? nil : messages.joined(separator: " ")
}

private struct SkinPreview: View {
    let theme: CandidateTheme
    let dark: Bool
    private let words = [("你好", "int. hello"), ("拟好", "v. draft"), ("你号", "n. number"), ("你好呀", "hello"), ("您好", "hello"), ("hello", "你好"), ("拟耗", "v. plan"), ("你好吗", "how are you"), ("倪浩", "name")]
    private var p: CandidatePalette { theme.palette(darkAppearance: dark) }
    private func font(_ name: String, size: Double) -> Font {
        guard name != "system-ui", let actual = NSFont(name: name, size: size) ?? NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) else { return .system(size: size) }
        return Font(actual)
    }
    var body: some View {
        let type = theme.typography
        VStack(alignment: .leading, spacing: 0) {
            Text("ni'hao ▏").font(font(type.fontEN, size: 13))
                .foregroundStyle(skinColor(p.cursor)).padding(.horizontal, 5).padding(.vertical, 4)
            ForEach(words.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(font(type.fontEN, size: type.indexSize))
                        .foregroundStyle(skinColor(i == 0 ? p.highlightComment : p.index))
                    Text(words[i].0).font(font(i == 5 ? type.fontEN : type.fontCN, size: type.fontSize))
                        .foregroundStyle(skinColor(i == 0 ? p.highlightText : p.text)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(words[i].1).font(font(type.fontEN, size: type.fontSize - 2))
                        .foregroundStyle(skinColor(i == 0 ? p.highlightComment : p.comment)).lineLimit(1)
                }.padding(.horizontal, 5).frame(minHeight: 30 * p.visual.rowHeight / 100)
                    .background(i == 0 ? skinColor(p.highlight) : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
            Text("1/4").font(font(type.fontEN, size: 11)).foregroundStyle(skinColor(p.page))
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 5).padding(.vertical, 3)
        }
        .padding(p.visual.padding)
        .background {
            ZStack {
                skinColor(p.background).opacity(p.visual.bgOpacity / 100)
                if let data = p.imageData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill().opacity(p.visual.imageOpacity / 100)
                }
            }.clipShape(RoundedRectangle(cornerRadius: p.visual.radius))
        }
        .overlay(RoundedRectangle(cornerRadius: p.visual.radius).stroke(skinColor(p.border)))
        .clipShape(RoundedRectangle(cornerRadius: p.visual.radius))
        .opacity(p.visual.opacity / 100)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("九条候选预览")
    }
}
