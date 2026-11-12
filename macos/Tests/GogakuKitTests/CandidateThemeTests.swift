import XCTest
@testable import GogakuKit

final class CandidateThemeTests: XCTestCase {
    func testBuiltinsResolveAppearance() {
        XCTAssertEqual(BuiltinCandidateThemes.all.map(\.id), [.gogaku, .claude, .grok, .witch])
        let gogaku = BuiltinCandidateThemes.theme(.gogaku)
        XCTAssertEqual(gogaku.palette(darkAppearance: false).background.rgb, 0xffffff)
        XCTAssertEqual(gogaku.palette(darkAppearance: true).background.rgb, 0x202823)
        let claude = BuiltinCandidateThemes.theme(.claude)
        XCTAssertEqual(claude.palette(darkAppearance: false).highlight.rgb, 0xdf9e87)
        XCTAssertEqual(claude.palette(darkAppearance: true).comment.rgb, 0xf0a585)
        let grok = BuiltinCandidateThemes.theme(.grok)
        XCTAssertEqual(grok.palette(darkAppearance: false).comment.rgb, 0x0b6dd3)
        XCTAssertEqual(grok.palette(darkAppearance: true).highlight.rgb, 0x28609b)
        let witch = BuiltinCandidateThemes.theme(.witch)
        XCTAssertNil(witch.dark)
        XCTAssertEqual(witch.palette(darkAppearance: false), witch.palette(darkAppearance: true))
        XCTAssertEqual(witch.light.highlight.rgb, 0x75bc4c)
    }

    func testRoundTripAndInvalidColorOrName() throws {
        for theme in BuiltinCandidateThemes.all {
            let data = try JSONEncoder().encode(theme)
            XCTAssertEqual(try JSONDecoder().decode(CandidateTheme.self, from: data), theme)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["name"] = "  "
            XCTAssertThrowsError(try JSONDecoder().decode(CandidateTheme.self, from: JSONSerialization.data(withJSONObject: object)))
            object["name"] = "ok"
            var light = try XCTUnwrap(object["light"] as? [String: Any])
            light["background"] = 0x1000000
            object["light"] = light
            XCTAssertThrowsError(try JSONDecoder().decode(CandidateTheme.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        XCTAssertNil(ThemeColor(rgb: 0x1000000))
    }

    func testCustomThemeRoundTripAndDamageIsolation() throws {
        let id = try XCTUnwrap(CandidateThemeID(rawValue: "用户/任意 ID-\(UUID().uuidString)"))
        var custom = BuiltinCandidateThemes.theme(.claude)
        custom = CandidateTheme(id: id, name: "我的主题", light: custom.light, dark: custom.dark)
        custom.light.comment = try XCTUnwrap(ThemeColor(rgb: 0x123456))
        var settings = Settings()
        settings.userCandidateThemes = [custom]
        settings.candidateTheme = id
        settings.recording = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded.candidateTheme, id)
        XCTAssertEqual(decoded.resolvedCandidateTheme, custom)
        XCTAssertEqual(decoded.resolvedCandidateTheme.palette(darkAppearance: false).comment.rgb, 0x123456)
        XCTAssertNotEqual(decoded.resolvedCandidateTheme.palette(darkAppearance: true), custom.light)
        var single = custom; single.dark = nil
        XCTAssertEqual(single.palette(darkAppearance: true), single.light)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var bad = try XCTUnwrap((object["userCandidateThemes"] as? [[String: Any]])?.first)
        bad["name"] = " "
        object["userCandidateThemes"] = [bad]
        let broken = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(broken.candidateTheme, .rimeMacOSLike)
        XCTAssertFalse(broken.recording)
        XCTAssertTrue(broken.userCandidateThemes.isEmpty)
        object["userCandidateThemes"] = [bad, try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["userCandidateThemes"] as? [[String: Any]])[0]]
        let partial = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(partial.resolvedCandidateTheme, custom)
        var deleted = decoded; deleted.userCandidateThemes = []
        XCTAssertEqual(deleted.resolvedCandidateTheme.id, .rimeMacOSLike)
    }

    func testBuiltinCannotBeOverriddenByUserTheme() throws {
        let builtin = BuiltinCandidateThemes.theme(.claude)
        var spoof = builtin; spoof.name = "伪造"
        var settings = Settings(); settings.userCandidateThemes = [spoof]; settings.candidateTheme = .claude
        XCTAssertEqual(settings.resolvedCandidateTheme, builtin)
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.resolvedCandidateTheme, builtin)
        XCTAssertTrue(decoded.userCandidateThemes.isEmpty)
    }

