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
    /// Picture subtitles (PGS, DVD): "full" (the pictures) or "mine" (read on the phone, as text in
    /// this look; a picture that couldn't be read surely stays a picture).
    static let picturesKey = "jellyspace.subtitle.pictures"
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

/// Settings → JellySpace → Preferences, beyond the subtitle languages (JellySubtitlePrefs), the
/// aspect ratio (JellyPrefs.fillKey) and remembering tracks (JellyPrefs.rememberTracksKey).
enum JellyPreferences {
    /// ISO 639-2 codes ("" for the file's own choice).
    static let audioLanguageKey = "jellyspace.audio.language"
    static let audioSecondKey = "jellyspace.audio.language2"
    /// Audio and subtitles remembered for each show (its episodes carry them), not only overall.
    static let perShowKey = "jellyspace.remember.perShow"
    /// The aspect ratio kept for each show (a pinch to Fill stays for its episodes).
    static let fillPerShowKey = "jellyspace.fill.perShow"

    static var perShow: Bool { UserDefaults.standard.object(forKey: perShowKey) as? Bool ?? true }
    static var fillPerShow: Bool { UserDefaults.standard.bool(forKey: fillPerShowKey) }
    static func fillKey(show: String) -> String { "jellyspace.fill." + show }
    /// Your default audio languages, first then second (none set: empty).
    static var audioLanguages: [String] {
        let defaults = UserDefaults.standard
        // A second choice only behind a first: with File's choice the file decides (the second, kept
        // but hidden in Settings, no longer applies).
        guard let first = defaults.string(forKey: audioLanguageKey), !first.isEmpty else { return [] }
        return [first, defaults.string(forKey: audioSecondKey) ?? ""].filter { !$0.isEmpty }
    }
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
    var pictures = "full"

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
        look.pictures = read(JellySubtitlePrefs.picturesKey, look.pictures)
        return look
    }

    private var textSwatch: JellySubtitleChoices.Swatch { JellySubtitleChoices.colors.first { $0.key == color } ?? JellySubtitleChoices.colors[0] }
    private var edgeSwatch: JellySubtitleChoices.Swatch {
        JellySubtitleChoices.outlineColors.first { $0.key == outlineColor } ?? JellySubtitleChoices.outlineColors[0]
    }
    var textColor: Color { textSwatch.color.opacity(opacity) }
    var edgeColor: Color { edgeSwatch.color.opacity(opacity) }

    /// Plain subtitles' size on a screen this tall, as mpv sizes them: its default line height (38 on a
    /// 720-line screen) with the letters fitted in it (the system font's line is 1.19 of its size),
    /// times the size setting. The same setting is then the same size on both players.
    static func points(screenHeight: CGFloat, size: Double) -> CGFloat {
        screenHeight * 38 / 720 / 1.19 * CGFloat(size)
    }
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
        let fonts = ["system": "Noto Sans", "rounded": "Avenir Next", "serif": "Georgia", "mono": "Menlo"]
        let borders = ["0", "1.5", "2.5", "3.5", "5"]
        let shadows = ["0", "1.5", "2.5"]
        let alpha = String(format: "%02X", Int((opacity * 255).rounded()))
        let boxAlpha = String(format: "%02X", Int((boxOpacity * 255).rounded()))
        return [
            ("sub-font-size", "38"), ("sub-scale-by-window", "yes"), ("sub-scale", String(size)), ("sub-font", fonts[font] ?? "Noto Sans"), ("sub-bold", bold ? "yes" : "no"),
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
    /// The text with its own italics, bold and colours (nil: none of its own).
    var styled: AttributedString? = nil

    var body: some View {
        let width = look.box ? 0 : look.outlineWidth(points)
        let hard = look.shadow == 2
        let label = (styled.map { Text($0) } ?? Text(text)).font(look.swiftFont(points))
        // The outline is all in its own colour, whatever the letters' are.
        let edge = (styled.map { Text(Self.uncoloured($0)) } ?? Text(text)).font(look.swiftFont(points))
        label.foregroundStyle(look.textColor)
            .background { if width > 0.2 { Self.outline(edge, color: look.edgeColor, width: width) } }
            .shadow(color: .black.opacity(look.box || look.shadow == 0 ? 0 : (hard ? 0.75 : 0.6) * look.opacity),
                    radius: hard ? 0 : max(1.5, points * 0.06), x: hard ? max(1, points * 0.06) : 0, y: hard ? max(1, points * 0.06) : 1)
            .multilineTextAlignment(.center)
            .padding(.horizontal, look.box ? 12 : 0).padding(.vertical, look.box ? 5 : 0)
            .background {
                if look.box { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(look.boxOpacity)) }
            }
    }

    private static func uncoloured(_ text: AttributedString) -> AttributedString {
        var text = text
        text.foregroundColor = Color?.none
        return text
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

/// Plain subtitle lines: their text, their own styling, and where the file puts them.
enum JellyPlainLines {
    /// ASS override tags ({\i1}) out, its line breaks (\N) in.
    static func plain(_ text: String) -> String {
        // A styled (ASS) event comes with its fields first: ReadOrder,Layer,Style,Name,MarginL,
        // MarginR,MarginV,Effect (or a "Dialogue:" line's Layer,Start,End,…); only the text is shown.
        text.replacingOccurrences(of: #"^\d+,-?\d+,[^,]*,[^,]*,-?\d+,-?\d+,-?\d+,[^,]*,"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^Dialogue:\s*-?\d+,[^,]*,[^,]*,[^,]*,[^,]*,-?\d+,-?\d+,-?\d+,[^,]*,"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A line showing, and where the file asks for it (numpad: 1 to 3 bottom, 4 to 6 middle, 7 to 9 top; left,
    /// centre, right). Nearly all are at the bottom; SRT's {\an8} puts one at the top, clear of what's
    /// written on the picture.
    struct Line {
        let text: String
        var alignment = 2
        /// With its own italics, bold and colours; nil when it has none.
        var styled: AttributedString? = nil
    }
    /// The lines at one place on the screen.
    struct Block {
        let alignment: Int
        let text: String
        let styled: AttributedString?
    }
    /// The lines showing (picture cues left out; translated ones in their translation).
    static func lines(_ cues: [SubtitleCue], replace: [String: String], look: JellySubtitleLook, points: CGFloat) -> [Line] {
        cues.compactMap { cue -> Line? in
            if case .image(let picture) = cue.body {
                // A picture subtitle as text in your look, once it's read surely enough (else the
                // picture shows); at the top if the disc put it in the picture's top part.
                guard let text = readText(cue, look: look) else { return nil }
                return Line(text: replace[text] ?? text, alignment: picture.position.midY < 0.4 ? 8 : 2)
            }
            guard let text = cue.text.map(plain), !text.isEmpty else { return nil }
            let place = cue.placement?.alignment ?? 2
            if let translated = replace[text] { return Line(text: translated, alignment: place) }
            return Line(text: text, alignment: place, styled: styled(cue, look: look, points: points))
        }
    }
    /// A picture subtitle's words (PGS, DVD), read on the phone by AetherEngine, when picture
    /// subtitles are set to Mine and every line was read with good confidence; nil keeps the picture.
    static func readText(_ cue: SubtitleCue, look: JellySubtitleLook) -> String? {
        guard look.pictures == "mine", let read = cue.recognizedText, !read.lines.isEmpty,
              read.lines.allSatisfy({ $0.confidence >= 0.5 }) else { return nil }
        let text = read.lines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    /// The lines by place.
    static func blocks(_ lines: [Line]) -> [Block] {
        let places = Dictionary(grouping: lines) { (1...9).contains($0.alignment) ? $0.alignment : 2 }
        return places.keys.sorted().map { place in
            let here = places[place] ?? []
            var joined: AttributedString?
            if here.contains(where: { $0.styled != nil }) {
                var all = AttributedString()
                for (index, line) in here.enumerated() {
                    if index > 0 { all += AttributedString("\n") }
                    all += line.styled ?? AttributedString(line.text)
                }
                joined = all
            }
            return Block(alignment: place, text: here.map(\.text).joined(separator: "\n"), styled: joined)
        }
    }
    /// A line's own italics, bold, underlines and colours as the file marks them (SRT and WebVTT tags); nil
    /// when it has none. AetherEngine hands them over with the line, and they were dropped: mpv always
    /// showed them.
    static func styled(_ cue: SubtitleCue, look: JellySubtitleLook, points: CGFloat) -> AttributedString? {
        guard case .richText(let runs) = cue.body else { return nil }
        var all = AttributedString()
        for run in runs {
            var part = AttributedString(run.text.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n"))
            if run.isItalic || run.isBold {
                var font = look.swiftFont(points)
                if run.isBold { font = font.bold() }
                if run.isItalic { font = font.italic() }
                part.font = font
            }
            if run.isUnderlined { part.underlineStyle = Text.LineStyle.single }
            if run.isStruckThrough { part.strikethroughStyle = Text.LineStyle.single }
            if let color = run.color {
                let own = Color(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
                part.foregroundColor = own.opacity(look.opacity)
            }
            all += part
        }
        while let last = all.characters.last, last.isWhitespace { all.characters.removeLast() }
        while let first = all.characters.first, first.isWhitespace { all.characters.removeFirst() }
        return all.characters.isEmpty ? nil : all
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
        let languages = first.isEmpty ? [] : [first, second].filter { !$0.isEmpty }
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

    /// Subtitles for the hearing-impaired, as files mark or name them.
    static func isSDH(_ track: TrackInfo) -> Bool { isSDH(track.name, marked: track.isHearingImpaired) }
    static func isSDH(_ title: String, marked: Bool) -> Bool {
        if marked { return true }
        let name = title.lowercased()
        return name.contains("sdh") || name.contains("hearing") || name.contains("[cc]") || name.contains("(cc)") || name == "cc"
    }

    /// Two language codes for the same language ("en", "eng", "en-US"; "fre"/"fra", "ger"/"deu").
    /// A language code in its forms, in order: as given, ISO 639-2/T, two-letter ("ger" → ger, deu,
    /// de). For an engine that matches codes as written.
    static func forms(_ code: String) -> [String] {
        let lower = code.lowercased()
        let bibliographic = ["fre": "fra", "ger": "deu", "chi": "zho", "dut": "nld", "cze": "ces", "gre": "ell", "per": "fas", "rum": "ron"]
        let terminology = bibliographic[lower] ?? lower
        let short = Locale.Language(identifier: terminology).languageCode?.identifier(.alpha2) ?? terminology
        var out: [String] = []
        for form in [code, terminology, short] where !out.contains(form) { out.append(form) }
        return out
    }
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
