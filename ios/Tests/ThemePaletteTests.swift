import XCTest
import SwiftUI
import UIKit
@testable import TwilDiary

/// Premiere's palette and how it shows the colours typed into screens.
final class ThemePaletteTests: XCTestCase {
    private func rgb(_ color: Color) -> (r: Float, g: Float, b: Float) {
        let resolved = color.resolve(in: EnvironmentValues())
        return (resolved.red, resolved.green, resolved.blue)
    }

    func testTheOriginalThemesKeepTheirColours() {
        for theme in DiaryTheme.allCases where theme != .premiere && !theme.palette.native {
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

    // MARK: Native

    private func rgb(_ color: Color, _ scheme: ColorScheme) -> (r: Float, g: Float, b: Float, a: Float) {
        var environment = EnvironmentValues(); environment.colorScheme = scheme
        let resolved = color.resolve(in: environment)
        return (resolved.red, resolved.green, resolved.blue, resolved.opacity)
    }
    private func system(_ colour: UIColor, _ scheme: ColorScheme) -> (r: Float, g: Float, b: Float) {
        let resolved = Color(uiColor: colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))).resolve(in: EnvironmentValues())
        return (resolved.red, resolved.green, resolved.blue)
    }

    func testNativeFollowsTheSystem() {
        XCTAssertEqual(DiaryTheme.native.palette, .native)
        XCTAssertTrue(ThemePalette.native.native); XCTAssertTrue(ThemePalette.native.followsSystemAppearance)
        XCTAssertNil(DiaryTheme.native.colorScheme)
        for theme in DiaryTheme.allCases where theme != .native {
            XCTAssertEqual(theme.colorScheme, .dark, "\(theme) stays dark")
            XCTAssertFalse(theme.palette.native)
        }
        // Its page and cards are the grouped list's: grey page and white cards in light mode, black and dark grey in dark.
        let page = rgb(ThemePalette.native.canvas, .light), card = rgb(ThemePalette.native.card, .light)
        XCTAssertGreaterThan(page.r, 0.99); XCTAssertLessThan(card.r, page.r); XCTAssertGreaterThan(card.r, 0.9)
        XCTAssertLessThan(rgb(ThemePalette.native.canvas, .dark).r, 0.05)
    }

    func testNativeMapsTheDesignsGreysOntoLightAndDark() {
        // The page, a card and text, drawn for a dark screen.
        let page = ("#000000", dark: Float(0), light: Float(1)), card = ("#0e0e12", dark: Float(0.11), light: Float(0.949))
        for item in [page, card] {
            XCTAssertEqual(rgb(ThemePalette.native(hex: item.0), .dark).g, item.dark, accuracy: 0.02, item.0)
            XCTAssertEqual(rgb(ThemePalette.native(hex: item.0), .light).g, item.light, accuracy: 0.02, item.0)
        }
        // Text: light on dark, dark on light, and the order of emphasis is kept.
        let strong = rgb(ThemePalette.native(hex: "#f5f5f7"), .light), quiet = rgb(ThemePalette.native(hex: "#9a9aa8"), .light)
        XCTAssertLessThan(strong.g, 0.1); XCTAssertLessThan(strong.g, quiet.g); XCTAssertLessThan(quiet.g, 0.5)
        XCTAssertGreaterThan(rgb(ThemePalette.native(hex: "#f5f5f7"), .dark).g, 0.9)
        // The app's violet greys are greys too (no violet cast).
        let chip = rgb(ThemePalette.native(hex: "#2a2440"), .dark)
        XCTAssertEqual(chip.r, chip.g, accuracy: 0.02); XCTAssertEqual(chip.g, chip.b, accuracy: 0.05)
        // Alpha is kept.
        XCTAssertEqual(rgb(ThemePalette.native(hex: "#0e0e1280"), .dark).a, 0.5, accuracy: 0.01)
    }

