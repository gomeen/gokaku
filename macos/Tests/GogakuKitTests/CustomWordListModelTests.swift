import XCTest
@testable import GogakuKit

/// 自定义词语页行模型：搜索筛选与存储顺序分离（2026-11-03 定稿）。
final class CustomWordListModelTests: XCTestCase {
    private func shortcode(_ code: String, content: String, enabled: Bool = true) -> CustomWord {
        CustomWord(kind: 0, enabled: enabled, code: code, pinyin: "", content: content)
    }
    private func pinyin(_ content: String, pinyin: String) -> CustomWord {
        CustomWord(kind: 1, enabled: true, code: "", pinyin: pinyin, content: content)
    }

    private func makeModel() -> CustomWordListModel {
        CustomWordListModel(words: [
            shortcode("qq", content: "请稍等，我马上处理。"),
            pinyin("会议纪要", pinyin: "hui'yi'ji'yao"),
            shortcode("br", content: "Best regards"),
            pinyin("极视角", pinyin: "ji'shi'jiao"),
        ])
    }

    func testRowsFilterByContentCodeAndPinyin() {
        let model = makeModel()
        XCTAssertEqual(model.rows(kind: 0, search: "").count, 2)
        // 内容命中。
        XCTAssertEqual(model.rows(kind: 0, search: "马上").map(\.word.code), ["qq"])
        // 编码命中（大小写不敏感）。
        XCTAssertEqual(model.rows(kind: 0, search: "BR").map(\.word.code), ["br"])
        // 读音命中。
        XCTAssertEqual(model.rows(kind: 1, search: "jiao").map(\.word.content), ["极视角"])
        // 无命中返回空，但不改变存储。
        XCTAssertTrue(model.rows(kind: 1, search: "zzz").isEmpty)
        XCTAssertEqual(model.words.count, 4)
    }

    func testRowIDsReferenceStorageIndexStableThroughFiltering() {
        let model = makeModel()
        let filtered = model.rows(kind: 1, search: "极视角")
        XCTAssertEqual(filtered.count, 1)
        let row = filtered[0]
        // 行标识引用存储行：按存储索引更新不会错行。
        XCTAssertEqual(model.words[row.storageIndex].content, "极视角")
    }

    func testMoveRestrictedToSameKindAndDisabledWhileSearching() {
        var model = makeModel()
        // 存储序：0 qq（短码）、1 会议纪要（拼音）、2 br（短码）、3 极视角（拼音）。
        XCTAssertTrue(model.canMove(storageIndex: 0, delta: 1, searching: false),
                      "qq 向下跳过拼音词到达同类 br")
        XCTAssertFalse(model.canMove(storageIndex: 0, delta: -1, searching: false), "qq 已是同类第一")
        XCTAssertTrue(model.canMove(storageIndex: 1, delta: 1, searching: false),
                      "会议纪要 → 极视角同类可换（跳过短码 br）")
        model.move(storageIndex: 1, delta: 1, searching: false)
        XCTAssertEqual(model.words[1].content, "极视角")
        XCTAssertEqual(model.words[3].content, "会议纪要", "拼音词相对顺序变化，短码短语不变")
        // qq 向下移动应落到 br 之后（同类排序），跨类型行保持相对位置。
        model.move(storageIndex: 0, delta: 1, searching: false)
        XCTAssertEqual(model.words.map(\.code), ["br", "", "qq", ""], "qq 与 br 交换，拼音词位置不变")
        // 搜索时禁用排序：移动请求本身不生效。
        XCTAssertFalse(model.canMove(storageIndex: 1, delta: 1, searching: true))
        model.move(storageIndex: 1, delta: 1, searching: true)
        XCTAssertEqual(model.words[1].content, "极视角", "搜索中的移动请求不生效")
    }

    func testRemoveAndUpdateByStorageIndex() {
        var model = makeModel()
        let rows = model.rows(kind: 0, search: "br")
        model.remove(at: rows[0].storageIndex)
        XCTAssertEqual(model.words.map(\.code), ["qq", "", ""], "只删除命中的那一行")
        XCTAssertEqual(model.words[1].content, "会议纪要", "其余行顺序不变")

        let pinyinRows = model.rows(kind: 1, search: "会议纪要")
        model.update(storageIndex: pinyinRows[0].storageIndex,
                     word: pinyin("会议纪要", pinyin: "hui'yi"))
        XCTAssertEqual(model.words.first(where: { $0.content == "会议纪要" })?.pinyin, "hui'yi")
    }

    func testAppendInsertsAfterLastSameKind() {
        var model = makeModel()
        model.append(word: pinyin("新词", pinyin: "xin'ci"))
        XCTAssertEqual(model.words.last?.content, "新词", "拼音词插到拼音词末尾（本例是存储末尾）")
        model.append(word: shortcode("zz", content: "新的短语"))
        // 短码短语插到同类型末尾之后（qq、br 之后），拼音词相对顺序不变。
        let codes = model.words.filter { !$0.code.isEmpty }.map(\.code)
        XCTAssertEqual(codes, ["qq", "br", "zz"])
        let pinyinContents = model.words.filter { $0.kind == 1 }.map(\.content)
        XCTAssertEqual(pinyinContents, ["会议纪要", "极视角", "新词"])
    }
}
