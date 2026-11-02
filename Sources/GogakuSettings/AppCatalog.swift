import AppKit
import GogakuCore

/// 系统应用目录：后台索引 /Applications、/System/Applications、~/Applications，
/// 按 bundle ID 去重，使用系统提供的名称与图标；支持文件选择器添加任意位置的 .app。
@MainActor
final class AppCatalog: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: String          // bundle ID
        let name: String
        let path: String
        var icon: NSImage?

        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
    }

    /// 旧配置中已卸载或无法解析的应用：保留记录，显示通用图标。
    struct UnknownEntry: Identifiable, Equatable {
        let id: String
        var name: String { displayName.isEmpty ? id : displayName }
        let displayName: String
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var indexing = false

    private nonisolated static let roots = [
        "/Applications",
        "/System/Applications",
        NSString(string: "~/Applications").expandingTildeInPath,
    ]

    init() {
        indexInBackground()
    }

    nonisolated private func indexInBackground() {
        let roots = Self.roots
        Task.detached(priority: .utility) { [weak self] in
            var paths: [String] = []
            for root in roots {
                let urls = (try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isApplicationKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
                paths.append(contentsOf: urls.map(\.path))
            }
            // 索引列表按名称排序，添加弹层稳定可扫读。
            let apps = paths.sorted().compactMap { path -> Entry? in
                let url = URL(fileURLWithPath: path)
                guard path.hasSuffix(".app"),
                      (try? url.resourceValues(forKeys: [.isApplicationKey]))?.isApplication == true,
                      let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty else { return nil }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                return Entry(id: bundleID, name: name, path: path,
                             icon: NSWorkspace.shared.icon(forFile: path))
            }
            // 按 bundle ID 去重：用户 /Applications 优先于系统目录（保持首见）。
            var seen = Set<String>()
            let unique = apps.filter { seen.insert($0.id).inserted }
            await MainActor.run { [weak self] in
                self?.entries = unique
                self?.indexing = false
            }
        }
    }

    /// 已知应用查找；未安装的返回 nil（调用方保留旧记录）。
    func entry(for id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    /// 解析旧配置列表：能解析的给出名称与图标，不能的保留记录。
    func resolve(_ ids: [String]) -> (known: [Entry], unknown: [UnknownEntry]) {
        var known: [Entry] = []
        var unknown: [UnknownEntry] = []
        for id in ids {
            if let entry = entry(for: id) { known.append(entry) }
            else { unknown.append(UnknownEntry(id: id, displayName: displayCache[id] ?? "")) }
        }
        return (known, unknown)
    }

    /// 文件选择器添加任意位置的 .app；返回 bundle ID。
    func pickViaPanel() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.message = "选择要添加的应用"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        displayCache[bundleID] = name
        if !entries.contains(where: { $0.id == bundleID }) {
            entries.append(Entry(id: bundleID, name: name, path: url.path,
                                 icon: NSWorkspace.shared.icon(forFile: url.path)))
        }
        return bundleID
    }

    private var displayCache: [String: String] = [:]
}
