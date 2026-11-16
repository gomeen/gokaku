import XCTest
import GogakuKit

/// 组合期间按键归属（2026-11-13 用户事故回归）。
///
/// 事故：候选窗显示时按退格，删掉的是**之前已提交的正文**。真因有两条：
/// ① 宿主瞬时读不到应用身份时输入法把按键漏给宿主；
/// ② 前向删除（keyCode 117）未映射，走「先上屏原编码再交还宿主」分支，
///    宿主随即把刚上屏的字删掉。
///
/// 合同：组合存在时破坏性按键由输入法拥有。`CompositionKeyPolicy` 是这条
/// 合同的唯一实现，`InputController` 两条路径都调用它。
final class CompositionKeyOwnershipTests: XCTestCase {
    /// 实测按键码：51＝退格（Apple 键盘上标 delete），117＝前向删除。
    func testDestructiveKeysCovered() {
        XCTAssertTrue(CompositionKeyPolicy.isDestructive(51))
        XCTAssertTrue(CompositionKeyPolicy.isDestructive(117))
        XCTAssertFalse(CompositionKeyPolicy.isDestructive(49), "空格不是破坏性键")
        XCTAssertFalse(CompositionKeyPolicy.isDestructive(36), "回车不是破坏性键")
    }

    func testComposingOwnsDestructiveKeys() {
        for code in CompositionKeyPolicy.destructiveKeyCodes {
            XCTAssertTrue(CompositionKeyPolicy.keepsKeyOwned(keyCode: code, composing: true),
                          "组合中 keyCode \(code) 必须由输入法吞掉，否则会删掉已提交正文")
        }
    }

    func testNoCompositionPassesDestructiveKeysToHost() {
        for code in CompositionKeyPolicy.destructiveKeyCodes {
            XCTAssertFalse(CompositionKeyPolicy.keepsKeyOwned(keyCode: code, composing: false),
                           "无组合时 keyCode \(code) 必须交还宿主")
        }
    }

    /// 非破坏性未映射键（Tab）不受影响：组合中仍可「先上屏再交还宿主」。
    func testOtherKeysUnaffected() {
        XCTAssertFalse(CompositionKeyPolicy.keepsKeyOwned(keyCode: 48, composing: true))
    }
}
