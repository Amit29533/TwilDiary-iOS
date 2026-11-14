import SwiftUI
import UIKit
import TwilDiaryCore

enum DiaryTheme: String, CaseIterable, Identifiable {
    case twilight, ocean, jade, rose, amber, premiere, native
    var id: Self { self }
    var name: String { rawValue.capitalized }
    var field: Color {
        switch self {
        case .premiere: Color(webHex: "#121212")
        case .native: Color(uiColor: .secondarySystemBackground)
        default: Color(webHex: "#111115")
        }
    }
    /// Everything else the theme colours (see `ThemePalette`).
    var palette: ThemePalette {
        switch self {
        case .premiere: .premiere
        case .native: .native
        default: .classic
        }
    }
    var detail: String {
        switch self {
        case .twilight: "The original violet"
        case .ocean: "Clear, cool blue"
        case .jade: "A quiet mint glow"
        case .rose: "Soft pink after dark"
        case .amber: "Warm cinema gold"
        case .premiere: "Streaming night: black, white and red"
        case .native: "iOS itself: light or dark, Liquid Glass"
        }
    }
    var ink: Color {
        switch self { case .twilight: Color(webHex: "#21182e"); case .ocean: Color(webHex: "#102039"); case .jade: Color(webHex: "#102820"); case .rose: Color(webHex: "#321622"); case .amber: Color(webHex: "#2c2010"); case .premiere, .native: Color(webHex: "#ffffff") }
    }
    var accent: Color {
        switch self {
        case .twilight: Color(webHex: "#b795f6")
        case .ocean: Color(webHex: "#82b8ff")
        case .jade: Color(webHex: "#79d8bc")
        case .rose: Color(webHex: "#f4a2c6")
        case .amber: Color(webHex: "#edbe73")
        case .premiere: Color(webHex: "#e50914")
        case .native: Color(uiColor: .systemBlue)
        }
    }
    /// The colour scheme the app asks for: always dark, except Native, which follows the iPhone.
    var colorScheme: ColorScheme? { palette.followsSystemAppearance ? nil : .dark }
}

extension Color {
    init(webHex: String) {
        let raw = webHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(raw, radix: 16) ?? 0
        let rgb = raw.count == 8 ? value >> 8 : value
        self.init(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: raw.count == 8 ? Double(value & 255) / 255 : 1)
    }
}

extension View {
    func diaryPanel(padding: CGFloat = 16, radius: CGFloat = 22, accentBorder: Bool = false, bordered: Bool = true) -> some View {
        modifier(DiaryPanelModifier(padding: padding, radius: radius, accentBorder: accentBorder, bordered: bordered))
    }
}

struct DiaryIcon: View {
    let name: String
    var size: CGFloat = 20
    var body: some View {
        Image(name).renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
}

extension Int {
    /// "1 watch", "3 watches": a count with the word that fits it.
    func counted(_ one: String, _ many: String) -> String { formatted() + " " + (self == 1 ? one : many) }
}

/// The app's small icon button: a faint 44 pt circle sized to its icon, never a padded glass bubble.
struct RoundTool: View {
    let icon: String
    var tint = Color(themed: "#c5c0cf")
    var size: CGFloat = 44
    var body: some View {
        DiaryIcon(name: icon, size: size * 0.43).foregroundStyle(tint).frame(width: size, height: size)
            .background(Color.primary.opacity(0.08), in: Circle()).frame(width: max(44, size), height: max(44, size)).contentShape(Circle())
    }
}

/// Sizes a poster by its width alone (height = width × 1.5). `.aspectRatio(contentMode: .fit)`
/// shrinks the whole poster whenever the height offered is tight, so a two-line title under it
/// made the poster smaller than its neighbours; this never gives way to the text.
struct PosterAspectLayout: Layout {
    var ratio: CGFloat = 1.5
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let offered = proposal.width ?? 0
        let width = offered.isFinite && offered > 0 ? offered : 120
        return CGSize(width: width, height: (width * ratio).rounded())
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews { view.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size)) }
    }
}
extension View {
    /// A 2:3 poster as wide as its card, whatever the text below it.
    func posterAspect(_ ratio: CGFloat = 1.5) -> some View { PosterAspectLayout(ratio: ratio) { self } }
}

/// A section heading's "see all": the same round chevron everywhere (Home, Explore, profiles,
/// rankings), instead of a mix of "Stats →" text links and buttons. The label is for VoiceOver.
/// The round › that opens a section's full page: the same button everywhere in the app.
struct RoundChevron: View {
    var body: some View {
        if ThemeStore.current.native {
            Image(systemName: "chevron.right").font(.system(size: 19, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        } else { classic }
    }
    private var classic: some View {
        Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.dateChipText)
            .frame(width: 44, height: 44).background(HomeStyle.round, in: Circle())
            .overlay(Circle().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
            .contentShape(Circle())
    }
}
struct SectionMoreLink<Value: Hashable>: View {
    let label: String
    let value: Value
    let identifier: String
    var body: some View {
        NavigationLink(value: value) { RoundChevron() }
            .buttonStyle(.springPress).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}
struct SectionMoreButton: View {
    let label: String
    let identifier: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { RoundChevron() }
            .buttonStyle(.springPress).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}

/// Compact 44 pt capsule buttons: dark violet with lavender text for the main action (as Add to
/// Planned), an outline for the rest.
struct DiaryCapsuleButtonStyle: ButtonStyle {
    var prominent = true
    /// Watch actions (Log a watch, Mark E3 watched): the bright lavender gradient with dark text.
    var bright = false
    /// A smaller capsule for actions inside list rows.
    var compact = false
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, prominent: prominent, bright: bright, compact: compact) }
    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let bright: Bool
        let compact: Bool
        @AppStorage("theme") private var theme = DiaryTheme.twilight
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            if ThemeStore.current.native { native } else { classic }
        }
        /// Native: Liquid Glass. The main and watch actions are the accent glass with white text
        /// (`.glassProminent`); the rest clear glass with accent text; destructive ones red.
        private var native: some View {
            let destructive = configuration.role == .destructive
            return configuration.label.font(.system(size: compact ? 14 : 16, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, compact ? 12 : 18).frame(minHeight: compact ? 34 : 44)
                .nativeGlassCapsule(prominent: (prominent || bright) && !destructive, ink: destructive ? Color(uiColor: .systemRed) : nil)
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.35), value: configuration.isPressed)
        }
        private var classic: some View {
            let destructive = configuration.role == .destructive
            return configuration.label.font(.system(size: compact ? 13 : 15, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, compact ? 12 : 16).frame(minHeight: compact ? 36 : 44)
                .foregroundStyle(bright ? WatchStyle.ink : prominent ? HomeStyle.chipText : destructive ? Color(themed: "#ff8a80") : theme.accent)
                .background(bright ? AnyShapeStyle(WatchStyle.fill) : prominent ? AnyShapeStyle(HomeStyle.chip) : AnyShapeStyle(Color.primary.opacity(0.07)), in: Capsule())
                .overlay { if !prominent { Capsule().strokeBorder(Color.primary.opacity(0.12)) } }
                .opacity(enabled ? 1 : 0.45).contentShape(Capsule())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
                .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
        }
    }
}
extension ButtonStyle where Self == DiaryCapsuleButtonStyle {
    static var diaryPrimary: DiaryCapsuleButtonStyle { DiaryCapsuleButtonStyle(prominent: true) }
    /// Logging a watch: the bright lavender gradient.
    static var diaryWatch: DiaryCapsuleButtonStyle { DiaryCapsuleButtonStyle(prominent: true, bright: true) }
    static var diarySecondary: DiaryCapsuleButtonStyle { DiaryCapsuleButtonStyle(prominent: false) }
    static var diaryRowPrimary: DiaryCapsuleButtonStyle { DiaryCapsuleButtonStyle(prominent: true, compact: true) }
    static var diaryRowSecondary: DiaryCapsuleButtonStyle { DiaryCapsuleButtonStyle(prominent: false, compact: true) }
}