    func testNativeMakesColoursTheSystemColours() {
        for scheme in [ColorScheme.light, .dark] {
            for (hex, colour) in [("#7fe0b5", UIColor.systemGreen), ("#f5c26b", .systemOrange), ("#ff8a80", .systemRed), ("#a98bff", .systemBlue), ("#cdbbff", .systemBlue)] {
                let mine = rgb(ThemePalette.native(hex: hex), scheme), wanted = system(colour, scheme)
                XCTAssertEqual(mine.r, wanted.r, accuracy: 0.02, "\(hex) \(scheme)"); XCTAssertEqual(mine.g, wanted.g, accuracy: 0.02, "\(hex) \(scheme)")
                XCTAssertEqual(mine.b, wanted.b, accuracy: 0.02, "\(hex) \(scheme)")
            }
        }
        // A dark tinted fill (a badge's ground) is its colour, faintly.
        let fill = rgb(ThemePalette.native(hex: "#1b2b25"), .dark)
        XCTAssertLessThan(fill.a, 0.3); XCTAssertGreaterThan(fill.g, fill.r)
    }

    func testNativeAppearanceChoice() {
        XCTAssertNil(DiaryTheme.native.colorScheme(native: .automatic))
        XCTAssertEqual(DiaryTheme.native.colorScheme(native: .light), .light)
        XCTAssertEqual(DiaryTheme.native.colorScheme(native: .dark), .dark)
        // The other themes stay dark whatever Native's choice is.
        for theme in DiaryTheme.allCases where theme != .native {
            for appearance in NativeAppearance.allCases { XCTAssertEqual(theme.colorScheme(native: appearance), .dark, "\(theme)") }
        }
    }

    // MARK: Design Lab

    func testEveryDesignLabPieceHasAnAreaAndTwoChoices() {
        for change in StudioChange.allCases {
            XCTAssertFalse(change.title.isEmpty, change.rawValue); XCTAssertFalse(change.section.isEmpty, change.rawValue)
            XCTAssertFalse(change.choices.off.isEmpty, change.rawValue); XCTAssertNotEqual(change.choices.off, change.choices.on, change.rawValue)
        }
        // Each area page lists something.
        for area in StudioChange.Area.pages { XCTAssertTrue(StudioChange.allCases.contains { $0.area == area }, area.rawValue) }
    }

    func testTheStudioThemeBecomesNativeWithTheStudioPreset() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "design-lab-migration-test"))
        defaults.removePersistentDomain(forName: "design-lab-migration-test")
        defaults.set("studio", forKey: "theme")
        defaults.set(["heroTrack", "personFacts"], forKey: "studio.lab.off")
        DesignLabMigration.run(defaults)
        XCTAssertEqual(defaults.string(forKey: "theme"), "native")
        let on = Set(defaults.stringArray(forKey: DesignLabKeys.on) ?? [])
        // A switch that was turned off stays off (the name's colour was part of "personFacts").
        XCTAssertFalse(on.contains("heroTrack")); XCTAssertFalse(on.contains("personName")); XCTAssertTrue(on.contains("homeHeader"))
        XCTAssertEqual(on.count, StudioChange.allCases.count - 2)
        XCTAssertEqual(defaults.string(forKey: DesignLabKeys.badge), DesignBadge.topLeft.rawValue)
        XCTAssertNil(defaults.stringArray(forKey: "studio.lab.off"))
        // Any other theme is left alone.
        defaults.set("twilight", forKey: "theme"); DesignLabMigration.run(defaults)
        XCTAssertEqual(defaults.string(forKey: "theme"), "twilight")
        defaults.removePersistentDomain(forName: "design-lab-migration-test")
    }

    @MainActor func testDesignLabPresets() {
        let lab = StudioLab.shared
        let saved = (on: lab.on, badge: lab.badge, corners: lab.corners, match: lab.match)
        defer {
            lab.apply(.original)
            for change in StudioChange.allCases where saved.on.contains(change.rawValue) { lab.set(change, on: true) }
            lab.setBadge(saved.badge); lab.setCorners(saved.corners); lab.setMatch(saved.match)
        }
        lab.apply(.studio)
        XCTAssertEqual(lab.preset, .studio); XCTAssertTrue(StudioChange.allCases.allSatisfy { lab.isOn($0) })
        XCTAssertEqual(lab.count(.home).on, lab.count(.home).of)
        lab.set(.heroTrack, on: false)
        XCTAssertEqual(lab.preset, .custom)
        lab.apply(.original)
        XCTAssertEqual(lab.preset, .original); XCTAssertFalse(StudioChange.allCases.contains { lab.isOn($0) })
        lab.setCorners(.rounder)
        XCTAssertEqual(lab.preset, .custom); XCTAssertEqual(Studio.corner(16), 22)
    }
}
