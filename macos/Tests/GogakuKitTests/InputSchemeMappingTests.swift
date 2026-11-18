import XCTest
import CGogakuCore
@testable import GogakuKit

/// 输入方案枚举与共享核心唯一映射（gc_scheme_from_id／gc_scheme_id）的一致性。
/// 双拼键位表只住在 libime／共享核心；Mac 枚举只透传，见 Settings.swift 的
/// InputScheme 注释。未知 ID 的回退由共享核心保证（回退小鹤）。
final class InputSchemeMappingTests: XCTestCase {
    func testAllSchemesMapToSharedCoreContract() {
        let cases: [(InputScheme, Int32, String)] = [
            (.xiaohe, 0, "xiaohe"), (.fullPinyin, 1, "fullPinyin"), (.ziranma, 2, "ziranma"),
            (.mspy, 3, "mspy"), (.abc, 4, "abc"), (.ziguang, 5, "ziguang"),
            (.pinyinjiajia, 6, "pinyinjiajia"), (.gb, 7, "gb"),
        ]
        XCTAssertEqual(Set(cases.map(\.0)), Set(InputScheme.allCases), "枚举与映射表必须同步")
        for (scheme, value, id) in cases {
            XCTAssertEqual(scheme.coreValue, value, "\(scheme) coreValue")
            XCTAssertEqual(String(cString: gc_scheme_id(scheme.coreValue)), id)
            XCTAssertEqual(gc_scheme_from_id(id), value)
            XCTAssertFalse(scheme.displayName.isEmpty)
        }
        XCTAssertEqual(gc_scheme_from_id("no-such-scheme"), 0, "未知 ID 回退小鹤")
    }

    func testSettingsRoundTripKeepsNewScheme() throws {
        var settings = Settings()
        settings.inputScheme = .ziranma
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded.inputScheme, .ziranma)
    }
}
