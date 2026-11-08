import AppKit
import Combine
import GogakuKit

/// 仅承载未提交的副本；持久化成功前不会改变 Settings。
final class SkinEditorSession: ObservableObject {
    @Published var draft: CandidateTheme?
    @Published var original: CandidateTheme?
    @Published var isNew = false
    @Published var saving = false

    var dirty: Bool { draft != nil && (isNew || draft != original) }

    func begin(_ theme: CandidateTheme, copy: Bool, new: Bool = false) {
        let value = copy ? CandidateTheme(id: CandidateThemeID(rawValue: UUID().uuidString)!,
                                          name: new ? "新主题" : theme.name + " 副本",
                                          light: theme.light, dark: new ? nil : theme.dark,
                                          typography: theme.typography) : theme
        draft = value
        original = value
        isNew = copy
    }

    func discard() { draft = nil; original = nil; isNew = false }

    /// 切页、返回、关闭及退出共用同一门禁；保存期间不允许销毁草稿。
    func mayLeave() -> Bool {
        guard !saving else { return false }
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "主题尚未保存"
        alert.informativeText = "放弃未保存的修改？"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃修改")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
