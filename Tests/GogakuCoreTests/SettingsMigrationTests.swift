import XCTest
import AppKit
@testable import GogakuCore

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
        XCTAssertEqual(missing.quickAddShortcut, ConfigurableCommand.quickAdd.defaultShortcut)
    }

    func testThreeAppListsAreIndependent() throws {
        // 快速添加排除、学习与隐私排除、按应用默认英文是三个独立设置，互不串值。
        var settings = Settings()
        settings.quickAddExcludedApplications = ["com.quick.added"]
        settings.excludedApplications = ["com.privacy.excluded"]
        settings.appDefaultEnglish = [EnglishAppEntry(id: "com.default.english", enabled: true)]
        let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(round.quickAddExcludedApplications, ["com.quick.added"])
        XCTAssertEqual(round.excludedApplications, ["com.privacy.excluded"])
        XCTAssertEqual(round.enabledDefaultEnglishApps, ["com.default.english"])
        XCTAssertFalse(round.quickAddExcludedApplications.contains("com.privacy.excluded"))
        XCTAssertFalse(round.excludedApplications.contains("com.quick.added"))
    }

    func testFontAndFuzzyDefaultsOnMissingKeys() throws {
        let settings = try decode("{}")
        XCTAssertEqual(settings.candidateFontSize, 14)
        XCTAssertTrue(settings.fuzzyPinyin.isEmpty)
        XCTAssertTrue(settings.glossEnabled)
        XCTAssertTrue(settings.inputLettersEnabled)
        XCTAssertTrue(settings.fullPinyinPreedit)
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