/// A filter as a pill that opens its menu, as on Canvas and Explore.
/// The filter pill's surface: tinted when a filter is on; otherwise a faint fill, or Liquid Glass in Premiere.
private struct FilterPillSurface: ViewModifier {
    let active: Bool
    let accent: Color
    func body(content: Content) -> some View {
        if ThemeStore.current.native {
            // Native: clear glass, or the accent glass when a filter is on.
            content.glassEffect(active ? .regular.tint(accent.opacity(0.85)).interactive() : .regular.interactive(), in: Capsule())
        } else if !active, ThemeStore.current.usesGlass {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(active ? accent.opacity(0.12) : Color.primary.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(active ? accent.opacity(0.5) : Color.primary.opacity(0.14)))
        }
    }
}

struct FilterPill: View {
    let label: String
    var icon: String? = nil
    var active = false
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        HStack(spacing: 7) {
            if let icon { DiaryIcon(name: icon, size: 16) }
            Text(label).font(.system(size: 15, weight: .medium)).lineLimit(1)
            DiaryIcon(name: "chevron-down", size: 13)
        }.foregroundStyle(active ? (ThemeStore.current.native ? .white : theme.accent) : Color(themed: "#f3f0f7"))
            .padding(.horizontal, 14).frame(height: 38)
            .modifier(FilterPillSurface(active: active, accent: theme.accent))
            .frame(minHeight: 44).contentShape(Capsule())
    }
}

/// Each service's own current logo, in its own colours (from the service's site), sized like a
/// settings icon. Nothing is redrawn or reduced to a name.
struct BrandLogo: View {
    enum Service { case trakt, tmdb, jellyfin, simkl, mdblist, wetrakr, cloudflare, anilist, imdb, myanimelist, metacritic, rottenTomatoes, letterboxd, tvtime }
    let service: Service
    var size: CGFloat = 34
    var body: some View {
        let corner = RoundedRectangle(cornerRadius: size * 0.225)
        Group {
            switch service {
            case .trakt: Image("trakt-mark").resizable().scaledToFit()
            case .jellyfin: Image("jellyfin-mark").resizable().scaledToFit().padding(size * 0.06)
            // TMDB's current green speech-bubble mark.
            case .tmdb: Image("tmdb-logo").resizable().scaledToFit().padding(size * 0.04)
            case .simkl: Image("brand-simkl").resizable().scaledToFit().clipShape(corner)
            case .mdblist: Image("brand-mdblist").resizable().scaledToFit().clipShape(corner)
            // WeTrakr's "we" mark on its violet (drawn here; no image asset yet).
            case .wetrakr: Text("we").font(.system(size: size * 0.46, weight: .black, design: .rounded)).tracking(-size * 0.03)
                .foregroundStyle(.white).frame(width: size, height: size).background(Color(themed: "#4b3df5"), in: corner)
            // A square tile (the cloud is twice as wide as tall: sized first, then the tile).
            case .cloudflare: Image("brand-cloudflare").resizable().scaledToFit()
                .padding(size * 0.14).frame(width: size, height: size).background(.white, in: corner)
            case .anilist: Image("brand-anilist").resizable().scaledToFit()
                .padding(size * 0.08).frame(width: size, height: size).background(Color(themed: "#2b2d42"), in: corner)
            case .imdb: Image("brand-imdb").resizable().scaledToFit()
            case .myanimelist: Image("brand-myanimelist").resizable().scaledToFit().clipShape(corner)
            case .metacritic: Image("brand-metacritic").resizable().scaledToFit()
            case .rottenTomatoes: Image("brand-rottentomatoes").resizable().scaledToFit().clipShape(corner)
            case .letterboxd: Image("brand-letterboxd").resizable().scaledToFit().clipShape(corner)
            // TV Time's black "tv" on its yellow (drawn here; no image asset).
            case .tvtime: Text("tv").font(.system(size: size * 0.5, weight: .black, design: .rounded)).tracking(-size * 0.02)
                .foregroundStyle(.black).frame(width: size, height: size).background(Color(themed: "#FFD400"), in: corner)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
    /// The logo for a rating source key ("imdb", "myanimelist", "tomatoes"…), if there is one.
    static func service(forRatingSource key: String) -> Service? {
        switch key {
        case "tmdb": .tmdb
        case "trakt": .trakt
        case "imdb": .imdb
        case "myanimelist", "mal": .myanimelist
        case "metacritic": .metacritic
        case "tomatoes", "popcorn": .rottenTomatoes
        case "letterboxd": .letterboxd
        case "simkl": .simkl
        case "anilist": .anilist
        default: nil
        }
    }
}

struct BrandMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let sx = rect.width / 24, sy = rect.height / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        path.move(to: point(12, 1))
        path.addCurve(to: point(23, 12), control1: point(13.5, 8.5), control2: point(15.5, 10.5))
        path.addCurve(to: point(12, 23), control1: point(15.5, 13.5), control2: point(13.5, 15.5))
        path.addCurve(to: point(1, 12), control1: point(10.5, 15.5), control2: point(8.5, 13.5))
        path.addCurve(to: point(12, 1), control1: point(8.5, 10.5), control2: point(10.5, 8.5))
        path.closeSubpath(); return path
    }
}

/// A tab page's header: the logo, title and actions are the scroll's first row and scroll away
/// with the page (true full screen; search and navigation live in the tab bar and gestures).
struct PageHeader: View {
    let name: String
    var count: String? = nil
    /// Home draws the header over the Continue watching backdrop.
    var overArtwork = false
    /// Library's Select button.
    var onSelect: (() -> Void)? = nil
    var height: CGFloat = 56
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var taps: [Double] = []
    @State private var angle = 0.0
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        HStack(spacing: 10) {
            // The spinning logo lives on Home only; other pages lead with a bigger title.
            if isHome { logo }
            title
            Spacer(minLength: 0)
            if let onSelect { glassButton("circle-check", label: "Select titles", id: "library-select", action: onSelect) }
        }.frame(height: height).padding(.horizontal, isHome ? 16 : 14)
    }
    private var isHome: Bool { name == "TwilDiary" }
    private var logo: some View {
        Button {
            let gesture = RandomPick.tap(previous: taps, now: ProcessInfo.processInfo.systemUptime)
            taps = gesture.taps
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.65)) { angle += 270 }
            if gesture.triggered { presentPick() }
        } label: {
            // The original Liquid Glass logo (owner's choice): the mark in the theme's accent on glass.
            BrandMark().fill(theme.accent).frame(width: 22, height: 22).rotationEffect(.degrees(angle))
                .frame(width: 44, height: 44)
                // See-through glass, as the other header buttons (owner's choice over a dark face);
                // held to the dark look so it doesn't flip between light and dark over bright artwork.
                .glassEffect(.regular.interactive(), in: Circle())
                .environment(\.colorScheme, ThemeStore.current.native ? colorScheme : .dark)
                // The tap shape sits outside the glass; otherwise the interactive glass takes the tap.
                .frame(width: 44, height: 44).contentShape(Circle())
        }.buttonStyle(.plain)
            // Quick taps can reach the button as one; a real triple tap opens the pick too.
            .simultaneousGesture(TapGesture(count: 3).onEnded { presentPick() })
            .sensoryFeedback(.impact(weight: .light), trigger: angle).accessibilityLabel("Spin TwilDiary logo").accessibilityHint("Tap three times for a random pick")
            .accessibilityAction(named: "Random pick") { presentPick() }
            .accessibilityIdentifier("random-pick-logo")
    }
    private func presentPick() {
        taps = []
        if router.randomPick == nil { router.presentRandomPick() }
    }
    @ViewBuilder private var title: some View {
        if ThemeStore.current.native {
            // Native: a large title, 34 pt bold in the label colour, as every Apple app's root page.
            Text(name).font(.system(size: name == "TwilDiary" ? 30 : 34, weight: .bold)).foregroundStyle(Color(uiColor: .label))
                .lineLimit(1).minimumScaleFactor(0.7).accessibilityIdentifier(name == "TwilDiary" ? "" : "page-title")
        } else if name == "TwilDiary" {
            // Design: one 24 pt bold word with a left-to-right #f5f0ff → #b79cff gradient.
            Text("TwilDiary").font(.system(size: 24, weight: .bold)).tracking(-0.48)
                .foregroundStyle(LinearGradient(colors: [Color(themed: "#f5f0ff"), Color(themed: "#b79cff")], startPoint: .leading, endPoint: .trailing))
        } else { Text(name).font(.system(size: 32, weight: .bold)).tracking(-1.3).foregroundStyle(Color(themed: "#f3f0f7")).lineLimit(1).minimumScaleFactor(0.7).accessibilityIdentifier("page-title") }
        if let count {
            Text(count).font(.system(size: 13)).foregroundStyle(Color(themed: "#a09aa9")).lineLimit(1)
                .contentTransition(.numericText()).animation(reduceMotion ? nil : Motion.smooth, value: count)
        }
    }
    private func glassButton(_ icon: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DiaryIcon(name: icon, size: 20).foregroundStyle(Color(themed: "#e6e2ec")).frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: Circle()).frame(width: 44, height: 44).contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }
}

struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    let label: String
    var autoFocus = false
    var focusRevision = 0
    var dismissRevision = 0
    /// Search by description (Gemini): the small AI pill turns it on, and the border glows in
    /// Gemini's colours while it's on. nil: no pill.
    var ai: Binding<Bool>? = nil
    /// The keyboard's Search key.
    var onSearch: (() -> Void)? = nil
    @State private var didAutoFocus = false
    @State private var spin = 0.0
    @FocusState private var focused: Bool
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Gemini's blue, violet, rose and gold, round the border and back to blue.
    /// AI looks the same everywhere: CineMind's glow colours on the AI pill and the field's ring.
    static let geminiColors = CineGlow.colours + [CineGlow.colours[0]]
    private var aiOn: Bool { ai?.wrappedValue == true }
    var body: some View {
        HStack(spacing: 10) {
            DiaryIcon(name: "search", size: 19).foregroundStyle(Color(themed: "#a09aa9"))
            TextField(aiOn ? "Describe a movie or show…" : placeholder, text: $text).font(.system(size: 16)).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).focused($focused).onSubmit { focused = false; onSearch?() }.accessibilityLabel(aiOn ? "Search by description" : label)
            if let ai { aiPill(ai) }
            if !text.isEmpty { Button { text = ""; focused = true } label: { DiaryIcon(name: "x", size: 16).frame(width: 26, height: 32) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
        }.padding(.horizontal, 14).frame(minHeight: 48).background { DiaryControlSurface(shape: RoundedRectangle(cornerRadius: 12), field: true) }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused && !aiOn ? theme.accent.opacity(0.65) : .clear))
            .overlay { if aiOn { geminiGlow.transition(.opacity) } }
            .animation(.smooth(duration: 0.3), value: aiOn)
            .onChange(of: aiOn, initial: true) { _, on in
                spin = 0
                guard on, !reduceMotion else { return }
                withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) { spin = 360 }
            }
            .onDisappear { focused = false }
            .onChange(of: focusRevision) { _, _ in
                focused = true
                // A re-tap that popped back to Search: the field may only just be on screen again.
                Task { try? await Task.sleep(for: .milliseconds(400)); if !focused { focused = true } }
            }
            .onChange(of: dismissRevision) { _, _ in focused = false }
            .task { if autoFocus && !didAutoFocus { didAutoFocus = true; focused = true } }
    }
    /// "AI" in a small pill: grey when off, Gemini's gradient when on.
    private func aiPill(_ ai: Binding<Bool>) -> some View {
        Button { ai.wrappedValue.toggle(); if ai.wrappedValue { focused = true } } label: {
            Text("AI").font(.system(size: 12, weight: .bold)).foregroundStyle(ai.wrappedValue ? .white : Color(themed: "#a09aa9"))
                .padding(.horizontal, 9).frame(height: 24)
                .background {
                    if ai.wrappedValue { Capsule().fill(LinearGradient(colors: Array(Self.geminiColors.prefix(3)), startPoint: .leading, endPoint: .trailing)) }
                    else { Capsule().fill(Color.primary.opacity(0.08)).overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)) }
                }
                .frame(minWidth: 36, minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(.plain).sensoryFeedback(.selection, trigger: ai.wrappedValue)
            .accessibilityLabel("Search by description with AI").accessibilityValue(ai.wrappedValue ? "On" : "Off").accessibilityIdentifier("search-ai")
    }
    /// The border in Gemini's colours, turning slowly, with a soft glow outside it.
    private var geminiGlow: some View {
        let gradient = AngularGradient(colors: Self.geminiColors, center: .center, angle: .degrees(spin))
        return ZStack {
            RoundedRectangle(cornerRadius: 12).stroke(gradient, lineWidth: 6).blur(radius: 9).opacity(0.75)
            RoundedRectangle(cornerRadius: 12).strokeBorder(gradient, lineWidth: 1.8)
        }.allowsHitTesting(false)
    }
}

@MainActor enum DemoArtwork {
    static let cache = NSCache<NSString, UIImage>()
    static func image(_ path: String) -> UIImage? {
        if let saved = cache.object(forKey: path as NSString) { return saved }
        if path.hasPrefix("scene:") {
            let scenes: [String: CGRect] = ["frieren": CGRect(x: 506, y: 446, width: 287, height: 120), "night": CGRect(x: 510, y: 795, width: 285, height: 145), "severance": CGRect(x: 496, y: 1150, width: 299, height: 135), "again": CGRect(x: 510, y: 1480, width: 285, height: 110)]
            guard let crop = scenes[String(path.dropFirst(6))], let file = Bundle.main.path(forResource: "glance-reference-atlas", ofType: "jpg"), let source = UIImage(contentsOfFile: file)?.cgImage?.cropping(to: crop) else { return nil }
            let image = UIImage(cgImage: source); cache.setObject(image, forKey: path as NSString); return image
        }
        let name = path.hasPrefix("asset:") ? String(path.dropFirst(6)) : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let windows: [String: CGRect] = ["frieren": CGRect(x: 60, y: 335, width: 193, height: 240), "night": CGRect(x: 60, y: 711, width: 193, height: 242), "severance": CGRect(x: 60, y: 1084, width: 193, height: 212), "again": CGRect(x: 60, y: 1426, width: 193, height: 177)]
        let image: UIImage?
        if path.hasPrefix("/demo/"), let crop = windows[name], let file = Bundle.main.path(forResource: "glance-reference-atlas", ofType: "jpg"), let source = UIImage(contentsOfFile: file)?.cgImage?.cropping(to: crop) { image = UIImage(cgImage: source) }
        else if let file = Bundle.main.path(forResource: name, ofType: "jpg") { image = UIImage(contentsOfFile: file) }
        else { image = nil }
        if let image { cache.setObject(image, forKey: path as NSString) }; return image
    }
}

