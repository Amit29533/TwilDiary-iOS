import SwiftUI
import UIKit
import TwilDiaryCore

enum DiaryTheme: String, CaseIterable, Identifiable {
    case twilight, ocean, jade, rose, amber, glass
    var id: Self { self }
    var name: String { self == .glass ? "Liquid Glass" : rawValue.capitalized }
    var text: Color { Color(webHex: self == .glass ? "#f5f5f7" : "#f3f0f7") }
    var muted: Color { Color(webHex: self == .glass ? "#a6a6af" : "#a09aa9") }
    var field: Color { Color(webHex: self == .glass ? "#101013" : "#111115") }
    var detail: String {
        switch self {
        case .twilight: "The original violet"
        case .ocean: "Clear, cool blue"
        case .jade: "A quiet mint glow"
        case .rose: "Soft pink after dark"
        case .amber: "Warm cinema gold"
        case .glass: "Liquid light on pure black"
        }
    }
    var strong: Color {
        switch self {
        case .twilight: Color(webHex: "#9d76f4")
        case .ocean: Color(webHex: "#498de8")
        case .jade: Color(webHex: "#36ae8c")
        case .rose: Color(webHex: "#d66d9f")
        case .amber: Color(webHex: "#ca8e36")
        case .glass: Color(webHex: "#87bde8")
        }
    }
    var ink: Color {
        switch self { case .twilight: Color(webHex: "#21182e"); case .ocean: Color(webHex: "#102039"); case .jade: Color(webHex: "#102820"); case .rose: Color(webHex: "#321622"); case .amber: Color(webHex: "#2c2010"); case .glass: Color(webHex: "#132332") }
    }
    var accent: Color {
        switch self {
        case .twilight: Color(webHex: "#b795f6")
        case .ocean: Color(webHex: "#82b8ff")
        case .jade: Color(webHex: "#79d8bc")
        case .rose: Color(webHex: "#f4a2c6")
        case .amber: Color(webHex: "#edbe73")
        case .glass: Color(webHex: "#c4e5ff")
        }
    }
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
    func diaryPanel(padding: CGFloat = 16, radius: CGFloat = 22, accentBorder: Bool = false) -> some View {
        modifier(DiaryPanelModifier(padding: padding, radius: radius, accentBorder: accentBorder))
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
    var tint = Color(webHex: "#c5c0cf")
    var size: CGFloat = 44
    var body: some View {
        DiaryIcon(name: icon, size: size * 0.43).foregroundStyle(tint).frame(width: size, height: size)
            .background(.white.opacity(0.08), in: Circle()).frame(width: max(44, size), height: max(44, size)).contentShape(Circle())
    }
}

/// Compact 44 pt capsule buttons: the accent fill for the main action, an outline for the rest.
struct DiaryCapsuleButtonStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, prominent: prominent) }
    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @AppStorage("theme") private var theme = DiaryTheme.twilight
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            let destructive = configuration.role == .destructive
            configuration.label.font(.system(size: 15, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 16).frame(minHeight: 44)
                .foregroundStyle(prominent ? theme.ink : destructive ? Color(webHex: "#ff8a80") : theme.accent)
                .background(prominent ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.white.opacity(0.07)), in: Capsule())
                .overlay { if !prominent { Capsule().strokeBorder(.white.opacity(0.12)) } }
                .opacity(enabled ? 1 : 0.45).contentShape(Capsule())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
                .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
        }
    }
}
extension ButtonStyle where Self == DiaryCapsuleButtonStyle {
    static var diaryPrimary: DiaryCapsuleButtonStyle { DiaryCapsuleButtonStyle(prominent: true) }
    static var diarySecondary: DiaryCapsuleButtonStyle { DiaryCapsuleButtonStyle(prominent: false) }
}

/// A filter as a pill that opens its menu, as on Canvas and Explore.
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
        }.foregroundStyle(active ? theme.accent : Color(webHex: "#f3f0f7"))
            .padding(.horizontal, 14).frame(height: 38)
            .background(active ? theme.accent.opacity(0.12) : .white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(active ? theme.accent.opacity(0.5) : .white.opacity(0.14)))
            .frame(minHeight: 44).contentShape(Capsule())
    }
}

