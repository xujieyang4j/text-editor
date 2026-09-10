import AppKit
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class NativeEditorPaletteTests: XCTestCase {
    func testAllEditorColorSchemesHaveDistinctSurfaceColors() {
        let palettes = EditorColorScheme.allCases.map { scheme in
            NativeEditorPalette.make(
                colorScheme: scheme, compatibleWith: .dark, increasedContrast: false
            )
        }

        XCTAssertEqual(Set(palettes.map { rgba($0.background) }).count, 4)
        XCTAssertEqual(Set(palettes.map { rgba($0.foreground) }).count, 4)
        XCTAssertEqual(Set(palettes.map { rgba($0.insertionPoint) }).count, 4)
        XCTAssertEqual(Set(palettes.map { rgba($0.gutterForeground) }).count, 4)
        XCTAssertTrue(palettes.allSatisfy { palette in
            rgba(palette.diagnosticError) != rgba(palette.diagnosticWarning)
                && rgba(palette.diagnosticWarning) != rgba(palette.diagnosticInformation)
        })
    }

    func testThemeControlsNativeAppearanceWithoutReplacingSchemeColors() {
        let darkCompatibility = NativeEditorPalette.make(
            colorScheme: .solarizedDark,
            compatibleWith: .dark,
            increasedContrast: false
        )
        let lightCompatibility = NativeEditorPalette.make(
            colorScheme: .solarizedDark,
            compatibleWith: .light,
            increasedContrast: false
        )

        XCTAssertEqual(darkCompatibility.appearanceName, .darkAqua)
        XCTAssertEqual(lightCompatibility.appearanceName, .aqua)
        XCTAssertEqual(rgba(darkCompatibility.background), rgba(lightCompatibility.background))
        XCTAssertEqual(rgba(darkCompatibility.foreground), rgba(lightCompatibility.foreground))
    }

    func testPaletteMatchesElectronEditorThemeAnchors() {
        let light = NativeEditorPalette.make(
            colorScheme: .light, compatibleWith: .light, increasedContrast: false
        )
        XCTAssertEqual(rgba(light.background), "1.0000,1.0000,1.0000,1.0000")
        XCTAssertEqual(rgba(light.foreground), "0.1412,0.1608,0.1843,1.0000")

        let solarized = NativeEditorPalette.make(
            colorScheme: .solarizedDark,
            compatibleWith: .dark,
            increasedContrast: false
        )
        XCTAssertEqual(rgba(solarized.background), "0.0000,0.1686,0.2118,1.0000")

        let dracula = NativeEditorPalette.make(
            colorScheme: .dracula,
            compatibleWith: .dark,
            increasedContrast: false
        )
        XCTAssertEqual(rgba(dracula.insertionPoint), "1.0000,0.4745,0.7765,1.0000")
    }

    func testIncreasedContrastStrengthensEditorAffordances() {
        let standard = NativeEditorPalette.make(
            colorScheme: .dark, compatibleWith: .dark, increasedContrast: false
        )
        let increased = NativeEditorPalette.make(
            colorScheme: .dark, compatibleWith: .dark, increasedContrast: true
        )

        XCTAssertNotEqual(rgba(standard.selectionBackground), rgba(increased.selectionBackground))
        XCTAssertGreaterThan(increased.ruler.alphaComponent, standard.ruler.alphaComponent)
        XCTAssertGreaterThan(increased.whitespace.alphaComponent, standard.whitespace.alphaComponent)
        XCTAssertGreaterThan(
            increased.trailingWhitespace.alphaComponent,
            standard.trailingWhitespace.alphaComponent
        )
        XCTAssertGreaterThan(
            increased.currentLineBackground.alphaComponent,
            standard.currentLineBackground.alphaComponent
        )
        XCTAssertGreaterThan(
            increased.selectionMatchBackground.alphaComponent,
            standard.selectionMatchBackground.alphaComponent
        )
        XCTAssertGreaterThan(
            increased.matchingBracketLineWidth,
            standard.matchingBracketLineWidth
        )
        XCTAssertEqual(
            rgba(standard.diagnosticColor(for: .error)),
            rgba(standard.diagnosticError)
        )
        XCTAssertEqual(
            rgba(standard.diagnosticColor(for: .warning)),
            rgba(standard.diagnosticWarning)
        )
        XCTAssertEqual(
            rgba(standard.diagnosticColor(for: .information)),
            rgba(standard.diagnosticInformation)
        )
    }

    private func rgba(_ color: NSColor) -> String {
        let value = color.usingColorSpace(.sRGB) ?? color
        return String(
            format: "%.4f,%.4f,%.4f,%.4f",
            value.redComponent,
            value.greenComponent,
            value.blueComponent,
            value.alphaComponent
        )
    }
}
