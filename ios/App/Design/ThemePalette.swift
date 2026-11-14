import SwiftUI
import UIKit
import Observation

/// Every colour a theme decides, beyond its accent: text, surfaces, chips, borders, the play
/// button and the screen's wash. The original five themes keep the colours the app always had
/// (their violet greys and lilac chips); Premiere (owner's request, inspired by today's streaming
/// apps: near-black, neutral greys, white play buttons, glass pills, red used sparingly) has its own.
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
    /// The text on a chip filled with `chipText` (a chosen chip): dark on lilac, black on Premiere's white.
    var chipInk: Color
    // The primary "play" button (Watch E5, Play): its fill, top to bottom, and its text.
    var watchTop: Color
    var watchBottom: Color
    var watchInk: Color
    /// The screen's ground.
    var canvas: Color
    /// The artwork of a show you're watching, softly behind every screen (pre-blurred, no live
    /// blur): what the glass picks up, as a streaming app's screens take the colour of their art.
    var ambientArtwork: Bool
    /// Pills, chips and small controls as Liquid Glass instead of solid fills.
    var usesGlass: Bool
    /// The colours typed into screens (`Color(themed:)`) are shown as they are, or, in Premiere,
    /// with violet tints made neutral and violet accents made the theme's red.
    var neutralizesViolet: Bool
    /// Light or dark as the iPhone is set (Native); every other theme is always dark.
    var followsSystemAppearance = false
    /// Native: the app's own controls give way to the system's (switches, grouped settings with
    /// coloured tiles, Liquid Glass buttons, system colours, haptics on choices).
    var native = false

    /// The app's own colours (the original themes).
    static let classic = ThemePalette(
        primary: Color(webHex: "#f5f5f7"), secondary: Color(webHex: "#9a9aa8"), muted: Color(webHex: "#6e6e7c"), soft: Color(webHex: "#d8d4e6"),
        card: Color(webHex: "#0e0e12"), cardBorder: Color(webHex: "#23232b"), round: Color(webHex: "#17171d"),
        chip: Color(webHex: "#2a2440"), chipText: Color(webHex: "#cdbbff"),
        dateChipBorder: Color(webHex: "#26262e"), dateChipText: Color(webHex: "#b4b3c2"),
        shortcut: Color(webHex: "#14111f"), shortcutBorder: Color(webHex: "#2a2440"),
        accentTop: Color(webHex: "#cdbbff"), accentBottom: Color(webHex: "#a98bff"), accentInk: Color(webHex: "#1a1030"), chipInk: Color(webHex: "#1a1030"),
        watchTop: Color(webHex: "#cdbbff"), watchBottom: Color(webHex: "#a98bff"), watchInk: Color(webHex: "#1a1030"),
        canvas: .black, ambientArtwork: false, usesGlass: false, neutralizesViolet: false)

    /// Premiere: a streaming app's palette, from the owner's references (a 2024 Netflix UI kit
    /// and Radiant Studio's Netflix concepts: ground #080605, text #DDDFE7, greys #B9BBC3 and
    /// #95979D). Near-black, cool neutral greys, white play buttons with black text, Liquid Glass
    /// pills, red only where something is chosen or under way; the colour on a screen comes from
    /// its artwork behind the glass, never a fixed tint.
    static let premiere = ThemePalette(
        primary: Color(webHex: "#f4f5f8"), secondary: Color(webHex: "#95979d"), muted: Color(webHex: "#6e7076"), soft: Color(webHex: "#dddfe7"),
        card: Color(webHex: "#151517"), cardBorder: Color(webHex: "#26272b"), round: Color(webHex: "#1e1f22"),
        chip: Color(webHex: "#2c2d31"), chipText: Color(webHex: "#f4f5f8"),
        dateChipBorder: Color(webHex: "#34363b"), dateChipText: Color(webHex: "#b9bbc3"),
        shortcut: Color(webHex: "#18191c"), shortcutBorder: Color(webHex: "#2e3034"),
        accentTop: Color(webHex: "#ff3b45"), accentBottom: Color(webHex: "#e50914"), accentInk: Color(webHex: "#ffffff"), chipInk: Color(webHex: "#000000"),
        watchTop: Color(webHex: "#ffffff"), watchBottom: Color(webHex: "#ececec"), watchInk: Color(webHex: "#000000"),
        canvas: Color(webHex: "#080605"), ambientArtwork: true, usesGlass: true, neutralizesViolet: true)

    /// Native (owner's request: "a new app made by Apple"): no colour of its own. Text, surfaces and
    /// fills are iOS's semantic colours, so the app follows the iPhone's light or dark setting;
    /// the accent is the system blue; controls are Liquid Glass. Colours typed into screens are
    /// mapped onto the same system roles (`ThemePalette.native(hex:)`).
    static let native = ThemePalette(
        primary: Color(uiColor: .label), secondary: Color(uiColor: .secondaryLabel), muted: Color(uiColor: .tertiaryLabel),
        soft: adaptive(dark: 0.9, light: 0.22),
        card: Color(uiColor: .secondarySystemBackground), cardBorder: Color(uiColor: .separator).opacity(0.55),
        round: Color(uiColor: .tertiarySystemFill),
        chip: Color(uiColor: .systemBlue).opacity(0.15), chipText: Color(uiColor: .systemBlue),
        dateChipBorder: Color(uiColor: .separator), dateChipText: Color(uiColor: .secondaryLabel),
        shortcut: Color(uiColor: .secondarySystemBackground), shortcutBorder: .clear,
        accentTop: Color(uiColor: .systemBlue), accentBottom: Color(uiColor: .systemBlue), accentInk: .white, chipInk: .white,
        watchTop: Color(uiColor: .systemBlue), watchBottom: Color(uiColor: .systemBlue), watchInk: .white,
        canvas: Color(uiColor: .systemBackground), ambientArtwork: false, usesGlass: true, neutralizesViolet: false,
        followsSystemAppearance: true, native: true)

    /// A cool neutral grey of lightness `dark` in dark mode and `light` in light mode.
    static func adaptive(dark: Double, light: Double, opacity: Double = 1) -> Color {
        Color(uiColor: UIColor { traits in
            let l = traits.userInterfaceStyle == .light ? light : dark
            return UIColor(red: l * 0.985, green: l * 0.99, blue: min(1, l * 1.03), alpha: opacity)
        })
    }

    /// A typed colour as Native shows it. The design's colours were drawn for a dark screen; here
    /// each takes the system role it plays, in light and dark:
    /// - greys and the app's violet greys by lightness: the page, cards, raised fills, separators,
    ///   then text from primary down to tertiary (in light mode the order of text flips to dark on light,
    ///   and cards turn white on the grey page, as in Settings);
    /// - saturated colours become the system colour of their hue (green, yellow, red, pink…),
    ///   a dark tinted fill becomes that colour at low opacity, and the violet accent becomes the system blue.
    /// Alpha is kept.
    static func native(hex: String) -> Color {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = UInt64(raw, radix: 16), raw.count == 6 || raw.count == 8 else { return Color(webHex: hex) }
        let rgb = raw.count == 8 ? value >> 8 : value
        let alpha = raw.count == 8 ? Double(value & 255) / 255 : 1
        let r = Double((rgb >> 16) & 255) / 255, g = Double((rgb >> 8) & 255) / 255, b = Double(rgb & 255) / 255
        let high = max(r, g, b), low = min(r, g, b), lightness = (high + low) / 2, delta = high - low
        let saturation = delta < 0.0001 ? 0 : delta / (1 - abs(2 * lightness - 1))
        var hue = 0.0
        if delta >= 0.0001 {
            switch high {
            case r: hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            case g: hue = (b - r) / delta + 2
            default: hue = (r - g) / delta + 4
            }
            hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
        }
        let violet = hue >= 235 && hue <= 290
        let neutral = saturation < 0.22 || lightness > 0.9 || (violet && saturation < 0.45) || lightness < 0.06
        if neutral {
            let (dark, light) = nativeGrey(lightness)
            return adaptive(dark: dark, light: light, opacity: alpha)
        }
        let system: UIColor = switch hue {
        case ..<12, 345...: .systemRed
        case ..<42: .systemOrange
        case ..<62: .systemYellow
        case ..<165: .systemGreen
        case ..<182: .systemMint
        case ..<200: .systemCyan
        case ..<235: .systemBlue
        case ..<290: .systemBlue
        default: .systemPink
        }
        // A dark tinted fill (a badge's ground) is the colour faintly, as iOS tints a fill.
        return Color(uiColor: system).opacity(lightness < 0.3 ? 0.18 * alpha : alpha)
    }

    /// A grey's lightness on a dark screen → (dark mode, light mode) lightness in Native.
    static func nativeGrey(_ l: Double) -> (Double, Double) {
        switch l {
        case ..<0.05: (0, 1)             // the page (#0a0a0e, the title page's ground, included): black or white
        case ..<0.075: (0.11, 0.949)     // cards: raised grey on the page, as Apple Music's
        case ..<0.11: (0.15, 0.925)      // a raised fill inside a card
        case ..<0.2: (0.19, 0.895)       // chips, pills, dividers
        case ..<0.36: (0.27, 0.8)        // strong fills, outlines
        default: (l, 0.62 * (1 - (l - 0.36) / 0.64))   // text, lightest to darkest
        }
    }

    /// Premiere's red, for colours that were the violet accent.
    static let premiereRedHue = 357.0 / 360

    /// A typed colour as Premiere shows it: a violet one (hue 235°–290°, where the app's lilacs are) becomes a
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
        // Pinks and magentas (Animation's chip, Rose's swatch) aren't the app's violet: left alone.
        guard hue >= 235, hue <= 290 else { return Color(webHex: hex) }
        if saturation >= 0.45, lightness <= 0.85, lightness >= 0.25 {
            return Color(hue: premiereRedHue, saturation: 0.86, brightness: 0.62 + (lightness - 0.25) * 0.55, opacity: alpha)
        }
        // A cool neutral (the references' greys lean faintly blue, never violet).
        return Color(red: lightness * 0.985, green: lightness * 0.99, blue: min(1, lightness * 1.03), opacity: alpha)
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
    /// The chosen theme's accent (for views without the theme at hand).
    static var accent: Color { (DiaryTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .twilight).accent }
    func apply(_ theme: DiaryTheme) {
        let next = theme.palette
        guard next != palette else { return }
        lock.lock(); converted.removeAll(); lock.unlock()
        palette = next
    }
    /// A typed colour in the current theme (kept, so each is worked out once).
    func color(_ hex: String) -> Color {
        guard palette.neutralizesViolet || palette.native else { return Color(webHex: hex) }
        lock.lock(); defer { lock.unlock() }
        if let known = converted[hex] { return known }
        let made = palette.native ? ThemePalette.native(hex: hex) : ThemePalette.premiere(hex: hex)
        converted[hex] = made
        return made
    }
}

extension Color {
    /// A colour from the design, as the current theme shows it (see `ThemePalette.premiere(hex:)`).
    init(themed hex: String) { self = ThemeStore.shared.color(hex) }
}

extension View {
    /// A pill's surface (filters, chips, small buttons): the theme's fill with its hairline in the
    /// original themes; Liquid Glass in Premiere. A chosen pill keeps its solid `chosen` fill.
    func pillSurface(_ fill: Color = HomeStyle.round, chosen: Color? = nil, border: Color? = HomeStyle.dateChipBorder) -> some View {
        modifier(PillSurface(fill: fill, chosen: chosen, border: border))
    }
}

private struct PillSurface: ViewModifier {
    let fill: Color
    let chosen: Color?
    let border: Color?
    func body(content: Content) -> some View {
        if let chosen {
            content.background(chosen, in: Capsule())
        } else if ThemeStore.current.usesGlass {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(fill, in: Capsule())
                .overlay { if let border { Capsule().strokeBorder(border, lineWidth: HomeStyle.hairline) } }
        }
    }
}
