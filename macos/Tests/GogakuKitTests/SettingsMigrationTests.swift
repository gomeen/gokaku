import XCTest
import AppKit
@testable import GogakuKit

/// 设置模型旧格式迁移：新增字段缺省采用原默认值，明确清除不复活（2026-11-03 定稿）。
final class SettingsMigrationTests: XCTestCase {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    func testLegacyStringAppDefaultEnglishBecomesEnabledEntries() throws {
        let settings = try decode("""
        {"appDefaultEnglish": ["com.raycast.macos", "md.obsidian"]}
        """)
        XCTAssertEqual(settings.appDefaultEnglish.map(\.id), ["com.raycast.macos", "md.obsidian"])
        XCTAssertTrue(settings.appDefaultEnglish.allSatisfy(\.enabled))
        XCTAssertEqual(settings.enabledDefaultEnglishApps, ["com.raycast.macos", "md.obsidian"])
    }

    func testNewAppDefaultEnglishKeepsDisabledRows() throws {
        let settings = try decode("""
        {"appDefaultEnglish": [{"id": "com.a", "enabled": false}, {"id": "com.b", "enabled": true}]}
        """)
        XCTAssertEqual(settings.enabledDefaultEnglishApps, ["com.b"])
        // 关闭后仍保留该行。
        XCTAssertEqual(settings.appDefaultEnglish.count, 2)
        XCTAssertFalse(settings.appDefaultEnglish[0].enabled)
    }


    func testGlobalModePreferenceDecodedAndValidated() throws {
        // 2026-11-04 用户裁决：全局普通／学习状态持久化；非法值回退默认。
        let settings = try decode("""
        {"preferredMode": "learning", "preferredDirection": "enToZh"}
        """)
        XCTAssertEqual(settings.preferredMode, .learning)
        XCTAssertEqual(settings.preferredDirection, .enToZh)
        let fallback = try decode("{}")
        XCTAssertEqual(fallback.preferredMode, .normal)
        XCTAssertEqual(fallback.preferredDirection, .zhToEn)
    }

    func testLegacyShortcutDefaultsAndDisabledSurvive() throws {
        // 旧格式：缺 disabled 字段不等于清除。
        let legacy = try decode("""
        {"modeShortcut": {"key": "k", "modifiers": 131072}}
        """)
        XCTAssertFalse(legacy.modeShortcut.disabled)
        XCTAssertTrue(legacy.modeShortcut.isValid)
        // 明确清除：重启不能自动恢复旧绑定。
        let cleared = try decode("""
        {"directionShortcut": {"key": "", "modifiers": 0, "disabled": true}}
        """)
        XCTAssertTrue(cleared.directionShortcut.disabled)
        XCTAssertFalse(cleared.directionShortcut.isValid)
        // 缺省快捷键采用原默认值。
        let missing = try decode("{}")
        XCTAssertEqual(missing.modeShortcut, ConfigurableCommand.modeSwitch.defaultShortcut)
        XCTAssertEqual(missing.directionShortcut, ConfigurableCommand.directionSwitch.defaultShortcut)
    }

    func testAppListsAreIndependent() throws {
        // 学习与隐私排除、按应用默认英文是两个独立设置，互不串值。
        var settings = Settings()
        settings.excludedApplications = ["com.privacy.excluded"]
        settings.appDefaultEnglish = [EnglishAppEntry(id: "com.default.english", enabled: true)]
        let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(round.excludedApplications, ["com.privacy.excluded"])
        XCTAssertEqual(round.enabledDefaultEnglishApps, ["com.default.english"])
    }

    func testFontAndFuzzyDefaultsOnMissingKeys() throws {
        let settings = try decode("{}")
        XCTAssertEqual(settings.candidateFontSize, 14)
        XCTAssertTrue(settings.fuzzyPinyin.isEmpty)
        XCTAssertTrue(settings.glossEnabled)
        XCTAssertTrue(settings.inputLettersEnabled)
        XCTAssertTrue(settings.fullPinyinPreedit)
    }