    func testSettingsCompatibilityAndSelectionRoundTrip() throws {
        func decode(_ json: String) throws -> Settings {
            try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode("{}").candidateTheme, .rimeMacOSLike)
        XCTAssertEqual(try decode("{\"candidateTheme\":\"rime-macos-like\"}").candidateTheme, .rimeMacOSLike)
        let fallback = try decode("{\"candidateTheme\":\"future-theme\",\"recording\":false}")
        XCTAssertEqual(fallback.candidateTheme, .rimeMacOSLike)
        XCTAssertFalse(fallback.recording)
        for theme in BuiltinCandidateThemes.all {
            var settings = Settings()
            settings.candidateTheme = theme.id
            XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)).candidateTheme, theme.id)
        }
    }

    /// 内置主题来自共享核心的 gc_themes_builtin（theme_contract.cpp），
    /// 这里验证 Mac 解码链路与锚点色，锚点与两端的 theme_contract_test 同步。
    func testBuiltinThemesComeFromSharedContract() throws {
        XCTAssertEqual(BuiltinCandidateThemes.all.map(\.id), [.gogaku, .claude, .grok, .witch])
        XCTAssertEqual(BuiltinCandidateThemes.all.map(\.name), ["Gogaku", "Claude", "Grok Bot", "女巫魔药"])
        let gogaku = BuiltinCandidateThemes.theme(.gogaku)
        XCTAssertEqual(gogaku.light.highlight.rgb, 0x12996a)
        XCTAssertEqual(gogaku.dark?.highlight.rgb, 0x168d64)
        XCTAssertNil(BuiltinCandidateThemes.theme(.witch).dark, "单色主题不应有 dark")
        XCTAssertEqual(BuiltinCandidateThemes.theme(.rimeMacOSLike).id, .rimeMacOSLike)
        XCTAssertEqual(BuiltinCandidateThemes.theme(.rimeMacOSLike).light, gogaku.light)
    }

    // MARK: - 内置主题覆盖补丁（原地修改）

    func testBuiltinOverrideAppliesToResolvedTheme() throws {
        var settings = Settings()
        settings.candidateTheme = .claude
        settings.builtinThemeOverrides = ["claude": .object([
            "light": .object(["highlight": .number(1218922)]),
        ])]
        let resolved = settings.resolvedCandidateTheme
        XCTAssertEqual(resolved.id, .claude)
        XCTAssertEqual(resolved.light.highlight.rgb, 1218922)
        // 补丁里没写的字段继续跟随出厂数据。
        XCTAssertEqual(resolved.light.background, BuiltinCandidateThemes.theme(.claude).light.background)
        XCTAssertEqual(resolved.dark, BuiltinCandidateThemes.theme(.claude).dark)
        XCTAssertTrue(settings.overrideIsActive(.claude))
        XCTAssertFalse(settings.overrideIsActive(.gogaku))
    }

    func testBuiltinOverrideCanAddOrRemoveDarkAppearance() throws {
        var settings = Settings()
        let witch = BuiltinCandidateThemes.theme(.witch)
        settings.builtinThemeOverrides = ["witch": .object(["dark": .object([
            "background": .number(0x101010), "border": .number(0x202020),
            "text": .number(0xffffff), "comment": .number(0xcccccc),
            "index": .number(0x999999), "highlight": .number(0x3366cc),
            "highlightText": .number(0xffffff), "highlightComment": .number(0xffffff),
            "cursor": .number(0x3366cc), "page": .number(0x999999),
        ])])]
        settings.candidateTheme = .witch
        XCTAssertEqual(settings.resolvedCandidateTheme.id, .witch)
        XCTAssertNil(witch.dark)
        XCTAssertEqual(settings.resolvedCandidateTheme.dark?.background.rgb, 0x101010)
        // 未应用时列表与编辑器也按覆盖解析，看到同一份。
        XCTAssertEqual(settings.effectiveBuiltinThemes[3].dark?.background.rgb, 0x101010)

        settings.candidateTheme = .claude
        settings.builtinThemeOverrides = ["claude": .object(["dark": .null])]
        XCTAssertEqual(settings.resolvedCandidateTheme.id, .claude)
        XCTAssertNil(settings.resolvedCandidateTheme.dark)
        XCTAssertNotNil(BuiltinCandidateThemes.theme(.claude).dark)
    }

    func testInvalidBuiltinOverrideFallsBackToFactory() throws {
        var settings = Settings()
        settings.candidateTheme = .gogaku
        // 字号超出本端范围：该条回退出厂版本，不影响其他主题或设置。
        settings.builtinThemeOverrides = [
            "gogaku": .object(["typography": .object(["fontSize": .number(99)])]),
            "grok": .object(["light": .object(["highlight": .number(0x123456)])]),
        ]
        XCTAssertEqual(settings.resolvedCandidateTheme, BuiltinCandidateThemes.theme(.gogaku))
        XCTAssertEqual(settings.effectiveBuiltinThemes[2].light.highlight.rgb, 0x123456)
        XCTAssertEqual(settings.recording, true)
    }

    func testRimeAliasIgnoresBuiltinOverride() throws {
        var settings = Settings()
        settings.candidateTheme = .rimeMacOSLike
        settings.builtinThemeOverrides = ["gogaku": .object(["light": .object(["highlight": .number(0x123456)])])]
        let resolved = settings.resolvedCandidateTheme
        XCTAssertEqual(resolved.id, .rimeMacOSLike)
        XCTAssertEqual(resolved.light, BuiltinCandidateThemes.theme(.gogaku).light)
        XCTAssertNotEqual(resolved.light.highlight.rgb, 0x123456)
    }

    func testOverridePatchIsMinimalAndRoundTrips() throws {
        let claude = BuiltinCandidateThemes.theme(.claude)
        XCTAssertEqual(BuiltinCandidateThemes.override(for: claude)?.isEmpty, true, "出厂数据应求差为空补丁")

        var edited = claude
        edited.name = "夜行 Claude"
        edited.light.highlight = try XCTUnwrap(ThemeColor(rgb: 0x123456))
        edited.typography.fontSize = 16
        let patch = try XCTUnwrap(BuiltinCandidateThemes.override(for: edited))
        XCTAssertEqual(patch.count, 3)
        XCTAssertEqual(patch["name"], .string("夜行 Claude"))
        XCTAssertEqual(patch["light"], .object(["highlight": .number(0x123456)]))
        XCTAssertEqual(patch["typography"], .object(["fontSize": .number(16)]))

        var settings = Settings()
        settings.builtinThemeOverrides = ["claude": .object(patch)]
        XCTAssertEqual(settings.effectiveBuiltinThemes[1], edited)

        var single = claude
        single.dark = nil
        XCTAssertEqual(BuiltinCandidateThemes.override(for: single)?["dark"], .null)

        // 用户主题不能求成内置补丁。
        var custom = claude
        custom = CandidateTheme(id: CandidateThemeID(rawValue: UUID().uuidString)!, name: custom.name,
                                light: custom.light, dark: custom.dark)
        XCTAssertNil(BuiltinCandidateThemes.override(for: custom))
    }

    func testOverrideFieldRoundTripsThroughSettingsCoding() throws {
        var settings = Settings()
        settings.builtinThemeOverrides = ["claude": .object(["dark": .null, "light": .object(["highlight": .number(1218922)])])]
        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let overrides = try XCTUnwrap(object["builtinThemeOverrides"] as? [String: Any])
        XCTAssertNotNil(overrides["claude"])
        // 整数值按整数写回，不改写为浮点写法。
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("1218922"))
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded.builtinThemeOverrides, settings.builtinThemeOverrides)
        XCTAssertEqual(Settings().builtinThemeOverrides, [:], "缺省应为空")
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).builtinThemeOverrides, [:])
    }
}