/// The official Trakt mark and TMDB logo, used wherever the app names those services.
struct BrandLogo: View {
    enum Service { case trakt, tmdb }
    let service: Service
    var size: CGFloat = 34
    var body: some View {
        Group {
            switch service {
            case .trakt: Image("trakt-mark").resizable().scaledToFit()
            case .tmdb: Image("tmdb-logo").resizable().scaledToFit().padding(size * 0.16)
                .background(Color(webHex: "#0d253f"), in: RoundedRectangle(cornerRadius: size * 0.225))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
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

/// A tab page's header. Tab pages split it: `.buttons` stays pinned over the page as frosted
/// glass, and `.title` is the scroll's first row, sliding up beneath them. `.full` draws both.
struct PageHeader: View {
    enum Part { case full, title, buttons }
    let name: String
    var count: String? = nil
    var onSearch: (() -> Void)? = nil
    /// Kept for callers; every search button is now a glass circle.
    var circledSearch = false
    /// Home draws the header over the Continue watching backdrop.
    var overArtwork = false
    /// Library's Select button, beside search.
    var onSelect: (() -> Void)? = nil
    var height: CGFloat = 56
    var part: Part = .full
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var taps: [Double] = []
    @State private var angle = 0.0
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        HStack(spacing: 10) {
            if part == .title { Color.clear.frame(width: 44, height: 44) } else { logo }
            if part != .buttons { title }
            Spacer(minLength: 0)
            if part == .title {
                // Keeps the title clear of the pinned buttons above it.
                Color.clear.frame(width: CGFloat((onSelect == nil ? 0 : 1) + (onSearch == nil ? 0 : 1)) * 54, height: 1)
            } else {
                if let onSelect { glassButton("circle-check", label: "Select titles", id: "library-select", action: onSelect) }
                if let onSearch { glassButton("search", label: name == "Library" ? "Search library" : "Search", id: "search-" + name.lowercased(), action: onSearch) }
            }
        }.frame(height: height).padding(.horizontal, 14)
            .background { if part == .full && theme != .glass && !overArtwork { Color(webHex: ["Library", "Trash"].contains(name) ? "#0e0d13" : "#050507") } }
            .background(alignment: .top) { if part == .buttons { statusScrim } }
    }
    private var logo: some View {
        Button {
            let gesture = RandomPick.tap(previous: taps, now: ProcessInfo.processInfo.systemUptime)
            taps = gesture.taps
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.65)) { angle += 270 }
            if gesture.triggered { router.presentRandomPick() }
        } label: {
            BrandMark().fill(theme.accent).frame(width: 22, height: 22).rotationEffect(.degrees(angle))
                .frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: Circle())
                // The tap shape sits outside the glass, as on Glance's − / +; otherwise the interactive glass takes the tap.
                .frame(width: 44, height: 44).contentShape(Circle())
        }.buttonStyle(.plain).sensoryFeedback(.impact(weight: .light), trigger: angle).accessibilityLabel("Spin TwilDiary logo").accessibilityHint("Tap three times for a random pick").accessibilityIdentifier("random-pick-logo")
    }
    @ViewBuilder private var title: some View {
        if name == "TwilDiary" {
            HStack(spacing: 0) {
                Text("Twil").foregroundStyle(Color(webHex: "#f3f0f7"))
                Text("Diary").foregroundStyle(LinearGradient(colors: [.white, theme.accent], startPoint: .leading, endPoint: .trailing))
            }.font(.system(size: 26, weight: .bold)).tracking(-1.25)
        } else { Text(name).font(.system(size: 26, weight: .bold)).tracking(-1.2).foregroundStyle(Color(webHex: "#f3f0f7")).lineLimit(1).minimumScaleFactor(0.7).accessibilityIdentifier("page-title") }
        if let count { Text(count).font(.system(size: 13)).foregroundStyle(Color(webHex: "#a09aa9")).lineLimit(1) }
    }
    private func glassButton(_ icon: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DiaryIcon(name: icon, size: 20).foregroundStyle(Color(webHex: "#e6e2ec")).frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: Circle()).frame(width: 44, height: 44).contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }
    /// Under the status bar, so rows scrolling up behind the pinned buttons never clash with it.
    private var statusScrim: some View {
        LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
            .frame(height: 74).offset(y: -54).ignoresSafeArea(edges: .top).allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    let label: String
    var autoFocus = false
    var focusRevision = 0
    var dismissRevision = 0
    @State private var didAutoFocus = false
    @FocusState private var focused: Bool
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        HStack(spacing: 10) {
            DiaryIcon(name: "search", size: 19).foregroundStyle(Color(webHex: "#a09aa9"))
            TextField(placeholder, text: $text).font(.system(size: 16)).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).focused($focused).onSubmit { focused = false }.accessibilityLabel(label)
            if !text.isEmpty { Button { text = ""; focused = true } label: { DiaryIcon(name: "x", size: 16).frame(width: 26, height: 32) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
        }.padding(.horizontal, 14).frame(minHeight: 48).background { DiaryControlSurface(shape: RoundedRectangle(cornerRadius: 12), field: true) }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? theme.accent.opacity(0.65) : .clear))
            .onDisappear { focused = false }
            .onChange(of: focusRevision) { _, _ in focused = true }
            .onChange(of: dismissRevision) { _, _ in focused = false }
            .task { if autoFocus && !didAutoFocus { didAutoFocus = true; focused = true } }
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
    @Environment(\.displayScale) private var displayScale
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var loadedArtwork: PublicArtworkBitmap?
    @State private var loadedRequest: PublicArtworkRequest?
    var body: some View {
        GeometryReader { proxy in
          let request = PublicArtworkRequest(path: path, pixels: Double(max(proxy.size.width, proxy.size.height) * displayScale))
          ZStack {
            if initialsOnly { LinearGradient(colors: [tint, theme.initialsBase], startPoint: .topLeading, endPoint: .bottomTrailing) }
            else {
                LinearGradient(colors: [Color(webHex: "#243638"), Color(webHex: "#17151e"), Color(webHex: "#17151e")], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [theme.placeholderGlow, .clear], center: UnitPoint(x: 0.8, y: 0.05), startRadius: 0, endRadius: max(proxy.size.width, proxy.size.height) * 0.7)
            }
            if let path, path.hasPrefix("asset:") || path.hasPrefix("/demo/") || path.hasPrefix("scene:"), let image = DemoArtwork.image(path) { Image(uiImage: image).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped() }
            else if let image = fixtureImage(path) { Image(uiImage: image).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped() }
            else if let request {
                // While loading, only the gradient shows: the named placeholder appears
                // only after a load failed, so new cells no longer flash title text
                // before their poster. A size change keeps the previous bitmap of the
                // same image until the new size is decoded.
                let current = loadedRequest == request ? loadedArtwork : nil
                let sameImage = loadedRequest?.url == request.url ? loadedArtwork : nil
                if let bitmap = current ?? PublicArtworkCache.shared.cached(request) ?? sameImage {
                    Image(decorative: bitmap.image, scale: displayScale).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                } else if loadedRequest == request { placeholder(size: proxy.size) }
            } else { placeholder(size: proxy.size) }
          }.frame(width: proxy.size.width, height: proxy.size.height).clipped()
            .task(id: request) {
                guard fixtureImage(path) == nil else { return }
                guard let request else { loadedArtwork = nil; loadedRequest = nil; return }
                if let saved = PublicArtworkCache.shared.cached(request) { loadedRequest = request; loadedArtwork = saved; return }
                let bitmap = await PublicArtworkCache.shared.image(request)
                guard !Task.isCancelled else { return }
                loadedRequest = request; loadedArtwork = bitmap
            }
        }.contentShape(Rectangle()).accessibilityHidden(true)
    }
    private var tint: Color {
        let values = ["#543173", "#514779", "#294959", "#345682", "#477062", "#73435f"]
        return Color(webHex: values[title.unicodeScalars.reduce(0) { $0 + Int($1.value) } % values.count])
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
            VStack(spacing: 16) {
                DiaryIcon(name: "clapperboard", size: 28)
                Text(title).font(.system(size: 12.8, weight: .semibold)).lineSpacing(3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(Color(webHex: "#d2c4e4")).padding(.horizontal, size.width * 0.14).padding(.vertical, size.height * 0.14)
        }
    }
    private var initials: some View { Text(title.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()).font(.system(size: 24, weight: .bold)).foregroundStyle(Color(webHex: "#eee6fb99")) }
}