    func testPageSizesDecodeClampAndRoundTrip() throws {
        // 2026-11-19：竖排每页数量可配置，与横排同规格（4–9）。
        let missing = try decode("{}")
        XCTAssertEqual(missing.verticalPageSize, 9, "缺键默认 9")
        XCTAssertEqual(missing.horizontalPageSize, 7)

        XCTAssertEqual(try decode("{\"verticalPageSize\": 12}").verticalPageSize, 9, "超上限钳到 9")
        XCTAssertEqual(try decode("{\"verticalPageSize\": 1}").verticalPageSize, 4, "低于下限钳到 4")
        XCTAssertEqual(try decode("{\"verticalPageSize\": 5}").verticalPageSize, 5)
        // 非整数类型单独丢弃（共享契约口径：非整数值不写回，回默认），
        // 不影响其他字段。Swift 侧 Int 严格解码对非整数值直接抛错，
        // 因此平台读盘永远先过共享契约规范化（见 SettingsStoreTests）。
        // 这里用浮点值验证同一口径：decodeIfPresent 对 5.5 也抛错，
        // 所以仅在显式标记 throws 的本测试断言错误路径。
        do {
            _ = try decode("{\"verticalPageSize\": 5.5}")
            XCTFail("浮点页大小应被共享契约拦截，Swift 直接解码必须报错")
        } catch { /* 预期路径：严格类型不静默转换 */ }
        let wrongType = try decode("{\"candidateFontSize\": 15}")
        XCTAssertEqual(wrongType.verticalPageSize, 9, "缺键仍回默认 9")
        XCTAssertEqual(wrongType.candidateFontSize, 15)

        // 编码往返保留显式值。
        var settings = Settings()
        settings.verticalPageSize = 5
        settings.horizontalPageSize = 6
        let round = try JSONDecoder().decode(Settings.self,
                                             from: JSONEncoder().encode(settings))
        XCTAssertEqual(round.verticalPageSize, 5)
        XCTAssertEqual(round.horizontalPageSize, 6)
        // schemaVersion 不动：新字段是可选解码，旧文件缺键不迁移。
        XCTAssertEqual(round.schemaVersion, 2)
    }

    func testEffectiveNormalPageSizeFollowsLayout() throws {
        // 竖排用 verticalPageSize，横排用 horizontalPageSize（都 4–9）。
        var settings = Settings()
        XCTAssertEqual(settings.effectiveNormalPageSize, 9, "默认竖排 9")
        settings.verticalPageSize = 5
        XCTAssertEqual(settings.effectiveNormalPageSize, 5)
        settings.candidateLayout = .horizontal
        settings.horizontalPageSize = 7
        XCTAssertEqual(settings.effectiveNormalPageSize, 7, "横排改用 horizontalPageSize")
        settings.horizontalPageSize = 4
        XCTAssertEqual(settings.effectiveNormalPageSize, 4)
        settings.candidateLayout = .vertical
        XCTAssertEqual(settings.effectiveNormalPageSize, 5, "切回竖排恢复 verticalPageSize")
    }

    func testFontClampOnOutOfRangeLegacyValue() throws {
        XCTAssertEqual(try decode("{\"candidateFontSize\": 99}").candidateFontSize, 16)
        XCTAssertEqual(try decode("{\"candidateFontSize\": 1}").candidateFontSize, 12)
    }

    func testEncodingStaysLegacyCompatibleForDefaults() throws {
        // 新字段编码保持旧格式兼容：默认值不写新字段，随包同建的旧二进制仍可解码。
        var settings = Settings()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        let shortcut = try XCTUnwrap(json["modeShortcut"] as? [String: Any])
        XCTAssertNil(shortcut["disabled"], "默认快捷键不写 disabled 字段")
        let apps = try XCTUnwrap(json["appDefaultEnglish"] as? [Any])
        XCTAssertTrue(apps.allSatisfy { $0 is String }, "启用中的默认英文应用输出旧格式字符串")
        // 明确清除与停用才使用新字段。
        settings.modeShortcut = Shortcut(key: "", modifiers: 0, disabled: true)
        settings.appDefaultEnglish[0].enabled = false
        let json2 = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertEqual((json2["modeShortcut"] as? [String: Any])?["disabled"] as? Bool, true)
        let apps2 = try XCTUnwrap(json2["appDefaultEnglish"] as? [Any])
        XCTAssertNotNil(apps2[0] as? [String: Any], "停用条目使用对象形式")
        XCTAssertNotNil(try? JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)))
    }
}
