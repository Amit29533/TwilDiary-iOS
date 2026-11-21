import SwiftUI
import AetherEngine

/// Settings → JellySpace → Subtitles, beyond the size, colour, box and height JellyPrefs already
/// keeps: the font and its weight, the text's opacity, the outline and shadow, the box's opacity,
/// moving up with the controls; how styled (ASS) subtitles are drawn; which subtitles a video starts
/// with; and the delay's step and memory.
enum JellySubtitlePrefs {
    static let fontKey = "jellyspace.subtitle.font"
    static let boldKey = "jellyspace.subtitle.bold"
    static let opacityKey = "jellyspace.subtitle.opacity"
    static let outlineKey = "jellyspace.subtitle.outline"
    static let outlineColorKey = "jellyspace.subtitle.outlineColor"
    static let shadowKey = "jellyspace.subtitle.shadow"
    static let boxOpacityKey = "jellyspace.subtitle.boxOpacity"
    static let liftKey = "jellyspace.subtitle.lift"
    /// "full" (drawn as made) or "mine" (as plain text, in the look set here).
    static let styledKey = "jellyspace.subtitle.styled"
    static let styledSizeKey = "jellyspace.subtitle.styledSize"
    /// ISO 639-2 codes ("" for the file's own choice).
    static let languageKey = "jellyspace.subtitle.language"
    static let secondLanguageKey = "jellyspace.subtitle.language2"
    /// "always", "forced" (only forced subtitles, for foreign lines) or "off".
    static let showKey = "jellyspace.subtitle.show"
    /// "avoid" or "prefer" subtitles for the hearing-impaired (SDH, with sounds described).
    static let sdhKey = "jellyspace.subtitle.sdh"
    static let rememberDelayKey = "jellyspace.subtitle.rememberDelay"
    static let delayStepKey = "jellyspace.subtitle.delayStep"
}

/// The choices the Subtitles page offers.
enum JellySubtitleChoices {
    struct Swatch: Sendable {
        let name: String
        let key: String
        let hex: String
        var color: Color {
            let value = UInt32(hex, radix: 16) ?? 0xFFFFFF
            return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }
    }
    static let colors: [Swatch] = [
        Swatch(name: "White", key: "white", hex: "FFFFFF"), Swatch(name: "Yellow", key: "yellow", hex: "FFE04D"),
        Swatch(name: "Green", key: "green", hex: "7CE0A0"), Swatch(name: "Cyan", key: "cyan", hex: "7FD3F5"),
        Swatch(name: "Pink", key: "pink", hex: "F5A3C7"),
    ]
    static let outlineColors: [Swatch] = [
        Swatch(name: "Black", key: "black", hex: "000000"), Swatch(name: "Grey", key: "grey", hex: "555555"),
        Swatch(name: "Navy", key: "navy", hex: "1D3A8A"),
    ]
    static let fonts: [(String, String)] = [("System", "system"), ("Rounded", "rounded"), ("Serif", "serif"), ("Monospaced", "mono")]
    static let outlines = ["None", "Thin", "Normal", "Thick", "Heavy"]
    static let shadows: [(String, Int)] = [("Off", 0), ("Soft", 1), ("Hard", 2)]
    static let show: [(String, String)] = [("Always", "always"), ("Forced only", "forced"), ("Off", "off")]
    static let sdh: [(String, String)] = [("Avoid", "avoid"), ("Prefer", "prefer")]
    static let styled: [(String, String)] = [("As made", "full"), ("Mine", "mine")]
    static let delaySteps: [(String, Double)] = [("0.05 s", 0.05), ("0.1 s", 0.1), ("0.5 s", 0.5)]
    /// The languages to pick from ("" first: whatever the file marks as its default).
    @MainActor static var languages: [(String, String)] { [("File's choice", "")] + JellyPlayerView.subtitleLanguages }
}

/// How plain subtitles look (and styled ones, where set to "Mine"), read once from Settings; the
/// player's own subtitles and mpv's are both drawn from it.
struct JellySubtitleLook: Equatable, Sendable {
    var size = 1.0
    var font = "system"
    var bold = false
    var color = "white"
    var opacity = 1.0
    var outline = 2
    var outlineColor = "black"
    var shadow = 1
    var box = false
    var boxOpacity = 0.6
    var raise = 0.0
    var lift = true
    var styled = "full"
    var styledSize = true

