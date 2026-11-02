import Foundation
import GogakuCore

/// 自定义词语页的行模型（可单元测试）：搜索筛选与排序分离。
/// - 搜索覆盖内容、编码和读音；不改变存储顺序；搜索时禁用排序。
/// - 行标识为「类型：存储序号」，筛选后编辑／删除按确切存储行执行，不错行。
public struct CustomWordListModel: Equatable {
    public struct Row: Identifiable, Equatable {
        public let id: String
        public let storageIndex: Int
        public let word: CustomWord
    }

    public private(set) var words: [CustomWord]

    public init(words: [CustomWord]) {
        self.words = words
    }

    public func rows(kind: Int32, search: String) -> [Row] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [Row] = []
        for (index, word) in words.enumerated() where word.kind == kind {
            if !query.isEmpty {
                let hit = word.content.lowercased().contains(query)
                    || word.code.lowercased().contains(query)
                    || word.pinyin.lowercased().contains(query)
                if !hit { continue }
            }
            result.append(Row(id: "\(kind):\(index)", storageIndex: index, word: word))
        }
        return result
    }

    /// 排序只在未搜索时可用；仅同类行交换（跨类型的存储项被跳过），
    /// 清除搜索后按原顺序移动同类型词条。
    public func canMove(storageIndex: Int, delta: Int, searching: Bool) -> Bool {
        guard !searching, words.indices.contains(storageIndex) else { return false }
        return sameKindNeighbor(of: storageIndex, delta: delta) != nil
    }

    public mutating func move(storageIndex: Int, delta: Int, searching: Bool) {
        guard canMove(storageIndex: storageIndex, delta: delta, searching: searching) else { return }
        words.swapAt(storageIndex, sameKindNeighbor(of: storageIndex, delta: delta)!)
    }

    /// 存储序中同类型的上一／下一行；中间隔着的其他类型行不参与排序。
    private func sameKindNeighbor(of storageIndex: Int, delta: Int) -> Int? {
        let kind = words[storageIndex].kind
        var index = storageIndex
        while true {
            index += delta
            guard words.indices.contains(index) else { return nil }
            if words[index].kind == kind { return index }
        }
    }

    public mutating func remove(at storageIndex: Int) {
        guard words.indices.contains(storageIndex) else { return }
        words.remove(at: storageIndex)
    }

    public mutating func update(storageIndex: Int, word: CustomWord) {
        guard words.indices.contains(storageIndex) else { return }
        words[storageIndex] = word
    }

    /// 新词条插入到同类型末尾之后（保持两类型各自相对顺序）。
    public mutating func append(word: CustomWord) {
        var insertAt = 0
        for (index, existing) in words.enumerated() where existing.kind == word.kind {
            insertAt = index + 1
        }
        words.insert(word, at: insertAt)
    }
}
