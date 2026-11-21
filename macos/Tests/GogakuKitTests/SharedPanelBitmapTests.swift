import AppKit
import XCTest
import CGogakuCore
import GogakuKit
@testable import GogakuInput

final class SharedPanelBitmapTests: XCTestCase {
    private func view() -> CompositionView {
        let stamp = InputStamp(mode: .normal, direction: .zhToEn)
        var view = CompositionView(stamp: stamp)
        view.candidateLayoutHorizontal = true
        view.normalPageSize = 4
        view.horizontalGlossRowEnabled = true
        view.page = 1
        view.selected = 5
        view.totalCandidates = 10
        view.preedit = "A🙂"
        view.preeditCaretUTF16 = 3
        view.typedPrefix = "A"
        view.candidates = ["你好", "你好呀", "候选词", "hello"].enumerated().map { index, text in
            Candidate(stamp: stamp, sourceID: "bitmap-test", source: "test",
                      range: RawRange(start: 0, length: 4), target: text,
                      explanation: index == 1 ? "(int.) hello · hi" : "", resource: "test")
        }
        return view
    }

    private func learningView(candidateCount: Int = 20, page: Int = 1) -> CompositionView {
        let stamp = InputStamp(mode: .learning, direction: .zhToEn)
        var view = CompositionView(stamp: stamp)
        view.page = page
        view.selected = page * CandidatePage.size
        view.raw = "metting"
        view.candidates = (0..<candidateCount).map { index in
            Candidate(stamp: stamp, sourceID: "bitmap-test", source: "test",
                      range: RawRange(start: 0, length: 1), target: "候选\(index + 1)",
                      explanation: "", resource: "test")
        }
        return view
    }

    private func render(appearance: NSAppearance.Name, scale: CGFloat) throws -> (PanelContent, SharedPanelBitmap) {
        let content = PanelContent()
        content.appearance = NSAppearance(named: appearance)
        let theme = CandidatePanelTheme.resolve(.gogaku, fontSize: 14)
        content.updateTheme(theme, renderer: .bitmap)
        content.update(view(), backingScale: scale)
        return (content, try XCTUnwrap(content.debugBitmap, content.debugRenderFailure ?? "共享位图渲染失败"))
    }