    static var current: JellySubtitleLook {
        let defaults = UserDefaults.standard
        var look = JellySubtitleLook()
        func read<Value>(_ key: String, _ fallback: Value) -> Value { defaults.object(forKey: key) as? Value ?? fallback }
        look.size = read(JellyPrefs.subtitleSizeKey, look.size)
        look.color = read(JellyPrefs.subtitleColorKey, look.color)
        look.box = read(JellyPrefs.subtitleBoxKey, look.box)
        look.raise = read(JellyPrefs.subtitleRaiseKey, look.raise)
        look.font = read(JellySubtitlePrefs.fontKey, look.font)
        look.bold = read(JellySubtitlePrefs.boldKey, look.bold)
        look.opacity = read(JellySubtitlePrefs.opacityKey, look.opacity)
        look.outline = read(JellySubtitlePrefs.outlineKey, look.outline)
        look.outlineColor = read(JellySubtitlePrefs.outlineColorKey, look.outlineColor)
        look.shadow = read(JellySubtitlePrefs.shadowKey, look.shadow)
        look.boxOpacity = read(JellySubtitlePrefs.boxOpacityKey, look.boxOpacity)
        look.lift = read(JellySubtitlePrefs.liftKey, look.lift)
        look.styled = read(JellySubtitlePrefs.styledKey, look.styled)
        look.styledSize = read(JellySubtitlePrefs.styledSizeKey, look.styledSize)
        return look
    }

    private var textSwatch: JellySubtitleChoices.Swatch { JellySubtitleChoices.colors.first { $0.key == color } ?? JellySubtitleChoices.colors[0] }
    private var edgeSwatch: JellySubtitleChoices.Swatch {
        JellySubtitleChoices.outlineColors.first { $0.key == outlineColor } ?? JellySubtitleChoices.outlineColors[0]
    }
    var textColor: Color { textSwatch.color.opacity(opacity) }
    var edgeColor: Color { edgeSwatch.color.opacity(opacity) }

    /// The text's font at a size in points.
    func swiftFont(_ points: CGFloat) -> Font {
        let design: Font.Design = switch font {
        case "rounded": .rounded
        case "serif": .serif
        case "mono": .monospaced
        default: .default
        }
        return .system(size: points, weight: bold ? .bold : .semibold, design: design)
    }
    /// The outline's width for text of this size (none, thin, normal, thick, heavy).
    func outlineWidth(_ points: CGFloat) -> CGFloat {
        let shares: [CGFloat] = [0, 0.04, 0.07, 0.1, 0.14]
        return shares[min(max(outline, 0), shares.count - 1)] * points
    }

    /// The same look in mpv's terms (its sizes are on a 720-line screen; colours are #AARRGGBB).
    var mpvSettings: [(String, String)] {
        let fonts = ["system": "Helvetica Neue", "rounded": "Avenir Next", "serif": "Georgia", "mono": "Menlo"]
        let borders = ["0", "1.5", "2.5", "3.5", "5"]
        let shadows = ["0", "1.5", "2.5"]
        let alpha = String(format: "%02X", Int((opacity * 255).rounded()))
        let boxAlpha = String(format: "%02X", Int((boxOpacity * 255).rounded()))
        return [
            ("sub-scale", String(size)), ("sub-font", fonts[font] ?? "Helvetica Neue"), ("sub-bold", bold ? "yes" : "no"),
            ("sub-color", "#" + alpha + textSwatch.hex), ("sub-border-color", "#" + alpha + edgeSwatch.hex),
            ("sub-border-size", borders[min(max(outline, 0), borders.count - 1)]),
            ("sub-shadow-offset", shadows[min(max(shadow, 0), shadows.count - 1)]),
            ("sub-shadow-color", shadow == 2 ? "#C0000000" : "#80000000"),
            ("sub-border-style", box ? "background-box" : "outline-and-shadow"), ("sub-back-color", "#" + boxAlpha + "000000"),
            ("sub-pos", String(Int((100 - raise * 100).rounded()))),
            // Styled subtitles: as made (sized by the slider too, if set), or in this look.
            ("sub-ass-override", styled == "mine" ? "force" : (styledSize ? "scale" : "no")),
        ]
    }
}