struct RatingBadge: View {
    let score: Double
    var community = true
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill").font(.system(size: community ? 10 : 12))
                .foregroundStyle(Color(webHex: community ? "#ffe030" : "#f4d06a"))
            Text(score, format: .number.precision(.fractionLength(1))).frame(minHeight: community ? 17.25 : 18)
        }.font(.system(size: community ? 11.5 : 12, weight: community ? .medium : .semibold))
            .foregroundStyle(Color(webHex: community ? "#f5f5f5" : "#f3f0f7"))
            // No text shadow: the badge already sits on a dark capsule, and a blurred
            // shadow costs an offscreen render pass for every poster in a scrolling grid.
            .padding(.horizontal, community ? 6 : 4).padding(.vertical, 3)
            .background(Color(webHex: community ? "#00000099" : "#07090cdd"), in: RoundedRectangle(cornerRadius: community ? 99 : 7))
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
            Artwork(path: title.poster, title: title.name, initialsOnly: !personalRating).aspectRatio(2 / 3, contentMode: .fit)
                .overlay(alignment: personalRating ? .bottomLeading : .topLeading) { if let score = displayedScore { RatingBadge(score: score, community: !personalRating).padding(6) } }
                .overlay(alignment: .bottom) { if !personalRating && title.status != "completed" && progress > 0 { GeometryReader { proxy in Rectangle().fill(theme.accent.opacity(0.267)).overlay(alignment: .leading) { Rectangle().fill(theme.accent).frame(width: proxy.size.width * progress) } }.frame(height: 4) } }
                .overlay(alignment: .bottomTrailing) { statusBadge }
                .overlay(alignment: personalRating ? .topLeading : .bottomLeading) { availabilityBadges.padding(8) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(title.name).font(.system(size: 15, weight: .semibold)).lineSpacing(2.3).foregroundStyle(Color(webHex: "#f3f0f7")).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }.contentShape(Rectangle()).accessibilityElement(children: .ignore).accessibilityLabel(title.name).accessibilityValue(accessibleDetails)
    }
    private var displayedScore: Double? { personalRating ? title.score : store.publicScore(title, source: ratingSource) }
    private var present: Bool { !archived && store.hasPresentLocation(title.id) }
    private var accessibleDetails: String {
        [title.categoryName, archived ? "In Trash" : title.status.capitalized, displayedScore.map { "Rating " + $0.formatted(.number.precision(.fractionLength(1))) }, title.status != "completed" && progress > 0 ? "\(Int((progress * 100).rounded())) percent watched" : nil, title.queued == true ? "In Queue" : nil, !personalRating && present ? "On your PC" : nil].compactMap { $0 }.joined(separator: ", ")
    }
    @ViewBuilder private var statusBadge: some View {
        if personalRating {
            DiaryIcon(name: title.statusIconName, size: 18).foregroundStyle(Color(webHex: title.status == "planned" ? "#b9dcff" : "#d3d4dc"))
                .frame(width: 26, height: 26).background(Color(webHex: "#080a10e8"), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.42))).padding(6)
        } else if title.status == "completed" && !archived {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(webHex: "#10291b")).frame(width: 26, height: 26)
                .background(Color(webHex: "#78e4ab"), in: Circle()).padding(8)
        }
    }
    private var availabilityBadges: some View {
        VStack(alignment: .leading, spacing: 5) {
            if title.queued == true {
                DiaryIcon(name: "download", size: 14).foregroundStyle(theme.accent).frame(width: 27, height: 27)
                    .background(Color(webHex: "#080c10d9"), in: RoundedRectangle(cornerRadius: 7))
            }
            if present && !personalRating {
                DiaryIcon(name: "monitor", size: 14).foregroundStyle(Color(webHex: "#9edbc4"))
                    .frame(width: 27, height: 27).background(Color(webHex: "#080c10b8"), in: RoundedRectangle(cornerRadius: 7))
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
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The accent pill glides from one category to the next instead of jumping.
    @Namespace private var pill
    var body: some View {
        HStack(spacing: 6) {
            ForEach(LibraryCategory.allCases) { category in
                let selected = selection == category
                Button { withAnimation(Motion.spring(reduceMotion)) { selection = category } } label: {
                    Text(category.rawValue).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? theme.ink : Color(webHex: "#c5c0cf"))
                        .padding(.horizontal, 16).frame(minHeight: 40)
                        .background { if selected { Capsule().fill(theme.accent).matchedGeometryEffect(id: "category-pill", in: pill) } }
                        .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("category-" + category.rawValue.lowercased()).accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 14).padding(.vertical, 4)
            .animation(Motion.spring(reduceMotion), value: selection)
            .sensoryFeedback(.selection, trigger: selection)
    }
}

/// "Recently updated ▾" on the left, screen tools (layout toggle, filters) on the right.
struct SortMenuRow<Option: Hashable & Identifiable, Trailing: View>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    let identifier: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Sort", selection: $selection) { ForEach(options) { Text(label($0)).tag($0) } }
            } label: {
                // Plain text on Glance by the owner's choice: that row is tight on space.
                HStack(spacing: 6) { Text(label(selection)); DiaryIcon(name: "chevron-down", size: 14) }
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Color(webHex: "#c5c0cf"))
                    .frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier(identifier).accessibilityLabel("Sort").accessibilityValue(label(selection))
            Spacer(minLength: 0)
            trailing
        }.padding(.leading, 18).padding(.trailing, 8)
    }
}