struct Artwork: View {
    let path: String?
    var title: String = ""
    var initialsOnly = true
    /// Where a cropped image anchors: `.top` keeps portraits' faces in frame.
    var alignment: Alignment = .center
    var contentMode: ContentMode = .fill
    /// Full-width profiles can use the original public TMDB portrait before downsampling.
    var prefersOriginal = false
    @Environment(\.displayScale) private var displayScale
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var loadedArtwork: PublicArtworkBitmap?
    @State private var loadedRequest: PublicArtworkRequest?
    var body: some View {
        GeometryReader { proxy in
          let request = PublicArtworkRequest(path: path, pixels: Double(max(proxy.size.width, proxy.size.height) * displayScale),
                                             width: Double(proxy.size.width * displayScale), prefersOriginal: prefersOriginal)
          // A size change keeps the previous bitmap of the same image until the new size is decoded.
          let bitmap: PublicArtworkBitmap? = request.flatMap { request in
              (loadedRequest == request ? loadedArtwork : nil) ?? PublicArtworkCache.shared.cached(request) ?? (loadedRequest?.url == request.url ? loadedArtwork : nil)
          }
          ZStack {
            // A fitted image leaves the spare space clear for whatever is behind it. The gradient is
            // drawn only while there's no image over it: under a loaded poster it was two more
            // layers per tile composited on every frame of a scroll (eight per Canvas list card).
            if contentMode == .fit { Color.clear }
            else if bitmap == nil, initialsOnly { LinearGradient(colors: [tint, theme.initialsBase], startPoint: .topLeading, endPoint: .bottomTrailing) }
            else if bitmap == nil {
                LinearGradient(colors: [Color(themed: "#243638"), Color(themed: "#17151e"), Color(themed: "#17151e")], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [theme.placeholderGlow, .clear], center: UnitPoint(x: 0.8, y: 0.05), startRadius: 0, endRadius: max(proxy.size.width, proxy.size.height) * 0.7)
            }
            if let path, path.hasPrefix("asset:") || path.hasPrefix("/demo/") || path.hasPrefix("scene:"), let image = DemoArtwork.image(path) { Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode).frame(width: proxy.size.width, height: proxy.size.height, alignment: alignment).clipped() }
            else if let image = fixtureImage(path) { Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode).frame(width: proxy.size.width, height: proxy.size.height, alignment: alignment).clipped() }
            else if let request {
                // While loading, only the gradient shows: the named placeholder appears
                // only after a load failed, so new cells no longer flash title text
                // before their poster.
                if let bitmap {
                    // High-quality resampling: small sources (AniList's 230 px portraits) stay smooth when enlarged.
                    Image(decorative: bitmap.image, scale: displayScale).resizable().interpolation(.high).aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: alignment).clipped()
                } else if loadedRequest == request { placeholder(size: proxy.size) }
            } else { placeholder(size: proxy.size) }
          }.frame(width: proxy.size.width, height: proxy.size.height).clipped()
            .task(id: request) {
                guard fixtureImage(path) == nil else { return }
                guard let request else { loadedArtwork = nil; loadedRequest = nil; return }
                if let saved = PublicArtworkCache.shared.cached(request) { loadedRequest = request; loadedArtwork = saved; return }
                var bitmap = await PublicArtworkCache.shared.image(request)
                // A load that failed (often the first one right after launch, while the network
                // wakes up) is asked again a few times before the placeholder stays: Home's hero
                // was left without its artwork after a cold start.
                for wait in [2.0, 6.0, 15.0] where bitmap == nil {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { return }
                    bitmap = await PublicArtworkCache.shared.image(request, retrying: true)
                }
                guard !Task.isCancelled else { return }
                loadedRequest = request; loadedArtwork = bitmap
            }
        }.contentShape(Rectangle()).accessibilityHidden(true)
    }
    private var tint: Color {
        let values = ["#543173", "#514779", "#294959", "#345682", "#477062", "#73435f"]
        return Color(themed: values[title.unicodeScalars.reduce(0) { $0 + Int($1.value) } % values.count])
    }
    private func fixtureImage(_ path: String?) -> UIImage? {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"), let path, path.contains("image.tmdb.org/t/p/") else { return nil }
        return DemoArtwork.image(path.contains("backdrop") ? "/demo/frieren-hero-v2.jpg" : "asset:frieren")
        #else
        return nil
        #endif
    }
    @ViewBuilder private func placeholder(size: CGSize) -> some View {
        if initialsOnly { initials }
        else {
            // Just the clapperboard: every card already shows the title beside or below its artwork.
            DiaryIcon(name: "clapperboard", size: min(34, max(16, min(size.width, size.height) * 0.3)))
                .foregroundStyle(Color(themed: "#d2c4e4"))
        }
    }
    private var initials: some View { Text(title.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()).font(.system(size: 24, weight: .bold)).foregroundStyle(Color(themed: "#eee6fb99")) }
}

struct RatingBadge: View {
    let score: Double
    var community = true
    var source: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill").font(.system(size: community ? 10 : 12))
                .foregroundStyle(Color(themed: community ? "#ffe030" : "#f4d06a"))
            // Your ratings are whole numbers ("8"); community scores keep their decimal ("7.3").
            Text(score, format: .number.precision(community ? .fractionLength(1) : .fractionLength(0...1))).frame(minHeight: community ? 17.25 : 18)
        }.font(.system(size: community ? 11.5 : 12, weight: community ? .medium : .semibold))
            .lineLimit(1).fixedSize(horizontal: true, vertical: true)
            .foregroundStyle(Color(themed: community ? "#f5f5f5" : "#f3f0f7"))
            // No text shadow: the badge already sits on a dark capsule, and a blurred
            // shadow costs an offscreen render pass for every poster in a scrolling grid.
            .padding(.horizontal, community ? 6 : 4).padding(.vertical, 3)
            .background(Color(themed: community ? "#00000099" : "#07090cdd"), in: RoundedRectangle(cornerRadius: community ? 99 : 7))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(source ?? (community ? "Community" : "Your")) rating \(score, format: .number.precision(community ? .fractionLength(1) : .fractionLength(0...1))) out of 10"))
    }
}

