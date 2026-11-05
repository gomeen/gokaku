import XCTest
import AppKit
@testable import GogakuCore
@testable import GogakuInput

final class LegacyCandidateAppearanceTests: XCTestCase {
    func testCustomPaletteActuallyFeedsRendering() throws {
        let id = try XCTUnwrap(CandidateThemeID(rawValue: UUID().uuidString))
        let base = BuiltinCandidateThemes.theme(.claude)
        var custom = CandidateTheme(id: id, name: "Custom", light: base.light, dark: base.dark)
        custom.light.background = try XCTUnwrap(ThemeColor(rgb: 0x123456))
        custom.dark?.background = try XCTUnwrap(ThemeColor(rgb: 0x987654))
        let theme = CandidatePanelTheme.resolve(custom)
        for (name, expected) in [(NSAppearance.Name.aqua, UInt32(0x123456)), (.darkAqua, UInt32(0x987654))] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let c = theme.panelBackground.usingColorSpace(.sRGB)!
                let rgb = (UInt32((c.redComponent * 255).rounded()) << 16) | (UInt32((c.greenComponent * 255).rounded()) << 8) | UInt32((c.blueComponent * 255).rounded())
                XCTAssertEqual(rgb, expected)
            }
        }
        custom.dark = nil
        let single = CandidatePanelTheme.resolve(custom)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            XCTAssertEqual(single.panelBackground.usingColorSpace(.sRGB)!.redComponent, 18.0 / 255.0, accuracy: 0.001)
        }
    }

    func testPanelRefreshesEditedThemeWithSameID() throws {
        let id = try XCTUnwrap(CandidateThemeID(rawValue: UUID().uuidString))
        let base = BuiltinCandidateThemes.theme(.claude)
        var custom = CandidateTheme(id: id, name: "Custom", light: base.light, dark: nil)
        let panel = CandidatePanel()
        panel.updateTheme(custom)
        custom.light.background = try XCTUnwrap(ThemeColor(rgb: 0x123456))
        panel.updateTheme(custom)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let color = panel.theme.panelBackground.usingColorSpace(.sRGB)!
            XCTAssertEqual(color.redComponent, 18.0 / 255.0, accuracy: 0.001)
        }
    }

    func testOldSettingsRetainEveryRenderingColor() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        let theme = CandidatePanelTheme.resolve(settings.candidateTheme)
        let colors: [(NSColor, UInt32, UInt32)] = [
            (theme.panelBackground, 0xffffff, 0x2d1e1f),
            (theme.sourceText, 0x3c3c3c, 0xeae9e9),
            (theme.typedText, 0x6b6b6b, 0xa3a09d),
            (theme.restText, 0x757575, 0x999999),
            (theme.caretColor, 0x3c3c3c, 0xeae9e9),
            (theme.candidateText, 0x3c3c3c, 0xeae9e9),
            (theme.indexText, 0x757575, 0x999999),
            (theme.annotationText, 0x7d5800, 0xe3a82e),
            (theme.selectedFill, 0x12996a, 0x12996a),
            (theme.selectedText, 0xffffff, 0xffffff),
            (theme.selectedAnnotation, 0xffffff, 0xeefaf5),
            (theme.statusText, 0x6b6b6b, 0xa3a09d),
            (theme.pageText, 0x757575, 0x999999),
        ]
        for (appearance, index) in [(NSAppearance.Name.aqua, 0), (.darkAqua, 1)] {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                for (color, light, dark) in colors {
                    let c = color.usingColorSpace(.sRGB)!
                    let rgb = (UInt32((c.redComponent * 255).rounded()) << 16)
                        | (UInt32((c.greenComponent * 255).rounded()) << 8)
                        | UInt32((c.blueComponent * 255).rounded())
                    XCTAssertEqual(rgb, index == 0 ? light : dark)
                }
                XCTAssertEqual(theme.panelBorder.alphaComponent, 0)
            }
        }
    }
}
