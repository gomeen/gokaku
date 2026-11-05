import XCTest
@testable import GogakuCore
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
}