struct PosterCard: View {
    let title: MediaTitle
    var personalRating = false
    var archived = false
    @Environment(DiaryStore.self) private var store
    @AppStorage("publicRatingSource") private var ratingSource = PublicRatingSource.tmdb
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Artwork(path: title.poster, title: title.name, initialsOnly: !personalRating).posterAspect()
                .overlay(alignment: personalRating ? .bottomLeading : .topLeading) { if let score = displayedScore { RatingBadge(score: score, community: !personalRating).padding(6) } }
                .overlay(alignment: .bottom) { if !personalRating && title.status != "completed" && progress > 0 { GeometryReader { proxy in Rectangle().fill(theme.accent.opacity(0.267)).overlay(alignment: .leading) { Rectangle().fill(theme.accent).frame(width: proxy.size.width * progress) } }.frame(height: 4) } }
                .overlay(alignment: .bottomTrailing) { statusBadge }
                .overlay(alignment: personalRating ? .topLeading : .bottomLeading) { availabilityBadges.padding(8) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(title.name).font(.system(size: 15, weight: .semibold)).lineSpacing(2.3).foregroundStyle(Color(themed: "#f3f0f7")).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }.contentShape(Rectangle()).accessibilityElement(children: .ignore).accessibilityLabel(title.name).accessibilityValue(accessibleDetails)
    }
    private var displayedScore: Double? { personalRating ? title.score : store.publicScore(title, source: ratingSource) }
    private var present: Bool { !archived && store.hasPresentLocation(title.id) }
    private var accessibleDetails: String {
        [title.categoryName, archived ? "In Trash" : title.status.capitalized, displayedScore.map { "Rating " + $0.formatted(.number.precision(.fractionLength(1))) }, title.status != "completed" && progress > 0 ? "\(Int((progress * 100).rounded())) percent watched" : nil, title.queued == true ? "In Queue" : nil, !personalRating && present ? "On your PC" : nil].compactMap { $0 }.joined(separator: ", ")
    }
    @ViewBuilder private var statusBadge: some View {
        if personalRating {
            DiaryIcon(name: title.statusIconName, size: 18).foregroundStyle(Color(themed: title.status == "planned" ? "#b9dcff" : "#d3d4dc"))
                .frame(width: 26, height: 26).background(Color(themed: "#080a10e8"), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.42))).padding(6)
        } else if title.status == "completed" && !archived {
            Image(systemName: "checkmark").font(.system(size: 17, weight: .heavy))
                .foregroundStyle(theme.accent).shadow(color: .black.opacity(0.8), radius: 3)
                .frame(width: 26, height: 26).padding(8)
        }
    }
    private var availabilityBadges: some View {
        VStack(alignment: .leading, spacing: 5) {
            if title.queued == true {
                DiaryIcon(name: "download", size: 14).foregroundStyle(theme.accent).frame(width: 27, height: 27)
                    .background(Color(themed: "#080c10d9"), in: RoundedRectangle(cornerRadius: 7))
            }
            if present && !personalRating {
                DiaryIcon(name: "monitor", size: 14).foregroundStyle(Color(themed: "#9edbc4"))
                    .frame(width: 27, height: 27).background(Color(themed: "#080c10b8"), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }
    private var progress: Double {
        store.libraryProgress(title)
    }
}

/// All · Movies · Shows · Anime as pills: the selected one is filled with the theme accent.
/// Shared by Glance and Library so both read and behave the same.
struct CategoryPicker: View {
    @Binding var selection: LibraryCategory
    /// Glance's design shows each category's count ("All 55", "Movies 8") on dark pills.
    var counts: [LibraryCategory: Int]? = nil
    /// Trash: every category on its own dark pill (the reference design).
    var pills = false
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The accent pill glides from one category to the next instead of jumping.
    @Namespace private var pill
    /// The tapped category while its pill is still gliding. The cards change only once the pill
    /// lands, so rebuilding them can't hold up the pill (it used to move a beat after the tap).
    @State private var pending: LibraryCategory?
    var body: some View {
        if ThemeStore.current.native { native } else { classic }
    }
    /// Native: a segmented control on Liquid Glass. The categories share one glass track and the
    /// chosen one sits on a raised thumb that slides under the finger's choice (as iOS 26's own).
    private var native: some View {
        let shown = pending ?? selection
        return HStack(spacing: 0) {
            ForEach(LibraryCategory.allCases) { category in
                let selected = shown == category
                Button { choose(category) } label: {
                    HStack(spacing: 5) {
                        Text(category.rawValue)
                        if let count = counts?[category] {
                            Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }.font(.system(size: 14, weight: selected ? .semibold : .medium)).foregroundStyle(Color(uiColor: .label))
                        .lineLimit(1).padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36)
                        .background {
                            if selected {
                                Capsule().fill(ThemePalette.adaptive(dark: 0.4, light: 1))
                                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                                    .matchedGeometryEffect(id: "category-pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("category-" + category.rawValue.lowercased()).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.padding(3).glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 16).padding(.vertical, 4)
            .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.22), value: selection)
            .sensoryFeedback(.selection, trigger: shown)
            .onChange(of: selection) { _, value in if pending == value { pending = nil } }
    }
    private var classic: some View {
        let shown = pending ?? selection
        return HStack(spacing: 6) {
            ForEach(LibraryCategory.allCases) { category in
                let selected = shown == category
                Button { choose(category) } label: {
                    HStack(spacing: 6) {
                        Text(category.rawValue)
                        if let count = counts?[category] {
                            Text(count.formatted()).foregroundStyle(selected ? theme.ink.opacity(0.75) : HomeStyle.secondary).monospacedDigit()
                        }
                    }.font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? theme.ink : counts == nil && !pills ? Color(themed: "#c5c0cf") : HomeStyle.primary)
                        .padding(.horizontal, counts == nil ? 16 : 14).frame(minHeight: 40)
                        .background {
                            if selected { Capsule().fill(theme.accent).matchedGeometryEffect(id: "category-pill", in: pill) }
                            else if counts != nil || pills { Capsule().fill(HomeStyle.round).overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline)) }
                        }
                        .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("category-" + category.rawValue.lowercased()).accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 14).padding(.vertical, 4)
            // A side swipe changes the selection directly; the pill follows it the same way.
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: selection)
            .sensoryFeedback(.selection, trigger: shown)
            .onChange(of: selection) { _, value in if pending == value { pending = nil } }
    }
    private func choose(_ category: LibraryCategory) {
        guard category != (pending ?? selection) else { return }
        if reduceMotion { selection = category; return }
        let glide: Animation = ThemeStore.current.native ? .spring(duration: 0.32, bounce: 0.22) : .snappy(duration: 0.22)
        withAnimation(glide) { pending = category } completion: {
            if pending == category { selection = category }
        }
    }
}

/// The − / + circles. Live Liquid Glass samples and blurs what's behind it every frame; on the large
/// cards (Glance's top card, Home) that's worth it, but dozens of list and grid cards each carrying two
/// made Glance stutter while scrolling. Those get the same look as plain fills.
/// A legibility shadow only where text sits on artwork; an invisible one still renders offscreen.
struct TextShadow: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.shadow(color: .black.opacity(0.6), radius: 4, y: 1) } else { content }
    }
}

/// Watch actions keep the bright lavender gradient with dark text (Start, + E2, Log watch, the
/// round +); other main buttons are dark violet with lavender text.
enum WatchStyle {
    // The theme's play button: lilac in the original themes, white with black text in Premiere.
    static var fill: LinearGradient { LinearGradient(colors: [ThemeStore.current.watchTop, ThemeStore.current.watchBottom], startPoint: .top, endPoint: .bottom) }
    static var ink: Color { ThemeStore.current.watchInk }
}

private struct CardCircle: ViewModifier {
    let glass: Bool
    let tint: Color?
    func body(content: Content) -> some View {
        if glass {
            content.glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? .regular.interactive(), in: Circle())
        } else {
            content.background(Circle().fill(tint ?? Color.primary.opacity(0.14)))
                .overlay(Circle().strokeBorder(.white.opacity(tint == nil ? 0.18 : 0.25), lineWidth: 0.75))
        }
    }
}


