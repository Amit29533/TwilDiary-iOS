import SwiftUI
import Observation

/// Every colour a theme decides, beyond its accent: text, surfaces, chips, borders, the play
/// button and the screen's wash. The original five themes keep the colours the app always had
/// (their violet greys and lilac chips); Premiere (owner's request, inspired by today's streaming
/// apps: deep black, neutral greys, white play buttons, red used sparingly) has its own.
struct ThemePalette: Equatable, Sendable {
    // Text
    var primary: Color
    var secondary: Color
    var muted: Color
    var soft: Color
    // Surfaces and borders
    var card: Color
    var cardBorder: Color
    var round: Color
    var chip: Color
    var chipText: Color
    var dateChipBorder: Color
    var dateChipText: Color
    var shortcut: Color
    var shortcutBorder: Color
    // The accent gradient (today, progress, chosen days) and the ink drawn on the accent.
    var accentTop: Color
    var accentBottom: Color
    var accentInk: Color
    // The primary "play" button (Watch E5, Play): its fill, top to bottom, and its text.
    var watchTop: Color
    var watchBottom: Color
    var watchInk: Color
    /// A soft colour at the top of every screen, fading into black (nil: plain black).
    var screenWash: Color?
    /// The colours typed into screens (`Color(themed:)`) are shown as they are, or, in Premiere,
    /// with violet tints made neutral and violet accents made the theme's red.
    var neutralizesViolet: Bool

    /// The app's own colours (the original themes).
    static let classic = ThemePalette(
        primary: Color(webHex: "#f5f5f7"), secondary: Color(webHex: "#9a9aa8"), muted: Color(webHex: "#6e6e7c"), soft: Color(webHex: "#d8d4e6"),
        card: Color(webHex: "#0e0e12"), cardBorder: Color(webHex: "#23232b"), round: Color(webHex: "#17171d"),
        chip: Color(webHex: "#2a2440"), chipText: Color(webHex: "#cdbbff"),
        dateChipBorder: Color(webHex: "#26262e"), dateChipText: Color(webHex: "#b4b3c2"),
        shortcut: Color(webHex: "#14111f"), shortcutBorder: Color(webHex: "#2a2440"),
        accentTop: Color(webHex: "#cdbbff"), accentBottom: Color(webHex: "#a98bff"), accentInk: Color(webHex: "#1a1030"),
        watchTop: Color(webHex: "#cdbbff"), watchBottom: Color(webHex: "#a98bff"), watchInk: Color(webHex: "#1a1030"),
        screenWash: nil, neutralizesViolet: false)

    /// Premiere: a streaming app's palette. Black and neutral greys, white type, white play
    /// buttons with black text, frosted grey chips, and red only where something is chosen or
    /// in progress; a muted grey-violet wash at the top of each screen, as their 2025 redesign has.
    static let premiere = ThemePalette(
        primary: Color(webHex: "#ffffff"), secondary: Color(webHex: "#b3b3b3"), muted: Color(webHex: "#808080"), soft: Color(webHex: "#e5e5e5"),
        card: Color(webHex: "#141414"), cardBorder: Color(webHex: "#2a2a2a"), round: Color(webHex: "#1f1f1f"),
        chip: Color(webHex: "#3a3a3c"), chipText: Color(webHex: "#ffffff"),
        dateChipBorder: Color(webHex: "#3a3a3a"), dateChipText: Color(webHex: "#d6d6d6"),
        shortcut: Color(webHex: "#181818"), shortcutBorder: Color(webHex: "#333333"),
        accentTop: Color(webHex: "#ff3b45"), accentBottom: Color(webHex: "#e50914"), accentInk: Color(webHex: "#ffffff"),
        watchTop: Color(webHex: "#ffffff"), watchBottom: Color(webHex: "#ececec"), watchInk: Color(webHex: "#000000"),
        screenWash: Color(webHex: "#2c2733"), neutralizesViolet: true)

    /// Premiere's red, for colours that were the violet accent.
    static let premiereRedHue = 357.0 / 360

    /// A typed colour as Premiere shows it: a violet or purple one (hue 235°–330°) becomes a
    /// neutral grey of the same lightness, unless it's a strong accent (saturated, not near
    /// white), which becomes a red of matching lightness. Every other colour (greens, golds,
    /// error reds, other services' blues) is left alone. Alpha is kept.
    static func premiere(hex: String) -> Color {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = UInt64(raw, radix: 16), raw.count == 6 || raw.count == 8 else { return Color(webHex: hex) }
        let rgb = raw.count == 8 ? value >> 8 : value
        let alpha = raw.count == 8 ? Double(value & 255) / 255 : 1
        let r = Double((rgb >> 16) & 255) / 255, g = Double((rgb >> 8) & 255) / 255, b = Double(rgb & 255) / 255
        let high = max(r, g, b), low = min(r, g, b), lightness = (high + low) / 2, delta = high - low
        guard delta > 0.0001 else { return Color(webHex: hex) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch high {
        case r: hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        case g: hue = (b - r) / delta + 2
        default: hue = (r - g) / delta + 4
        }
        hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
        guard hue >= 235, hue <= 330 else { return Color(webHex: hex) }
        if saturation >= 0.45, lightness <= 0.85, lightness >= 0.25 {
            return Color(hue: premiereRedHue, saturation: 0.86, brightness: 0.62 + (lightness - 0.25) * 0.55, opacity: alpha)
        }
        return Color(white: lightness, opacity: alpha)
    }
}

/// The palette on screen. Views read it through `HomeStyle`, `WatchStyle` and `Color(themed:)`,
/// so a theme change redraws them where they are (no screen is reset).
@Observable final class ThemeStore: @unchecked Sendable {
    static let shared = ThemeStore()
    private(set) var palette: ThemePalette
    @ObservationIgnored private var converted: [String: Color] = [:]
    @ObservationIgnored private let lock = NSLock()
    init() {
        palette = (DiaryTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .twilight).palette
    }
    static var current: ThemePalette { shared.palette }
    func apply(_ theme: DiaryTheme) {
        let next = theme.palette
        guard next != palette else { return }
        lock.lock(); converted.removeAll(); lock.unlock()
        palette = next
    }
    /// A typed colour in the current theme (kept, so each is worked out once).
    func color(_ hex: String) -> Color {
        guard palette.neutralizesViolet else { return Color(webHex: hex) }
        lock.lock(); defer { lock.unlock() }
        if let known = converted[hex] { return known }
        let made = ThemePalette.premiere(hex: hex)
        converted[hex] = made
        return made
    }
}

extension Color {
    /// A colour from the design, as the current theme shows it (see `ThemePalette.premiere(hex:)`).
    init(themed hex: String) { self = ThemeStore.shared.color(hex) }
}
