import XCTest
import AppKit
@testable import GogakuCore
@testable import GogakuInput

final class ThemeVisualTests: XCTestCase {
    private func custom() throws -> CandidateTheme {
        let base = BuiltinCandidateThemes.theme(.claude)
        return CandidateTheme(id: try XCTUnwrap(CandidateThemeID(rawValue: "visual-test")),
                              name: "视觉测试", light: base.light, dark: base.dark)
    }

    private func composition() -> CompositionView {
        let stamp = InputStamp()
        var view = CompositionView(stamp: stamp)
        view.candidates = ["你好", "hello", "你好 hello"].map {
            Candidate(stamp: stamp, sourceID: "test", source: "nihao", range: RawRange(start: 0, length: 5),
                      target: $0, explanation: "int. hello 你好", resource: "test")
        }
        view.totalCandidates = 3
        return view
    }

    func testLegacyJSONAndPartialNewFieldsUseDefaults() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(custom())) as? [String: Any])
        object.removeValue(forKey: "typography")
        for key in ["light", "dark"] {
            var palette = try XCTUnwrap(object[key] as? [String: Any])
            palette.removeValue(forKey: "visual")
            palette.removeValue(forKey: "imageData")
            object[key] = palette
        }
        let decoded = try JSONDecoder().decode(CandidateTheme.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.typography, CandidateThemeTypography())
        XCTAssertEqual(decoded.light.visual, CandidateThemeVisual())
        XCTAssertEqual(decoded.dark?.visual, CandidateThemeVisual())
        XCTAssertNil(decoded.light.imageData)
        XCTAssertEqual(try JSONDecoder().decode(CandidateThemeTypography.self, from: Data("{\"fontEN\":\"Menlo\"}".utf8)),
                       CandidateThemeTypography(fontEN: "Menlo"))
        XCTAssertEqual(try JSONDecoder().decode(CandidateThemeVisual.self, from: Data("{\"opacity\":70}".utf8)),
                       CandidateThemeVisual(opacity: 70))
    }

    func testIndependentPalettesAndImageRoundTrip() throws {
        var theme = try custom()
        theme.typography = .init(fontCN: "PingFang SC", fontEN: "Menlo", fontSize: 22, indexSize: 17)
        theme.light.visual = .init(radius: 2, padding: 3, rowHeight: 80, opacity: 40, bgOpacity: 0, imageOpacity: 100)
        theme.dark?.visual = .init(radius: 20, padding: 20, rowHeight: 140, opacity: 100, bgOpacity: 100, imageOpacity: 0)
        theme.light.imageData = Data([1, 2, 3])
        XCTAssertTrue(theme.isValid)
        XCTAssertEqual(try JSONDecoder().decode(CandidateTheme.self, from: JSONEncoder().encode(theme)), theme)
        XCTAssertNotEqual(theme.light.visual, theme.dark?.visual)
    }

    func testRejectsInvalidNumbersAndFontNames() throws {
        let typographyFields: [(WritableKeyPath<CandidateThemeTypography, Double>, Double, Double)] = [
            (\.fontSize, 12, 24), (\.indexSize, 8, 20)
        ]
        for (key, lower, upper) in typographyFields {
            for value in [lower - 0.1, upper + 0.1, .nan, .infinity, -.infinity] {
                var theme = try custom()
                theme.typography[keyPath: key] = value
                XCTAssertFalse(theme.isValid)
                XCTAssertThrowsError(try JSONEncoder().encode(theme))
            }
        }
        let visualFields: [(String, WritableKeyPath<CandidateThemeVisual, Double>, Double, Double)] = [
            ("radius", \.radius, 0, 20), ("padding", \.padding, 0, 20), ("rowHeight", \.rowHeight, 80, 140),
            ("opacity", \.opacity, 40, 100), ("bgOpacity", \.bgOpacity, 0, 100), ("imageOpacity", \.imageOpacity, 0, 100)
        ]
        for (name, key, lower, upper) in visualFields {
            for value in [lower - 0.1, upper + 0.1, .nan, .infinity, -.infinity] {
                var theme = try custom()
                theme.dark?.visual[keyPath: key] = value
                XCTAssertFalse(theme.isValid)
                XCTAssertThrowsError(try JSONEncoder().encode(theme))
                if value.isFinite {
                    let data = try JSONSerialization.data(withJSONObject: [name: value])
                    XCTAssertThrowsError(try JSONDecoder().decode(CandidateThemeVisual.self, from: data))
                }
            }
        }
        for name in ["", "  \n", String(repeating: "字", count: 129)] {
            var theme = try custom()
            theme.typography.fontCN = name
            XCTAssertFalse(theme.isValid)
            XCTAssertThrowsError(try JSONEncoder().encode(theme))
            let data = try JSONSerialization.data(withJSONObject: ["fontEN": name])
            XCTAssertThrowsError(try JSONDecoder().decode(CandidateThemeTypography.self, from: data))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(CandidateThemeTypography.self, from: Data("{\"fontSize\":25}".utf8)))
    }

    func testNewThemeUsesDemoMetricsAndIndependentAppearance() throws {
        var theme = try custom()
        theme.typography.fontSize = 20
        theme.typography.indexSize = 16
        theme.light.visual = .init(radius: 0, padding: 3, rowHeight: 80, opacity: 50, bgOpacity: 40)
        theme.dark?.visual = .init(radius: 20, padding: 18, rowHeight: 140, opacity: 90, bgOpacity: 80)
        let resolved = CandidatePanelTheme.resolve(theme, fontSize: 12)
        let light = resolved.resolvingAppearance(try XCTUnwrap(NSAppearance(named: .aqua)))
        let dark = resolved.resolvingAppearance(try XCTUnwrap(NSAppearance(named: .darkAqua)))
        XCTAssertEqual(light.metrics.candidateSize, 20)
        XCTAssertEqual(light.metrics.annotationSize, 18)
        XCTAssertEqual(light.metrics.indexSize, 16)
        XCTAssertEqual(light.metrics.rowHeight, 24)
        XCTAssertEqual(dark.metrics.rowHeight, 42)
        XCTAssertEqual(light.metrics.cornerRadius, 0)
        XCTAssertEqual(dark.metrics.windowPadding, 18)
        XCTAssertEqual(light.opacity, 0.5)
        XCTAssertEqual(dark.opacity, 0.9)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            XCTAssertEqual(light.panelBackground.usingColorSpace(.sRGB)!.alphaComponent, 0.4, accuracy: 0.001)
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            XCTAssertEqual(dark.panelBackground.usingColorSpace(.sRGB)!.alphaComponent, 0.8, accuracy: 0.001)
        }
        theme.dark = nil
        let single = CandidatePanelTheme.resolve(theme)
        XCTAssertEqual(single.resolvingAppearance(NSAppearance(named: .darkAqua)!).metrics.rowHeight, 24)
    }

    func testRealLayoutUsesEnglishFontAndRefreshesSameID() throws {
        var theme = try custom()
        theme.typography = .init(fontCN: "Helvetica", fontEN: "Menlo", fontSize: 18, indexSize: 15)
        let content = PanelContent()
        content.appearance = NSAppearance(named: .aqua)
        content.updateTheme(CandidatePanelTheme.resolve(theme))
        content.update(composition())
        let words = content.debugRowWords
        XCTAssertEqual((words[1].attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName,
                       NSFont(name: "Menlo", size: 18)?.fontName)
        XCTAssertEqual((words[2].attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName,
                       NSFont(name: "Helvetica", size: 18)?.fontName)
        XCTAssertEqual((words[2].attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.fontName,
                       NSFont(name: "Menlo", size: 18)?.fontName)
        XCTAssertEqual(content.debugRowFrames[0].height, 30)
        let oldHeight = content.layoutSize.height
        theme.light.visual.rowHeight = 140
        theme.light.visual.padding = 20
        content.updateTheme(CandidatePanelTheme.resolve(theme))
        XCTAssertEqual(content.debugRowFrames[0].height, 42)
        XCTAssertGreaterThan(content.layoutSize.height, oldHeight)
        theme.typography.fontCN = "GogakuMissingFont-123"
        theme.typography.fontEN = "GogakuMissingFont-456"
        let missing = CandidatePanelTheme.resolve(theme)
        XCTAssertEqual(missing.candidateFont.fontName, NSFont.systemFont(ofSize: 18).fontName)
        XCTAssertEqual(missing.candidateEnglishFont.fontName, NSFont.systemFont(ofSize: 18).fontName)
    }

    func testBackgroundAndWholePanelAlphaAreActuallyDrawn() throws {
        var theme = try custom()
        theme.light.visual = .init(radius: 0, padding: 16, opacity: 50, bgOpacity: 40)
        let content = PanelContent()
        content.appearance = NSAppearance(named: .aqua)
        content.updateTheme(CandidatePanelTheme.resolve(theme))
        content.update(composition())
        content.frame = NSRect(origin: .zero, size: content.layoutSize)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(content.frame.width),
            pixelsHigh: Int(content.frame.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(content.bounds)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { content.draw(content.bounds) }
        NSGraphicsContext.restoreGraphicsState()
        let pixel = try XCTUnwrap(bitmap.colorAt(x: 4, y: 4))
        XCTAssertEqual(pixel.alphaComponent, 0.2, accuracy: 0.025)
    }

    func testImageIsDecodedAtThemeUpdateAndReusedByLayoutAndAppearance() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
        var theme = try custom()
        theme.light.imageData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        theme.dark?.imageData = theme.light.imageData
        let resolved = CandidatePanelTheme.resolve(theme)
        let light = resolved.resolvingAppearance(NSAppearance(named: .aqua)!)
        let image = try XCTUnwrap(light.backgroundImage)
        XCTAssertTrue(image === light.resolvingAppearance(NSAppearance(named: .darkAqua)!).backgroundImage)
        let content = PanelContent()
        content.appearance = NSAppearance(named: .aqua)
        content.updateTheme(light)
        for _ in 0..<5 { content.update(composition()) }
        XCTAssertTrue(content.debugTheme.backgroundImage === image)
        theme.light.imageData = Data("not a PNG".utf8)
        XCTAssertNil(CandidatePanelTheme.resolve(theme).resolvingAppearance(NSAppearance(named: .aqua)!).backgroundImage)
    }

    func testLegacyGlobalFontAndNoBorderRemainCompatible() {
        for size: CGFloat in [12, 14, 16] {
            let theme = CandidatePanelTheme.resolve(.rimeMacOSLike, fontSize: size)
            XCTAssertEqual(theme.metrics.candidateSize, size)
            XCTAssertEqual(theme.metrics.indexSize, size - 3)
            XCTAssertEqual(theme.metrics.rowHeight, 46 * size / 21, accuracy: 0.001)
            XCTAssertEqual(theme.panelBorder.alphaComponent, 0)
        }
        XCTAssertEqual(CandidatePanelTheme.resolve(.rimeMacOSLike, fontSize: 24).metrics.candidateSize, 16)
    }
}
