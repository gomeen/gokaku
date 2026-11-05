import XCTest
@testable import GogakuCore

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
}