struct SectionHeading<Trailing: View>: View {
    let name: String
    @ViewBuilder var trailing: Trailing
    var body: some View { HStack(spacing: 8) { Text(name).font(.system(size: 19, weight: .semibold)).tracking(-0.5); Spacer(minLength: 4); trailing.font(.system(size: 12, weight: .semibold)) }.frame(minHeight: 32) }
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
    private var card: WatchCard? { loadedCard ?? store.cachedCard(title) }
    @State private var watchFeedback = 0
    /// New watches only (not removals): the mark button throws a star burst.
    @State private var sparks = 0
    @State private var suppressNavigationUntil = Date.distantPast
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
                                else { Rectangle().fill(theme.field) }
                            }.frame(width: proxy.size.width, height: proxy.size.height).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Open " + title.name).accessibilityIdentifier("progress-cover-" + title.id)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(compact ? 0 : 0.17)))
        }.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .task(id: store.cardRevision(title.id)) { await loadCard() }
            .sensoryFeedback(.success, trigger: watchFeedback)
    }
    /// Home's Continue watching text over the page backdrop (owner's design): title, "S2 · E3 of 8",
    /// the bar with "38% complete" and the time left, then the same − / + controls as Glance.
    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Text("CONTINUE WATCHING").font(.system(size: 13, weight: .medium)).tracking(1.2).foregroundStyle(.white.opacity(0.78))
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1).accessibilityLabel("Continue watching").accessibilityAddTraits(.isHeader)
            Button { openTitle() } label: {
                Text(title.name).font(.system(size: 26, weight: .bold)).tracking(-0.6).foregroundStyle(.white)
                    .lineLimit(3).multilineTextAlignment(.leading).shadow(color: .black.opacity(0.55), radius: 8, y: 2)
            }.buttonStyle(.plain).accessibilityIdentifier("progress-title-" + title.id)
            Text(homeLine).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.88)).lineLimit(1)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { proxy in Capsule().fill(.white.opacity(0.2)).overlay(alignment: .leading) { Capsule().fill(.tint).frame(width: proxy.size.width * fraction) } }.frame(height: 6)
                    HStack(spacing: 8) {
                        // Share and episode count come from the same card, so they always agree.
                        Text(card == nil ? "Checking progress…" : "\(Int((fraction * 100).rounded()))% complete")
                        Spacer(minLength: 0)
                        if let left = cardText?.timeLeft { Text(left).monospacedDigit() }
                    }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }.frame(maxWidth: 240)
                Spacer(minLength: 0)
                controls
            }.padding(.top, 6)
        }.padding(.horizontal, 12).padding(.bottom, 4).frame(height: 196)
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
            // The text column sets the card's height and the poster fills it, top to bottom: no strip under it.
            HStack(alignment: .top, spacing: 14) {
                Color.clear.frame(width: 86)
                VStack(alignment: .leading, spacing: 4) {
                    Button { openTitle() } label: { Text(title.name).font(.system(size: 17, weight: .semibold)).tracking(-0.425).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading) }
                        .buttonStyle(.plain).padding(.trailing, 34).accessibilityIdentifier("progress-title-" + title.id)
                    subtitleLine.font(.system(size: 13)).lineLimit(2)
                    progressBlock.padding(.top, 8)
                    HStack { Spacer(minLength: 0); controls }.padding(.top, 2)
                }.frame(maxWidth: .infinity, alignment: .topLeading)
                    .overlay(alignment: .topTrailing) { cardMenu.offset(x: 10, y: -10) }
            }.background(alignment: .leading) {
                Button { openTitle() } label: {
                    Artwork(path: title.poster, title: title.name, initialsOnly: false).frame(width: 86).frame(maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            }.padding(12)
        }
    }
    private var gridContent: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Button { openTitle() } label: { Artwork(path: title.poster, title: title.name, initialsOnly: false).frame(height: 154).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    Button { openTitle() } label: { Text(title.name).font(.system(size: 17, weight: .semibold)).tracking(-0.425).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading) }
                        .buttonStyle(.plain).padding(.trailing, 34).accessibilityIdentifier("progress-title-" + title.id)
                    subtitleLine.font(.system(size: 13)).lineSpacing(3.5).fixedSize(horizontal: false, vertical: true).frame(minHeight: 20, alignment: .topLeading)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .topLeading)
                    .overlay(alignment: .topTrailing) { cardMenu.offset(x: 10, y: -10) }
            }
            VStack(alignment: .leading, spacing: 10) {
                progressBlock
                controls
            }
        }.padding(10)
    }
    /// The backdrop fills the card and fades to black on the right, where the text sits,
    /// so the artwork's subject stays visible on the left.
    private var heroContent: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 34)
                Button { openTitle() } label: {
                    Text(title.name).font(.system(size: 21, weight: .bold)).tracking(-0.5).foregroundStyle(.white)
                        .lineLimit(2).multilineTextAlignment(.leading).shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                }.buttonStyle(.plain).accessibilityIdentifier("progress-title-" + title.id)
                subtitleLine.font(.system(size: 13)).lineLimit(2)
                progressBlock.padding(.top, 8)
                Spacer(minLength: 8)
                HStack { Spacer(minLength: 0); controls }
            }.containerRelativeFrame(.horizontal) { width, _ in width * 0.52 }
        }.padding(14).frame(height: 208)
            .overlay(alignment: .topTrailing) { cardMenu.background(.black.opacity(0.35), in: Circle()).padding(8) }
    }
    /// The bar with "63% of season 1" and the time left; long-running seasons show no share.
    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            if card == nil || cardText?.progressLabel != nil {
                GeometryReader { proxy in Capsule().fill(.white.opacity(0.16)).overlay(alignment: .leading) { Capsule().fill(.tint).frame(width: proxy.size.width * fraction) } }.frame(height: 6)
            }
            // Narrow grid cards stack the time left under the share instead of truncating it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { progressText; Spacer(minLength: 0); timeLeftText }
                VStack(alignment: .leading, spacing: 2) { progressText; timeLeftText }
            }.font(.system(size: 13)).foregroundStyle(Color(webHex: "#c5c0cf")).lineLimit(1)
        }
    }
    // Before the card loads, say so instead of showing a made-up zero.
    private var progressText: some View { Text(card == nil ? "Checking progress…" : cardText?.progressLabel ?? "").fixedSize() }
    @ViewBuilder private var timeLeftText: some View { if let left = cardText?.timeLeft { Text(left).monospacedDigit().fixedSize() } }
    /// − last watched episode + for shows; one Log watch button for movies. The circles are
    /// 36 pt, as in the owner's design, inside 44 pt tap targets.
    private var controls: some View {
                // One container lets the card's glass controls render and morph together.
                GlassEffectContainer(spacing: 6) { HStack(spacing: 6) {
                if title.isSeries {
                    Button { Task { await removeWatch() } } label: { actionIcon(.remove, symbol: "minus", size: 16).frame(width: 36, height: 36).glassEffect(.regular.interactive(), in: Circle()).frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(cardBusy || store.needsMutationRefresh || card?.previous == nil).accessibilityLabel("Remove latest watch for \(title.name)")
                    // The last watched episode ("E5"); the subtitle carries "of 8".
                    Text(cardText?.counter ?? "–").font(.system(size: 15, weight: .semibold)).monospacedDigit().contentTransition(.numericText()).animation(reduceMotion ? nil : .snappy(duration: 0.2), value: card?.progress.watched).frame(minWidth: 24).accessibilityIdentifier("watch-count-" + title.id)
                    Button { Task { await markWatch() } } label: { actionIcon(.mark, symbol: "plus", size: 17).foregroundStyle(theme.ink).frame(width: 36, height: 36).glassEffect(.regular.tint(theme.accent).interactive(), in: Circle()).frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(!canMark).starBurst(trigger: sparks).accessibilityLabel("Mark next watch for \(title.name)")
                } else {
                    Button { Task { await markWatch() } } label: {
                        HStack(spacing: 8) { actionIcon(.mark, symbol: "checkmark", size: 17); Text(fraction > 0 ? "Watched" : "Log watch") }
                            .font(.system(size: 13, weight: .semibold)).frame(height: 22).padding(.horizontal, 6)
                            .foregroundStyle(theme.ink)
                    }.buttonStyle(.glassProminent).disabled(!canMark).starBurst(trigger: sparks).accessibilityLabel((fraction > 0 ? "Watched " : "Log watch for ") + title.name)
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
            Button("Dropped", systemImage: "stop.circle") { Task { await store.patchCard(title.id, values: ["status": "dropped"]) } }
            Button("Notes", systemImage: "note.text") {
                router.paths[router.selectedTab, default: NavigationPath()].append(SavedTitleRoute(id: title.id, season: card?.season?.number ?? 1, focusEpisodes: false, focusNotes: true))
            }
        } label: { DiaryIcon(name: "ellipsis", size: 19).frame(width: 44, height: 44) }
            .disabled(cardBusy || store.needsMutationRefresh).foregroundStyle(Color(webHex: "#c5c0cf")).accessibilityLabel("More options for " + title.name).accessibilityIdentifier("progress-menu-" + title.id)
    }
    /// "S1 · Watched 5 of 8 · Next E6" (see GlanceCardText).
    private var subtitleLine: some View {
        Text(cardText?.subtitle ?? (title.isSeries ? title.categoryName : "Movie"))
            .foregroundStyle(Color(webHex: "#c5c0cf")).shadow(color: .black.opacity(hero ? 0.6 : 0), radius: 4, y: 1)
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
        guard !cardBusy, !store.needsMutationRefresh, let card else { return false }
        return title.isSeries ? card.next != nil : card.progress.watched == 0
    }
    private var fraction: Double { guard let card, card.progress.total > 0 else { return 0 }; return min(1, Double(card.progress.watched) / Double(card.progress.total)) }
    private var cardBackdrop: String? { ["again", "night", "severance"].contains(title.id) ? "scene:" + title.id : title.backdrop ?? title.poster }
    private var remaining: Int? {
        guard let card else { return nil }
        if !title.isSeries { return title.runtimeMinutes.map { card.progress.watched == 0 ? $0 : 0 } }
        return store.seasonProgress(title, season: card.season?.number ?? 1).remainingMinutes
    }
    private func loadCard() async {
        guard !store.needsSignIn, !Task.isCancelled else { return }
        do { let result = try await store.card(title); guard !Task.isCancelled else { return }; loadedCard = result }
        catch is CancellationError { }
        catch { if !Task.isCancelled { store.error = error.localizedDescription } }
    }
    private func openTitle() { guard Date.now >= suppressNavigationUntil else { return }; router.openTitle(title.id, tab: router.selectedTab) }
    private func markWatch() async {
        let previous = card?.progress.watched
        await store.markNext(title, expectedEpisode: card?.next?.id); await loadCard()
        if let previous, let current = card?.progress.watched, current > previous { watchFeedback += 1; sparks += 1 }
    }
    private func removeWatch() async {
        let previous = card?.progress.watched
        await store.removeLatest(title, expected: card?.previous); await loadCard()
        if let previous, let current = card?.progress.watched, current < previous { watchFeedback += 1 }
    }
}