struct ProgressCard: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    let title: MediaTitle
    var compact = false
    var grid = false
    /// Glance's large card for the most recently updated title: full artwork, text on a scrim.
    var hero = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(DiaryStore.self) private var store
    @State private var loadedCard: WatchCard?
    /// The card shown. A show's card read before its episodes are (an empty "E0 of 0", which
    /// happens for a moment each time Home appears or refreshes) never replaces real progress:
    /// the last real one stays until real numbers come back, so the buttons don't jump.
    private var card: WatchCard? {
        var candidates = [loadedCard, store.cachedCard(title)].compactMap { $0 }
        // A diary kept on the phone works its card out at once: a page the carousel turns to
        // shows its progress straight away instead of "Checking progress…" first.
        if candidates.isEmpty, store.diarySource != "server" { candidates = [store.localCard(title)] }
        guard title.isSeries else { return candidates.first }
        return candidates.first { $0.progress.total > 0 } ?? Self.lastReal[title.id] ?? candidates.first
    }
    /// Each show's last card with real progress, kept across the card being rebuilt.
    @MainActor private static var lastReal: [String: WatchCard] = [:]
    @State private var watchFeedback = 0
    /// New watches only (not removals): the mark button throws a star burst.
    @State private var sparks = 0
    @State private var suppressNavigationUntil = Date.distantPast
    /// Notes open as their own sheet over the card, not the whole title page.
    @State private var showNotes = false
    @State private var waitedForProgress = false
    /// Progress worth showing: a card, and for a show its episode count.
    private var progressKnown: Bool { card.map { !title.isSeries || $0.progress.total > 0 } ?? false }
    @Environment(AppRouter.self) private var router
    var body: some View {
        ZStack(alignment: .leading) {
            Group { if compact { compactContent } else if hero { heroContent } else { glanceContent } }
                .background {
                    GeometryReader { proxy in
                        Button { openTitle() } label: {
                            Group {
                                // Home's hero draws its backdrop behind the whole page header instead.
                                if compact { Color.clear }
                                else if hero { Artwork(path: cardBackdrop, title: title.name).overlay(scrim) }
                                else if ThemeStore.current.native { Color.clear }
                                else { Rectangle().fill(theme.field) }
                            }.frame(width: proxy.size.width, height: proxy.size.height).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Open " + title.name).accessibilityIdentifier("progress-cover-" + title.id)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .background { if ThemeStore.current.native && !compact && !hero { Color.clear.nativeCard(radius: cornerRadius) } }
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(compact || (ThemeStore.current.native && !hero) ? 0 : 0.17)))
        }.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .task(id: store.cardRevision(title.id)) { await loadCard() }
            .sensoryFeedback(.success, trigger: watchFeedback)
            .sheet(isPresented: $showNotes) { TitleNotesSheet(titleID: title.id) }
    }
    /// Home's Continue watching text over the page backdrop (owner's design): title, "S2 · E3 of 8",
    /// the bar with "38% complete" and the time left, then the same − / + controls as Glance.
    /// A show with nothing watched in its current season: the design's "Start S2 · E1" state.
    private var notStarted: Bool { title.isSeries && (card.map { $0.progress.watched == 0 && $0.next != nil } ?? false) }
    private var compactContent: some View {
        // Design spacing: label, 8, title, 6, "S2 · E4 of 12", then the bar row; the − / + sit on
        // the middle of the bar and its labels together.
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if notStarted {
                    Text("CONTINUE WATCHING").font(.system(size: 11, weight: .bold)).tracking(1.54).foregroundStyle(Color(themed: "#cdbbff"))
                        .frame(height: 14).padding(.bottom, 6)
                } else {
                    Text("CONTINUE WATCHING").font(.system(size: 12, weight: .medium)).tracking(1.92).foregroundStyle(Color(themed: "#d8d4e6"))
                        .frame(height: 16).padding(.bottom, 8)
                }
            }.shadow(color: .black.opacity(0.5), radius: 6, y: 1).accessibilityLabel("Continue watching").accessibilityAddTraits(.isHeader)
            Button { openTitle() } label: {
                Text(title.name).font(.system(size: 26, weight: .bold)).tracking(-0.52).foregroundStyle(Color(themed: "#f5f5f7"))
                    .lineLimit(3).multilineTextAlignment(.leading).shadow(color: .black.opacity(0.55), radius: 8, y: 2)
            }.buttonStyle(.plain).accessibilityIdentifier("progress-title-" + title.id)
            // Its row fades in once progress is known, instead of one row flashing into the other:
            // an empty card ("E0 of 0", episodes not read yet) counts as not known (at most 2 s).
            Group { if notStarted { startRow } else { progressRow } }
                .opacity(progressKnown || waitedForProgress ? 1 : 0)
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: progressKnown || waitedForProgress)
                .task { try? await Task.sleep(for: .seconds(2)); waitedForProgress = true }
        }.padding(.horizontal, 8).frame(height: 196)
    }
    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(homeLine).font(.system(size: 14)).foregroundStyle(Color(themed: "#d8d4e6")).lineLimit(1).frame(height: 20).padding(.top, 6)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { proxy in RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.28)).overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 3).fill(.tint).frame(width: proxy.size.width * fraction) } }.frame(width: 186, height: 5)
                    // Held to the bar's width: a long label ("Time unknown") shortens with … instead of
                    // pushing the − / count / + over, which wrapped the count onto two lines.
                    HStack(spacing: 12) {
                        // Share and episode count come from the same card, so they always agree.
                        Text(card == nil ? "Checking progress…" : "\(Int((fraction * 100).rounded()))% complete").layoutPriority(1)
                        Spacer(minLength: 0)
                        if let left = cardText?.timeLeft { Text(left).monospacedDigit() }
                    }.font(.system(size: 13)).foregroundStyle(Color(themed: "#d8d4e6")).lineLimit(1).frame(width: 186)
                }
                Spacer(minLength: 0)
                controls
            }.padding(.top, 10)
        }
    }
    /// Nothing watched yet: "Season 2 · 12 episodes · about 4h 48m", then a 48 pt gradient
    /// "Start S2 · E1" button and a 48 pt frosted + that adds the show to the Queue (design).
    private var startRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(startLine).font(.system(size: 13)).foregroundStyle(Color(themed: "#b4b3c2")).lineLimit(1).frame(height: 18).padding(.top, 6)
            HStack(spacing: 10) {
                Button { Task { await markWatch() } } label: {
                    HStack(spacing: 8) {
                        actionIcon(.mark, symbol: "play.fill", size: 13)
                        Text(startLabel).font(.system(size: 15, weight: .bold))
                    }.foregroundStyle(WatchStyle.ink).frame(maxWidth: .infinity).frame(height: 48)
                        .background(WatchStyle.fill, in: Capsule())
                        .contentShape(Capsule())
                }.buttonStyle(.springPress).disabled(!markable).starBurst(trigger: sparks).accessibilityLabel(startLabel + ", " + title.name)
                Button { guard !cardBusy, !store.needsMutationRefresh else { return }; Task { await store.patchCard(title.id, values: ["queued": title.queued != true]) } } label: {
                    Image(systemName: title.queued == true ? "checkmark" : "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color(themed: "#f5f5f7"))
                        .frame(width: 48, height: 48)
                        .background(Color(red: 120 / 255, green: 122 / 255, blue: 132 / 255).opacity(0.32), in: Circle())
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                }.buttonStyle(.plain)
                    .accessibilityLabel(title.queued == true ? "Remove from Queue" : "Add to Queue")
            }.padding(.top, 14)
        }
    }
    private var startLabel: String {
        guard let card, let next = card.next else { return "Start" }
        let season = card.season.map { $0.number == 0 ? "Specials" : "S\($0.number)" }
        return "Start " + ([season, "E\(next.number)"].compactMap { $0 }.joined(separator: " · "))
    }
    /// "Season 2 · 12 episodes · about 4h 48m".
    private var startLine: String {
        guard let card else { return title.categoryName }
        let season = card.season.map { $0.number == 0 ? "Specials" : "Season \($0.number)" }
        let count = card.progress.total.counted("episode", "episodes")
        let time = remaining.flatMap { $0 > 0 ? "about " + DiaryDate.duration($0) : nil }
        return [season, count, time].compactMap { $0 }.joined(separator: " · ")
    }
    /// "S2 · E3 of 8" for shows, "Movie · 1h 54m" for movies.
    private var homeLine: String {
        guard title.isSeries else { return (["Movie"] + [title.runtimeMinutes.map(DiaryDate.duration)].compactMap { $0 }).joined(separator: " · ") }
        guard let card else { return title.categoryName }
        let season = card.season.map { $0.number == 0 ? "Specials" : "S\($0.number)" }
        return [season, "E\(card.progress.watched) of \(card.progress.total)"].compactMap { $0 }.joined(separator: " · ")
    }
    /// Poster on the left; title, progress and the − / + controls stacked beside it.
    @ViewBuilder private var glanceContent: some View {
        if grid { gridContent } else {
            // Every card's poster is the same 2:3 size; a longer title grows the text column, not the poster.
            // The poster sits centred, so a two-line name's extra height is split above and below it.
            HStack(alignment: .top, spacing: 14) {
                Color.clear.frame(width: 66, height: 99)
                VStack(alignment: .leading, spacing: 4) {
                    // The name gets two lines; the episode line sits centred just above the bar.
                    Button { openTitle() } label: {
                        Text(title.name).font(.system(size: 17, weight: .semibold)).tracking(-0.425).foregroundStyle(HomeStyle.ink)
                            .lineLimit(2).truncationMode(.tail).multilineTextAlignment(.leading)
                    }.buttonStyle(.plain).padding(.trailing, 34).padding(.top, 6).accessibilityIdentifier("progress-title-" + title.id)
                    if let glanceTime { timePill(glanceTime).padding(.top, 4) }
                    Spacer(minLength: 8)
                    HStack(alignment: .center, spacing: 14) {
                        barWithLine(color: Color(themed: "#c5c0cf"))
                        nextButton
                    }
                }.frame(maxWidth: .infinity, minHeight: 105, alignment: .topLeading)
                    .overlay(alignment: .topTrailing) { cardMenu.offset(x: 10, y: -10) }
            }.background(alignment: .leading) {
                Button { openTitle() } label: {
                    Artwork(path: title.poster, title: title.name, initialsOnly: false).frame(width: 66, height: 99).clipShape(RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).frame(maxHeight: .infinity, alignment: .center)
            }.padding(12)
        }
    }
    private var gridContent: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Button { openTitle() } label: { Artwork(path: title.poster, title: title.name, initialsOnly: false).frame(height: 154).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    // One line each, ending in … when long, so every card in a row is the same height.
                    Button { openTitle() } label: { Text(title.name).font(.system(size: 17, weight: .semibold)).tracking(-0.425).foregroundStyle(HomeStyle.ink).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading) }
                        .buttonStyle(.plain).padding(.trailing, 34).padding(.top, 4).accessibilityIdentifier("progress-title-" + title.id)
                    if let glanceTime { timePill(glanceTime) } else { Color.clear.frame(height: 22) }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .topLeading)
                    .overlay(alignment: .topTrailing) { cardMenu.offset(x: 10, y: -10) }
            }
            VStack(alignment: .leading, spacing: 10) {
                barWithLine(color: Color(themed: "#c5c0cf"))
                HStack { Spacer(minLength: 0); nextButton }
            }
        }.padding(10)
    }
    /// The backdrop fills the card and fades to black on the right, where the text sits,
    /// so the artwork's subject stays visible on the left.
    private var heroContent: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                Text("LAST WATCHED").font(.system(size: 12, weight: .bold)).tracking(1.8)
                    // Native: white on the artwork (the accent blue was lost on warm pictures).
                    .foregroundStyle(ThemeStore.current.native ? Color.white.opacity(0.85) : HomeStyle.chipText)
                    .shadow(color: .black.opacity(0.5), radius: 4).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 10)
                Button { openTitle() } label: {
                    Text(title.name).font(.system(size: 24, weight: .bold)).tracking(-0.5).foregroundStyle(.white)
                        .lineLimit(2).multilineTextAlignment(.leading).shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                }.buttonStyle(.plain).accessibilityIdentifier("progress-title-" + title.id)
                if let glanceTime { timePill(glanceTime, onArtwork: true).padding(.top, 2) }
                HStack(alignment: .center, spacing: 14) { barWithLine(color: Color(themed: "#e6e2ef"), shadow: true); nextButton }.padding(.top, 8)
            }
        }.padding(16).frame(height: 178)
            .overlay(alignment: .topTrailing) { cardMenu.background(.black.opacity(0.35), in: Circle()).padding(8) }
            // On the artwork: light text in light mode too (Native).
            .environment(\.colorScheme, .dark)
    }
    /// − last watched episode + for shows; one Log watch button for movies. The circles are
    /// 36 pt, as in the owner's design, inside 44 pt tap targets.
    @ViewBuilder private var controls: some View {
        if compact && title.isSeries { homeStepper } else { cardControls }
    }
    /// Home's stepper, to the design: a 35 pt solid #3a3a40 −, "4 / 12" in 16 pt semibold, and a
    /// 36 pt accent +, 10 pt apart. Tap areas reach 44 pt without moving the circles.
    private var homeStepper: some View {
        HStack(spacing: 10) {
            Button { Task { await removeWatch() } } label: {
                actionIcon(.remove, symbol: "minus", size: 15).fontWeight(.bold).foregroundStyle(Color(themed: "#f5f5f7"))
                    .frame(width: 35, height: 35).background(Color(themed: "#3a3a40"), in: Circle())
                    .contentShape(Rectangle().inset(by: -5))
            }.buttonStyle(.plain).disabled(card != nil && card?.previous == nil).accessibilityLabel("Remove latest watch for \(title.name)")
            Text(card.map { "\($0.progress.watched) / \($0.progress.total)" } ?? "–").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(themed: "#f5f5f7"))
                .monospacedDigit().lineLimit(1).fixedSize().contentTransition(.numericText()).animation(reduceMotion ? nil : .snappy(duration: 0.2), value: card?.progress.watched)
                .accessibilityIdentifier("watch-count-" + title.id)
            Button { Task { await markWatch() } } label: {
                actionIcon(.mark, symbol: "plus", size: 17).fontWeight(.bold).foregroundStyle(WatchStyle.ink)
                    .frame(width: 36, height: 36).background(WatchStyle.fill, in: Circle())
                    .contentShape(Rectangle().inset(by: -4))
            }.buttonStyle(.plain).disabled(!markable).starBurst(trigger: sparks).accessibilityLabel("Mark next watch for \(title.name)")
        }.frame(height: 44)
    }
    private var cardControls: some View {
                // One container lets the card's glass controls render and morph together.
                GlassEffectContainer(spacing: 6) { HStack(spacing: 6) {
                if title.isSeries {
                    Button { Task { await removeWatch() } } label: { actionIcon(.remove, symbol: "minus", size: 16).frame(width: 36, height: 36).modifier(CardCircle(glass: hero || compact, tint: nil)).frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(card != nil && card?.previous == nil).accessibilityLabel("Remove latest watch for \(title.name)")
                    // The last watched episode ("E5"); the subtitle carries "of 8".
                    Text(cardText?.counter ?? "–").font(.system(size: 15, weight: .semibold)).monospacedDigit().contentTransition(.numericText()).animation(reduceMotion ? nil : .snappy(duration: 0.2), value: card?.progress.watched).frame(minWidth: 24).accessibilityIdentifier("watch-count-" + title.id)
                    Button { Task { await markWatch() } } label: { actionIcon(.mark, symbol: "plus", size: 17).foregroundStyle(WatchStyle.ink).frame(width: 36, height: 36).background(WatchStyle.fill, in: Circle()).frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(!markable).starBurst(trigger: sparks).accessibilityLabel("Mark next watch for \(title.name)")
                } else {
                    Button { Task { await markWatch() } } label: {
                        HStack(spacing: 8) { actionIcon(.mark, symbol: "checkmark", size: 17); Text(fraction > 0 ? "Watched" : "Log watch") }
                            .font(.system(size: 13, weight: .semibold)).frame(height: 34).padding(.horizontal, 14)
                            .foregroundStyle(WatchStyle.ink).background(WatchStyle.fill, in: Capsule()).contentShape(Capsule())
                    }.buttonStyle(.springPress).disabled(!markable).starBurst(trigger: sparks).accessibilityLabel((fraction > 0 ? "Watched " : "Log watch for ") + title.name)
                }
                } }.frame(height: 44)
    }
    private var cardMenu: some View {
        Menu {
            Button(title.favorite ? "Remove favorite" : "Favorite", systemImage: title.favorite ? "heart.slash" : "heart") { Task { await store.patchCard(title.id, values: ["favorite": !title.favorite]) } }
            Button(title.queued == true ? "Remove from Queue" : "Add to Queue", systemImage: "text.badge.plus") { Task { await store.patchCard(title.id, values: ["queued": title.queued != true]) } }
            if title.isSeries, let season = card?.season?.number {
                // Name the season: this completes only the card's season, never the whole show.
                Button(season == 0 ? "Complete Specials" : "Complete Season \(season)", systemImage: "checkmark.circle") { Task { await store.completeCardSeason(title.id, season: season) } }
            }
            if card?.previous != nil {
                Button("Undo last watch", systemImage: "arrow.uturn.backward") { Task { await removeWatch() } }
            }
            Button("Dropped", systemImage: "stop.circle") { Task { await store.patchCard(title.id, values: ["status": "dropped"]) } }
            Button("Notes", systemImage: "note.text") { showNotes = true }
        } label: { DiaryIcon(name: "ellipsis", size: 19).frame(width: 44, height: 44) }
            .disabled(cardBusy || store.needsMutationRefresh).foregroundStyle(Color(themed: "#c5c0cf")).accessibilityLabel("More options for " + title.name).accessibilityIdentifier("progress-menu-" + title.id)
    }
    // MARK: Glance (owner's design): "S1 · E1 of 12 · 4h 24m left", a bar with its percent, "+ E2".

    /// "S1 · E12 of 28 · 43%" centred just above a plain bar (the owner's fix: the line used to sit
    /// under the title and the percent beside the bar, which crowded the card).
    private func barWithLine(color: Color, shadow: Bool = false) -> some View {
        VStack(spacing: 6) {
            Text(progressLine).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).monospacedDigit()
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .center)
                .modifier(TextShadow(on: shadow))
            GeometryReader { proxy in
                Capsule().fill(Color.primary.opacity(0.14))
                    .overlay(alignment: .leading) { Capsule().fill(.tint).frame(width: max(fraction > 0 ? 6 : 0, proxy.size.width * fraction)) }
            }.frame(height: 5)
        }.accessibilityElement(children: .ignore).accessibilityLabel(progressLine + ", \(Int((fraction * 100).rounded())) percent watched")
            .accessibilityIdentifier("watch-progress-" + title.id)
    }
    /// "S1 · E12 of 28 · 43%"; movies: "Movie · 1h 54m".
    private var progressLine: String {
        guard title.isSeries else { return (["Movie"] + [title.runtimeMinutes.map(DiaryDate.duration)].compactMap { $0 }).joined(separator: " · ") }
        guard let card else { return title.categoryName }
        let season = card.season.map { $0.number == 0 ? "Specials" : "S\($0.number)" }
        let percent = fraction > 0 ? "\(Int((fraction * 100).rounded()))%" : nil
        return [season, "E\(card.progress.watched) of \(card.progress.total)", percent].compactMap { $0 }.joined(separator: " · ")
    }
    /// The time left as a small pill with a clock: lilac on the cards, a dark wash over artwork.
    private func timePill(_ text: String, onArtwork: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock").font(.system(size: 10, weight: .semibold))
            Text(text).lineLimit(1)
        }.font(.system(size: 12, weight: .semibold)).monospacedDigit()
            .foregroundStyle(onArtwork ? Color(themed: "#ece8f6") : HomeStyle.chipText)
            .padding(.horizontal, 8).frame(height: 22)
            .background(onArtwork ? AnyShapeStyle(Color.black.opacity(0.45)) : AnyShapeStyle(HomeStyle.chip), in: Capsule())
            .fixedSize()
    }
    /// "6h 24m left" under the title ("24m" before the first episode); nil when unknown.
    private var glanceTime: String? {
        guard title.isSeries, let card else { return nil }
        return remaining.flatMap { $0 > 0 ? DiaryDate.duration($0) + (card.progress.watched > 0 ? " left" : "") : nil }
    }
    /// "+ E2", "▶ Start" before the first episode, "Log watch" for movies: the bright lavender gradient.
    private var nextButton: some View {
        let starting = title.isSeries && card.map { $0.progress.watched == 0 } == true
        let label: String = {
            guard title.isSeries else { return fraction > 0 ? "Watched" : "Log watch" }
            if starting { return "Start" }
            return card?.next.map { "E\($0.number)" } ?? "Done"
        }()
        return Button { Task { await markWatch() } } label: {
            HStack(spacing: 6) {
                actionIcon(.mark, symbol: starting ? "play.fill" : title.isSeries ? "plus" : "checkmark", size: starting ? 11 : 14).fontWeight(.bold)
                Text(label).font(.system(size: 15, weight: .bold)).lineLimit(1)
            }.foregroundStyle(WatchStyle.ink)
                .padding(.horizontal, 16).frame(height: 40)
                .background { Capsule().fill(WatchStyle.fill) }
                .fixedSize()
                // A 40 pt pill, with the 44 pt tap target the platform asks for.
                .frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.springPress).disabled(!markable).opacity(markable ? 1 : 0.5).starBurst(trigger: sparks)
            .accessibilityLabel((title.isSeries ? (starting ? "Start " : "Mark ") + label : label) + ", " + title.name)
            .accessibilityIdentifier("progress-next-" + title.id)
    }

    private var cardText: GlanceCardText? {
        guard let card else { return nil }
        if !title.isSeries { return .movie(watched: card.progress.watched > 0, runtimeMinutes: title.runtimeMinutes) }
        return .series(season: card.season?.number, watched: card.progress.watched, total: card.progress.total,
                       next: card.next?.number, remainingMinutes: remaining)
    }
    private var cornerRadius: CGFloat { hero ? 20 : compact ? 12 : 14 }
    private var scrim: LinearGradient {
        hero
            ? LinearGradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0.2), location: 0.3),
                                     .init(color: .black.opacity(0.82), location: 0.55), .init(color: .black.opacity(0.94), location: 1)],
                             startPoint: .leading, endPoint: .trailing)
            : LinearGradient(colors: [.black.opacity(compact ? 0.05 : 0.35), .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
    }
    private var cardBusy: Bool { store.cardActions[title.id] != nil }
    @ViewBuilder private func actionIcon(_ action: DiaryStore.CardAction, symbol: String, size: CGFloat) -> some View {
        if store.cardActions[title.id] == action { ProgressView().controlSize(.small).tint(action == .remove ? theme.accent : theme.ink).frame(width: size, height: size).accessibilityLabel("Saving") }
        else if reduceMotion { Image(systemName: symbol).font(.system(size: size)) }
        else { Image(systemName: symbol).font(.system(size: size)).symbolEffect(.bounce, value: watchFeedback) }
    }
    private var canMark: Bool {
        guard !cardBusy, !store.needsMutationRefresh, card != nil else { return false }
        return markable
    }
    /// Whether there's anything to mark at all. Only this dims the button: a save or refresh in
    /// progress (or progress still loading) doesn't, so the hero's buttons don't flash on opening
    /// the app or pulling to refresh; a tap then simply waits.
    private var markable: Bool {
        guard let card else { return true }
        return title.isSeries ? card.next != nil : card.progress.watched == 0
    }
    private var fraction: Double { guard let card, card.progress.total > 0 else { return 0 }; return min(1, Double(card.progress.watched) / Double(card.progress.total)) }
    private var cardBackdrop: String? { ["again", "night", "severance"].contains(title.id) ? "scene:" + title.id : title.backdrop ?? title.poster }
    private var remaining: Int? {
        guard let card else { return nil }
        if !title.isSeries { return title.runtimeMinutes.map { card.progress.watched == 0 ? $0 : 0 } }
        // The time left needs the season's runtimes, which can arrive a moment after the card:
        // the last known time (for the same progress) stays meanwhile, so "about 4h 48m" doesn't
        // drop out and come back when Home opens.
        let season = card.season?.number ?? 1, key = title.id + "#" + String(season)
        let value = store.seasonProgress(title, season: season).remainingMinutes
        if let value, value > 0 { Self.lastRemaining[key] = (card.progress.watched, value); return value }
        if let kept = Self.lastRemaining[key], kept.watched == card.progress.watched { return kept.minutes }
        return value
    }
    @MainActor private static var lastRemaining: [String: (watched: Int, minutes: Int)] = [:]
    private func loadCard() async {
        guard !store.needsSignIn, !Task.isCancelled else { return }
        do {
            let result = try await store.card(title); guard !Task.isCancelled else { return }
            if !title.isSeries || result.progress.total > 0 { Self.lastReal[title.id] = result }
            loadedCard = result
        }
        catch is CancellationError { }
        catch { if !Task.isCancelled { store.error = error.localizedDescription } }
    }
    private func openTitle() { guard Date.now >= suppressNavigationUntil else { return }; router.openTitle(title.id, tab: router.selectedTab) }
    private func markWatch() async {
        guard canMark else { return }
        let previous = card?.progress.watched
        await store.markNext(title, expectedEpisode: card?.next?.id); await loadCard()
        if let previous, let current = card?.progress.watched, current > previous { watchFeedback += 1; sparks += 1 }
    }
    private func removeWatch() async {
        guard !cardBusy, !store.needsMutationRefresh, card?.previous != nil else { return }
        let previous = card?.progress.watched
        await store.removeLatest(title, expected: card?.previous); await loadCard()
        if let previous, let current = card?.progress.watched, current < previous { watchFeedback += 1 }
    }
}