/// A plain subtitle as the player draws it (and Settings previews it): the text in its font, colour
/// and opacity, a crisp outline round it (the text in the outline colour, drawn eight ways round
/// underneath), a soft or hard shadow, or a box behind it instead.
struct JellyPlainSubtitle: View {
    let text: String
    let look: JellySubtitleLook
    let points: CGFloat

    var body: some View {
        let width = look.box ? 0 : look.outlineWidth(points)
        let hard = look.shadow == 2
        let label = Text(text).font(look.swiftFont(points))
        label.foregroundStyle(look.textColor)
            .background { if width > 0.2 { Self.outline(label, color: look.edgeColor, width: width) } }
            .shadow(color: .black.opacity(look.box || look.shadow == 0 ? 0 : (hard ? 0.75 : 0.6) * look.opacity),
                    radius: hard ? 0 : max(1.5, points * 0.06), x: hard ? max(1, points * 0.06) : 0, y: hard ? max(1, points * 0.06) : 1)
            .multilineTextAlignment(.center)
            .padding(.horizontal, look.box ? 12 : 0).padding(.vertical, look.box ? 5 : 0)
            .background {
                if look.box { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(look.boxOpacity)) }
            }
    }

    private static func outline(_ label: Text, color: Color, width: CGFloat) -> some View {
        ZStack {
            ForEach(0..<8, id: \.self) { step in
                let angle = Double(step) * .pi / 4
                label.foregroundStyle(color).multilineTextAlignment(.center).offset(x: cos(angle) * width, y: sin(angle) * width)
            }
        }
    }
}

/// Which subtitles a video starts with, from Settings: in your language (then your second
/// choice), with or without SDH as you prefer, never a forced-only track for a full one; or only
/// forced subtitles; or none. Without a language set, the file's default (else its forced) track.
enum JellySubtitlePick {
    static func choose(_ tracks: [TrackInfo]) -> TrackInfo? {
        let defaults = UserDefaults.standard
        let show = defaults.string(forKey: JellySubtitlePrefs.showKey) ?? "always"
        let first = defaults.string(forKey: JellySubtitlePrefs.languageKey) ?? ""
        let second = defaults.string(forKey: JellySubtitlePrefs.secondLanguageKey) ?? ""
        let preferSDH = defaults.string(forKey: JellySubtitlePrefs.sdhKey) == "prefer"
        let languages = [first, second].filter { !$0.isEmpty }
        switch show {
        case "off":
            return nil
        case "forced":
            let forced = tracks.filter(\.isForced)
            return languages.lazy.compactMap { language in forced.first { same($0.language, language) } }.first ?? forced.first
        default:
            for language in languages {
                let full = tracks.filter { !$0.isForced && same($0.language, language) }
                if let track = full.first(where: { isSDH($0) == preferSDH }) ?? full.first { return track }
            }
            // None in your languages (or none set): the file's own choice.
            return tracks.first(where: \.isDefault) ?? tracks.first(where: \.isForced)
        }
    }

    /// Subtitles for the hearing-impaired, as files name them.
    static func isSDH(_ track: TrackInfo) -> Bool {
        let name = track.name.lowercased()
        return name.contains("sdh") || name.contains("hearing") || name.contains("[cc]") || name.contains("(cc)") || name == "cc"
    }

    /// Two language codes for the same language ("en", "eng", "en-US"; "fre"/"fra", "ger"/"deu").
    static func same(_ code: String?, _ wanted: String) -> Bool {
        guard let code, !code.isEmpty, !wanted.isEmpty else { return false }
        func base(_ text: String) -> String {
            let lower = text.lowercased().split(separator: "-").first.map(String.init) ?? text.lowercased()
            let bibliographic = ["fre": "fra", "ger": "deu", "chi": "zho", "dut": "nld", "cze": "ces", "gre": "ell", "per": "fas", "rum": "ron"]
            let terminology = bibliographic[lower] ?? lower
            return Locale.Language(identifier: terminology).languageCode?.identifier(.alpha2) ?? terminology
        }
        return base(code) == base(wanted)
    }
}
