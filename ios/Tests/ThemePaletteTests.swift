import XCTest
import SwiftUI
@testable import TwilDiary

/// Premiere's palette and how it shows the colours typed into screens.
final class ThemePaletteTests: XCTestCase {
    private func rgb(_ color: Color) -> (r: Float, g: Float, b: Float) {
        let resolved = color.resolve(in: EnvironmentValues())
        return (resolved.red, resolved.green, resolved.blue)
    }

    func testTheOriginalThemesKeepTheirColours() {
        for theme in DiaryTheme.allCases where theme != .premiere {
            XCTAssertEqual(theme.palette, .classic, "\(theme) keeps the app's own colours")
        }
        XCTAssertEqual(DiaryTheme.premiere.palette, .premiere)
        XCTAssertFalse(ThemePalette.classic.neutralizesViolet)
        XCTAssertTrue(ThemePalette.premiere.neutralizesViolet)
        // Premiere's colour comes from the artwork behind the glass, never a fixed tint.
        XCTAssertTrue(ThemePalette.premiere.ambientArtwork); XCTAssertTrue(ThemePalette.premiere.usesGlass)
        XCTAssertFalse(ThemePalette.classic.ambientArtwork); XCTAssertFalse(ThemePalette.classic.usesGlass)
    }

    func testPremiereMakesVioletTintsNeutralAndVioletAccentsRed() {
        // A violet surface and a lavender text colour become cool neutral greys of the same lightness
        // (no red or violet cast: blue at most a few percent above red).
        for hex in ["#2a2440", "#c5c0cf", "#211d2d", "#a9a7b6"] {
            let c = rgb(ThemePalette.premiere(hex: hex))
            XCTAssertEqual(c.r, c.g, accuracy: 0.02, hex); XCTAssertEqual(c.g, c.b, accuracy: 0.05, hex)
            XCTAssertGreaterThanOrEqual(c.b, c.r, hex)
        }
        // The lilac accent becomes red.
        for hex in ["#a98bff", "#8b6cf6", "#6c4cf0"] {
            let c = rgb(ThemePalette.premiere(hex: hex))
            XCTAssertGreaterThan(c.r, c.g * 2, hex); XCTAssertGreaterThan(c.r, c.b * 2, hex)
        }
        // Near-white lilac (highlighted text) becomes near-white, not pink.
        let light = rgb(ThemePalette.premiere(hex: "#cdbbff"))
        XCTAssertEqual(light.r, light.b, accuracy: 0.05); XCTAssertGreaterThan(light.r, 0.8)
    }

    func testPremiereLeavesOtherColoursAlone() {
        // Success green, warning gold, error red and other services' blues are unchanged.
        for hex in ["#7fe0b5", "#f5c26b", "#ff8a80", "#4285F4", "#01b4e4"] {
            let mine = rgb(ThemePalette.premiere(hex: hex)), original = rgb(Color(webHex: hex))
            XCTAssertEqual(mine.r, original.r, accuracy: 0.001, hex); XCTAssertEqual(mine.g, original.g, accuracy: 0.001, hex)
            XCTAssertEqual(mine.b, original.b, accuracy: 0.001, hex)
        }
        // Transparency is kept.
        XCTAssertEqual(ThemePalette.premiere(hex: "#2a244080").resolve(in: EnvironmentValues()).opacity, 0.5, accuracy: 0.01)
    }
}
