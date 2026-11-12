import XCTest
@testable import GogakuKit
@testable import GogakuSettings

final class SkinEditorSessionTests: XCTestCase {
    func testCopyAndDraftIsolation() throws {
        let builtin = BuiltinCandidateThemes.theme(.claude)
        var source = builtin
        source.typography = CandidateThemeTypography(fontCN: "PingFang SC", fontEN: "Menlo", fontSize: 18, indexSize: 10)
        let session = SkinEditorSession()
        session.begin(source, copy: true)
        XCTAssertTrue(session.dirty)
        XCTAssertNotEqual(session.draft?.id, source.id)
        XCTAssertEqual(session.draft?.typography, source.typography)
        session.draft?.light.comment = try XCTUnwrap(ThemeColor(rgb: 0x123456))
        XCTAssertNotEqual(session.draft?.light, source.light)
        XCTAssertEqual(BuiltinCandidateThemes.theme(.claude), builtin)
        session.discard()
        XCTAssertNil(session.draft)
    }

    func testExistingDraftDirtyAndSingleAppearance() {
        let source = BuiltinCandidateThemes.theme(.witch)
        let session = SkinEditorSession()
        session.begin(source, copy: false)
        XCTAssertFalse(session.dirty)
        session.draft?.dark = session.draft?.light
        XCTAssertTrue(session.dirty)
        session.draft?.dark = nil
        XCTAssertFalse(session.dirty)
        session.draft?.name = "更改"
        XCTAssertTrue(session.dirty)
    }

    /// 内置主题原地编辑：入口拿到的是已套用覆盖的版本，ID 不变，dirty 只看草稿。
    func testInPlaceBuiltinEditingTracksDirtyAndIdentity() throws {
        var overridden = BuiltinCandidateThemes.theme(.claude)
        overridden.light.highlight = try XCTUnwrap(ThemeColor(rgb: 0x123456))
        var settings = Settings()
        settings.candidateTheme = .claude
        settings.builtinThemeOverrides = ["claude": .object(try XCTUnwrap(BuiltinCandidateThemes.override(for: overridden)))]

        let session = SkinEditorSession()
        session.begin(settings.resolvedCandidateTheme, copy: false)
        XCTAssertEqual(session.draft?.id, .claude)
        XCTAssertEqual(session.draft?.light.highlight.rgb, 0x123456)
        XCTAssertFalse(session.dirty)
        session.draft?.typography.fontSize = 18
        XCTAssertTrue(session.dirty)
        let patch = try XCTUnwrap(BuiltinCandidateThemes.override(for: try XCTUnwrap(session.draft)))
        XCTAssertEqual(Set(patch.keys), ["light", "typography"], "求差只包含改动过的字段")
        session.discard()
        XCTAssertNil(session.draft)
    }
}