    func testBitmapContainsCurrentPageHitsAndDispatchesGlobalIndex() throws {
        let (content, bitmap) = try render(appearance: .aqua, scale: 2)
        XCTAssertEqual(content.debugRenderer, .bitmap)
        XCTAssertNil(content.debugRenderFailure)
        XCTAssertEqual(bitmap.scale, 2)
        XCTAssertGreaterThan(bitmap.pixelWidth, 0)
        XCTAssertGreaterThan(bitmap.pixelHeight, 0)
        XCTAssertEqual(bitmap.hits.filter { $0.action == Int32(GC_PANEL_HIT_CHOOSE) }.map(\.argument), [4, 5, 6, 7])
        XCTAssertGreaterThanOrEqual(bitmap.hits.first(where: { $0.action == Int32(GC_PANEL_HIT_CHOOSE) })!.rect.minX, 0)

        var chosen: Int?
        content.choose = { chosen = $0 }
        let second = try XCTUnwrap(bitmap.hits.first { $0.action == Int32(GC_PANEL_HIT_CHOOSE) && $0.argument == 5 })
        let point = NSPoint(x: CGFloat(second.rect.midX) / bitmap.scale,
                            y: CGFloat(second.rect.midY) / bitmap.scale)
        XCTAssertTrue(content.handleHit(at: point))
        XCTAssertEqual(chosen, 1, "共享核心回传全局下标，面板回调转换为现有页内下标")

        let image = try XCTUnwrap(bitmap.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(image.width, bitmap.pixelWidth)
        XCTAssertEqual(image.height, bitmap.pixelHeight)
        XCTAssertNotNil(image.dataProvider?.data, "预乘 RGBA 像素必须实际保留在图像数据中")
    }

    /// 页码已去掉（2026-11-20 裁决）：多页面板不得再产生翻页命中区，但页内
    /// CHOOSE 仍按全局下标给出（翻页只走键盘与 `.`/`,`）。
    func testMultiPageBitmapHasNoPageHitRegions() throws {
        let content = PanelContent()
        content.updateTheme(CandidatePanelTheme.resolve(.gogaku), renderer: .bitmap)
        content.update(learningView(candidateCount: 20, page: 1), backingScale: 1)

        let bitmap = try XCTUnwrap(content.debugBitmap, content.debugRenderFailure ?? "共享位图渲染失败")
        XCTAssertFalse(bitmap.hits.contains { $0.action == Int32(GC_PANEL_HIT_PAGE_PREV) })
        XCTAssertFalse(bitmap.hits.contains { $0.action == Int32(GC_PANEL_HIT_PAGE_NEXT) },
                       "页码去掉后不再有翻页命中区")
        XCTAssertEqual(bitmap.hits.filter { $0.action == Int32(GC_PANEL_HIT_CHOOSE) }.map(\.argument), Array(9...17).map(Int32.init))
    }

    /// 单页与多页同内容必须等高：页码不再凭空占一行（用户报 7→9 个候选项框变高）。
    func testSingleAndMultiPageShareHeight() throws {
        let content = PanelContent()
        content.updateTheme(CandidatePanelTheme.resolve(.gogaku), renderer: .bitmap)
        content.update(learningView(candidateCount: 9, page: 0), backingScale: 1)
        let single = try XCTUnwrap(content.debugBitmap, content.debugRenderFailure ?? "共享位图渲染失败")
        content.update(learningView(candidateCount: 10, page: 0), backingScale: 1)
        let multi = try XCTUnwrap(content.debugBitmap, content.debugRenderFailure ?? "共享位图渲染失败")
        XCTAssertEqual(single.pointSize.height, multi.pointSize.height, accuracy: 0.001,
                       "9 个与 10 个候选的首页面板高度必须一致")
    }

    func testExplainHitRendersIssueExplanationInBitmap() throws {
        let content = PanelContent()
        content.updateTheme(CandidatePanelTheme.resolve(.gogaku), renderer: .bitmap)
        var view = learningView(candidateCount: 2, page: 0)
        view.issues = [SpellingIssue(location: 0, length: 7, explanation: "拼写提示：metting 应为 meeting")]
        content.update(view, backingScale: 1)
        let before = try XCTUnwrap(content.debugBitmap, content.debugRenderFailure ?? "共享位图渲染失败")
        let issueHit = try XCTUnwrap(before.hits.first { $0.action == Int32(GC_PANEL_HIT_EXPLAIN) })
        let point = NSPoint(x: CGFloat(issueHit.rect.midX) / before.scale,
                            y: CGFloat(issueHit.rect.midY) / before.scale)

        XCTAssertTrue(content.handleHit(at: point))
        let after = try XCTUnwrap(content.debugBitmap, content.debugRenderFailure ?? "说明重渲染失败")
        XCTAssertEqual(content.debugRenderer, .bitmap)
        XCTAssertGreaterThan(after.pointSize.height, before.pointSize.height)
        XCTAssertNotEqual(try pixelData(after), try pixelData(before))
    }

    func testOriginalAndRestoreHitsRequireActions() throws {
        let view = learningView(candidateCount: 3, page: 0)
        let theme = CandidatePanelTheme.resolve(.gogaku)
        let content = PanelContent()
        content.updateTheme(theme, renderer: .bitmap)
        content.update(view, backingScale: 1)
        let withoutActions = try XCTUnwrap(content.debugBitmap, content.debugRenderFailure ?? "共享位图渲染失败")
        XCTAssertFalse(withoutActions.hits.contains { $0.action == Int32(GC_PANEL_HIT_ORIGINAL) })
        XCTAssertFalse(withoutActions.hits.contains { $0.action == Int32(GC_PANEL_HIT_RESTORE) })

        content.commitOriginal = {}
        content.restoreDraft = {}
        content.update(view, backingScale: 1)
        let withActions = try XCTUnwrap(content.debugBitmap, content.debugRenderFailure ?? "共享位图渲染失败")
        XCTAssertTrue(withActions.hits.contains { $0.action == Int32(GC_PANEL_HIT_ORIGINAL) })
        XCTAssertTrue(withActions.hits.contains { $0.action == Int32(GC_PANEL_HIT_RESTORE) })
    }

    func testValidationCaretUsesCompositionDataWhenBitmapHasNoPanelLayout() {
        let content = PanelContent()
        content.updateTheme(CandidatePanelTheme.resolve(.gogaku), renderer: .bitmap)
        var view = self.view()
        view.preeditCaretUTF16 = 1
        content.update(view, backingScale: 1)

        XCTAssertEqual(content.validationPreeditCaret, [3, 1])
    }

    func testFontListUsesReadablePublicPingFangFaceForHanFallback() throws {
        let fonts = SharedPanelBitmapRenderer.fontList(theme: CandidatePanelTheme.resolve(.gogaku))
        let pingfang = try XCTUnwrap(fonts.first { $0.postscriptName == "PingFangSC-Regular" })
        XCTAssertEqual(URL(fileURLWithPath: pingfang.path).lastPathComponent, "PingFang.ttc")
        XCTAssertEqual(pingfang.index, -1)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: pingfang.path))
    }

    func testFontListDeduplicatesResolvedFacesAndRetainsLatinRole() {
        let fonts = SharedPanelBitmapRenderer.fontList(theme: CandidatePanelTheme.resolve(.gogaku))
        let identities = fonts.map { "\($0.path)|\($0.postscriptName)" }

        XCTAssertEqual(Set(identities).count, identities.count)
        XCTAssertTrue(fonts.contains { $0.role == "latin" })
    }

    func testLightDarkAndBackingScaleProduceExpectedBitmaps() throws {
        let (_, light1x) = try render(appearance: .aqua, scale: 1)
        let (_, light2x) = try render(appearance: .aqua, scale: 2)
        let (_, dark2x) = try render(appearance: .darkAqua, scale: 2)

        XCTAssertEqual(light2x.scale, 2)
        XCTAssertEqual(dark2x.scale, 2)
        XCTAssertGreaterThanOrEqual(light2x.pixelWidth, light1x.pixelWidth * 2 - 1)
        XCTAssertGreaterThanOrEqual(light2x.pixelHeight, light1x.pixelHeight * 2 - 1)
        XCTAssertLessThanOrEqual(light2x.pixelWidth, light1x.pixelWidth * 2 + 1)
        XCTAssertLessThanOrEqual(light2x.pixelHeight, light1x.pixelHeight * 2 + 1)
        XCTAssertNotEqual(try pixelData(light2x), try pixelData(dark2x), "深浅主题应使用各自调色板")
        XCTAssertEqual(light2x.pointSize.width, dark2x.pointSize.width, accuracy: 1)
        XCTAssertEqual(light2x.pointSize.height, dark2x.pointSize.height, accuracy: 1)
    }

    func testSystemRendererRemainsAvailableAsFallback() throws {
        let content = PanelContent()
        content.updateTheme(CandidatePanelTheme.resolve(.gogaku), renderer: .system)
        content.update(view())
        XCTAssertNil(content.debugBitmap)
        XCTAssertEqual(content.debugRenderer, .system)
        XCTAssertGreaterThan(content.layoutSize.width, 0)
        XCTAssertGreaterThan(content.layoutSize.height, 0)
    }

    func testPreparedThemeSurvivesAppearanceAndRefreshesSameIDEdits() throws {
        var source = BuiltinCandidateThemes.theme(.gogaku)
        source.light.background = try XCTUnwrap(ThemeColor(rgb: 0x112233))
        let first = CandidatePanelTheme.resolve(source)
        let dark = first.resolvingAppearance(try XCTUnwrap(NSAppearance(named: .darkAqua)))
        XCTAssertTrue(first.coreTheme === dark.coreTheme, "外观切换不重复序列化主题")
        let before = try SharedPanelBitmapRenderer.render(view: view(), theme: first, scale: 1, dark: false)
        source.light.background = try XCTUnwrap(ThemeColor(rgb: 0x332211))
        let second = CandidatePanelTheme.resolve(source)
        XCTAssertFalse(first.coreTheme === second.coreTheme, "相同ID的编辑建立新主题快照")
        let after = try SharedPanelBitmapRenderer.render(view: view(), theme: second, scale: 1, dark: false)
        let repeatFirst = try SharedPanelBitmapRenderer.render(view: view(), theme: first, scale: 1, dark: false)
        XCTAssertNotEqual(try pixelData(before), try pixelData(after))
        XCTAssertEqual(try pixelData(before), try pixelData(repeatFirst), "两个主题快照交错渲染不会串缓存")
    }

    func testPreparedThemeIsReleasedWithItsOwner() throws {
        weak var prepared: SharedPanelBitmapTheme?
        do {
            let theme = CandidatePanelTheme.resolve(.gogaku)
            prepared = try XCTUnwrap(theme.coreTheme)
            _ = try SharedPanelBitmapRenderer.render(view: view(), theme: theme, scale: 1, dark: false)
            XCTAssertNotNil(prepared)
        }
        XCTAssertNil(prepared, "无全局缓存保留已不用的主题和PNG")
    }

    private func pixelData(_ bitmap: SharedPanelBitmap) throws -> Data {
        let cgImage = try XCTUnwrap(bitmap.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return try XCTUnwrap(cgImage.dataProvider?.data as Data?)
    }
}
