import SwiftUI
import UIKit
import TwilDiaryCore

/// Shared title header for saved titles and unimported catalog previews.
struct TitleHero<Ratings: View>: View {
    let name: String
    let poster: String?
    /// Shown above the name, like "Sci-Fi & Fantasy • Drama".
    let genres: [String]
    let year: Int?
    let category: String
    let runtime: Int?
    let series: Bool
    let summary: String
    @Binding var expanded: Bool
    let onNameScrolled: ((CGFloat) -> Void)?
    let ratings: Ratings
    /// The cover art behind the header: press and hold its visible part to see it full screen.
    let backdrop: String?
    /// Age rating, status and network chips under the genres.
    let extras: TitleExtras?
    /// Ratings as a full-width row under the poster instead of beside it.
    let ratingsBelow: Bool
    /// The clear space above the poster (TitleCover.strip for this phone).
    var coverStrip: CGFloat = 167
    /// The title's TMDB id: TheTVDB's synopsis (and AniList's, for anime) is found by it.
    var tmdbID: Int? = nil
    init(name: String, poster: String?, backdrop: String? = nil, genres: [String] = [], year: Int?, category: String, runtime: Int?, series: Bool, summary: String, expanded: Binding<Bool>, extras: TitleExtras? = nil, ratingsBelow: Bool = false, coverStrip: CGFloat = 167, tmdbID: Int? = nil, onNameScrolled: ((CGFloat) -> Void)? = nil, @ViewBuilder ratings: () -> Ratings) {
        self.coverStrip = coverStrip; self.tmdbID = tmdbID
        self.name = name; self.poster = poster; self.backdrop = backdrop; self.genres = genres; self.year = year; self.category = category; self.runtime = runtime; self.series = series; self.summary = summary; self._expanded = expanded; self.extras = extras; self.ratingsBelow = ratingsBelow; self.onNameScrolled = onNameScrolled; self.ratings = ratings()
    }
    @State private var synopsisWidth: CGFloat = 0
    @State private var synopsisParts = SynopsisTextLayout.Parts(leading: "", continuation: "")
    @Environment(DiaryStore.self) private var store
    /// TheTVDB's and AniList's synopses, each only where it says something TMDB's (and the other's) doesn't.
    @State private var otherSynopses: [SynopsisSource: String] = [:]
    @State private var chosenSource: SynopsisSource?
    /// The title's trailer on YouTube (TMDB's), found when the page opens.
    @State private var trailerKey: String?
    /// Playing over the cover (made on the first tap; one web view, as Cines').
    @State private var trailer: CinesPlayer?
    /// Each start of the trailer (a stop or a new start ends the one before's retries).
    @State private var trailerRun = 0
    @Environment(\.openURL) private var openURL
    /// The sources with a synopsis of their own, TMDB's first.
    private var synopsisSources: [SynopsisSource] {
        (summary.isEmpty ? [] : [.tmdb]) + [SynopsisSource.tvdb, .anilist].filter { otherSynopses[$0] != nil }
    }
    /// The source shown: the one picked, else TMDB's, else (TMDB has none) TheTVDB's or AniList's.
    private var shownSource: SynopsisSource {
        if let chosenSource, synopsisSources.contains(chosenSource) { return chosenSource }
        return synopsisSources.first ?? .tmdb
    }
    private var shownSummary: String { shownSource == .tmdb ? summary : otherSynopses[shownSource] ?? summary }
    private var synopsisText: String { shownSummary.isEmpty ? "Add your own thoughts in Notes." : shownSummary }
    private var runtimeText: String? {
        if let minutes = [runtime, extras?.runtimeMinutes].compactMap({ $0 }).first(where: { $0 > 0 }) {
            return series ? "\(minutes) min/ep" : DiaryDate.duration(minutes)
        }
        if series, let latest = extras?.latestEpisodeMinutes, latest > 0 { return "Latest ep \(latest) min" }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The cover art's visible strip, down to 18 pt into the panel where the poster starts
            // (TitleCover.panelTop + 18, measured from the safe area).
            Color.clear.frame(maxWidth: .infinity).frame(height: coverStrip).contentShape(Rectangle())
                .fullScreenArtwork(backdrop, title: name, aspect: 16.0 / 9.0)
                // The trailer, over the cover art exactly: the screen's width, from the top of the screen.
                .overlay(alignment: .topLeading) { if let trailer { trailerView(trailer) } }
                // Its picture showing: the page draws the cover blurred under it (TitleArtworkBackdrop).
                .preference(key: TitleTrailerShowing.self, value: trailer?.playing == true)
        VStack(alignment: .leading, spacing: 20) {
            // Keep the identity down in the darkened lower artwork. The column is at least the
            // poster's height with its text at the bottom, so short names sit low beside the
            // poster; a long name makes the column taller downwards, never up past the poster's
            // top. Ratings scroll within the remaining column width.
            // Design: a 112 × 168 poster (radius 16, white 12 % hairline), the text column 14 pt to its
            // right starting 8 pt below the poster's top.
            HStack(alignment: .top, spacing: 14) {
                Artwork(path: poster, title: name, initialsOnly: false).frame(width: 112, height: 168).clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HomeStyle.outline(0.12), lineWidth: HomeStyle.hairline))
                    .shadow(color: .black.opacity(0.6), radius: 14, y: 10)
                    .contentShape(RoundedRectangle(cornerRadius: 16)).fullScreenArtwork(poster, title: name)
                    .accessibilityIdentifier("title-hero-poster")
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.app(size: 26, weight: .bold)).tracking(-0.52).foregroundStyle(HomeStyle.primary)
                        .lineLimit(2).truncationMode(.tail).allowsTightening(true)
                        .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                        .accessibilityIdentifier("title-hero-name")
                        .onGeometryChange(for: CGFloat.self) { CompactHeaderTransition.progress(nameBottom: $0.frame(in: .scrollView(axis: .vertical)).maxY) } action: { onNameScrolled?($0) }
                    HStack(spacing: 6) {
                        Text([year.map(String.init) ?? "—", category, runtimeText].compactMap { $0 }.joined(separator: " · ")).font(.app(size: 12)).foregroundStyle(HomeStyle.dateChipText).fixedSize(horizontal: false, vertical: true)
                        // The age rating as a small outlined badge on the year line.
                        if let rating = extras?.certification {
                            Text(rating).font(.app(size: 11, weight: .bold)).foregroundStyle(HomeStyle.dateChipText).lineLimit(1).fixedSize()
                                .padding(.horizontal, 4).frame(height: 16)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(HomeStyle.dateChipText.opacity(0.7), lineWidth: 1))
                                .accessibilityLabel("Rated " + rating)
                        }
                    }.padding(.top, 6)
                    TitleMetaChips(genres: genres, extras: extras, series: series, anime: category.lowercased().contains("anime")).padding(.top, 6)
                    if !ratingsBelow { ratings.padding(.top, 14) }
                }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if ratingsBelow { ratings }
            VStack(alignment: .leading, spacing: 4) {
                if expanded && (!synopsisParts.continuation.isEmpty || synopsisSources.count > 1) {
                    Text(synopsisText.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.app(size: 15)).lineSpacing(4).foregroundStyle(Color(themed: "#C4C4CC"))
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        .id(shownSource).transition(.opacity)
                        .accessibilityIdentifier("title-synopsis-text")
                    HStack(spacing: 8) {
                        Button("Less") { setExpanded(false) }.font(.app(size: 15, weight: .semibold)).frame(minHeight: 44)
                            .accessibilityIdentifier("title-synopsis-expanded")
                        Spacer(minLength: 8)
                        // Where the synopsis comes from, when more than one says something of its own.
                        if synopsisSources.count > 1 {
                            SynopsisSwitcher(sources: synopsisSources, shown: shownSource) { source in
                                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { chosenSource = source }
                            }
                        }
                    }
                } else {
                    synopsisLead
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                synopsisWidth = width; measureSynopsis()
            }
        }
        }
        // The trailer's button at the cover's foot, laid over the whole header rather than the cover
        // strip: that strip carries the press-and-hold layer (a UIKit context menu), and taps on a
        // button inside it sometimes never reached the button (owner's video, several taps).
        .overlay(alignment: .topTrailing) {
            if trailerKey != nil {
                trailerButton.padding(.top, max(0, coverStrip - 20 - 44))
            }
        }
        .onChange(of: synopsisText) { _, _ in measureSynopsis() }
        .task(id: tmdbID) { await loadOtherSynopses() }
        .task(id: tmdbID) { await loadTrailer() }
        .onDisappear { stopTrailer() }
        .onChange(of: trailer?.ended == true) { _, ended in if ended { stopTrailer() } }
        .onChange(of: trailerRefused) { _, refused in
            // Embedding switched off for this video: it opens on YouTube instead.
            guard refused, let key = trailerKey else { return }
            stopTrailer()
            if let url = URL(string: "https://www.youtube.com/watch?v=" + key) { openURL(url) }
        }
    }
    /// YouTube refused the trailer here (embedding switched off).
    private var trailerRefused: Bool {
        guard let trailer, let id = trailer.current else { return false }
        return trailer.refused.contains(id)
    }
    private func loadTrailer() async {
        guard let tmdbID, !store.isPreview, let token = TMDBDirect.token(store) else { return }
        // Asked once a session per title (each visit asked TMDB again).
        let place = (series ? "tv:" : "movie:") + String(tmdbID)
        if let kept = TitleTrailer.found[place] { trailerKey = kept; TitleTrailer.player.prepare(); return }
        let key = await CinesFeed.trailer(tmdb: tmdbID, series: series, anime: category.lowercased().contains("anime"), token: token)
        guard !Task.isCancelled, let key else { return }
        TitleTrailer.found[place] = key
        trailerKey = key
        // YouTube's player loaded ahead (once for the whole app), so the tap starts the video at once.
        TitleTrailer.player.prepare()
    }
    /// Round, on glass, at the cover's foot: play the trailer; while it plays, close it.
    private var trailerButton: some View {
        // While it loads: a spinner, and a tap does nothing (it closed the trailer before it began).
        let loading = trailer.map { !$0.playing && !$0.paused } ?? false
        return Button {
            if trailer == nil { startTrailer() } else if !loading { stopTrailer() }
        } label: {
            Group {
                if loading { ProgressView().tint(.white) }
                else {
                    Image(systemName: trailer == nil ? "play.fill" : "xmark").font(.app(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            // The size of the back and ••• buttons: 44 pt with the glass's own padding (about 7 pt a
            // side; at 20 pt it came out about 34 pt, smaller than them: owner's screenshots).
            .frame(width: 30, height: 30)
        }
        // iOS's own glass button: an "interactive" glass on a plain button's label tracked the touch
        // itself (it lit up) and sometimes kept the tap from the button.
        .buttonStyle(.glass).buttonBorderShape(.circle)
        .contentShape(Circle())
        .accessibilityLabel(trailer == nil ? "Play trailer" : "Close trailer")
        .accessibilityIdentifier("title-trailer")
    }
    private func startTrailer() {
        guard let trailerKey else { return }
        // One player for every title page, kept with YouTube's player loaded: a new web view and
        // player script on every tap were most of the wait before the video began.
        let player = TitleTrailer.player
        trailerRun += 1
        let run = trailerRun
        // With sound (the trailer was asked for), also with the ringer off, as a film plays. It
        // starts muted (YouTube's player often won't start unmuted by itself, so a tap seemed to do
        // nothing) and the sound comes on as it plays.
        player.muted = true
        player.unmutesOnStart = true
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { trailer = player }
        Task {
            await JellyAudioSession.activate()
            guard trailerRun == run, trailer != nil else { return }
            player.play(trailerKey)
            // Not started after a while (the page was slow, or YouTube held it): loaded again from the
            // start and asked to play (asking it to play only didn't always wake it).
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(2.5))
                guard trailerRun == run, trailer != nil, !player.playing, !player.paused, !player.ended else { return }
                player.reload()
            }
            // Still nothing after that: the cover back (a spinner that a tap can't close helps no one).
            try? await Task.sleep(for: .seconds(2.5))
            if trailerRun == run, trailer != nil, !player.playing, !player.paused { stopTrailer() }
        }
    }
    private func stopTrailer() {
        guard let trailer else { return }
        trailerRun += 1
        trailer.stop()
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { self.trailer = nil }
        // Music or a podcast that was playing before carries on.
        if !JellyMusic.shared.playing { JellyAudioSession.release() }
    }
    /// The trailer over the cover: no controls (a tap pauses and plays), its foot melting into the page
    /// as the cover's does; the cover shows until the video's picture comes.
    private func trailerView(_ player: CinesPlayer) -> some View {
        GeometryReader { proxy in
            let inset = max(0, proxy.frame(in: .global).minX)
            let width = proxy.size.width + inset * 2
            let height = (width * 9 / 16).rounded()
            ZStack {
                CinesPlayerHost(player: player).opacity(player.playing ? 1 : 0)
                if !player.playing && !player.paused { ProgressView().tint(.white) }
                if player.paused {
                    Image(systemName: "play.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 58, height: 58).background(.black.opacity(0.5), in: Circle()).allowsHitTesting(false)
                }
            }
            .frame(width: width, height: height)
            .background(Color.black.opacity(player.playing ? 1 : 0))
            // The lower part fades out gradually into the cover and its wash below (over the last tenth
            // only, a bright frame ended almost on a line above the wash, owner's screenshot).
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.6),
                                         .init(color: .black.opacity(0.75), location: 0.72), .init(color: .black.opacity(0.4), location: 0.84),
                                         .init(color: .black.opacity(0.12), location: 0.94), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .contentShape(Rectangle())
            .onTapGesture { player.toggle() }
            .offset(x: -inset, y: coverStrip - 6 - height)
        }
        .frame(height: coverStrip)
        .transition(.opacity)
        .accessibilityElement().accessibilityLabel("Trailer").accessibilityAddTraits(.startsMediaSession)
        .accessibilityAction { player.toggle() }
    }
    /// TheTVDB's synopsis, and AniList's for anime (each asked once and kept on the phone): a page
    /// whose TMDB synopsis is empty shows one of them, and More offers the choice where they differ.
    private func loadOtherSynopses() async {
        guard let tmdbID, !store.isPreview else { return }
        let film = !series, anime = category.lowercased().contains("anime")
        async let tvdb = Synopses.tvdbTitle(tmdb: tmdbID, series: series, store: store)
        async let ani: String? = anime ? await Synopses.aniList(tmdb: tmdbID, film: film) : nil
        let found = [(SynopsisSource.tvdb, await tvdb), (SynopsisSource.anilist, await ani)]
        // Every source with a synopsis, the same words as TMDB's or not: TMDB took many of its
        // synopses from TheTVDB, and hiding the matching ones left most titles without the choice.
        var kept: [SynopsisSource: String] = [:]
        for (source, text) in found { if let text, !text.isEmpty { kept[source] = text } }
        guard !Task.isCancelled, kept != otherSynopses else { return }
        otherSynopses = kept
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var synopsisLead: some View {
        let hasOverflow = !synopsisParts.continuation.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            Text(synopsisParts.leading.isEmpty ? synopsisText : synopsisParts.leading.trimmingCharacters(in: .whitespacesAndNewlines) + (expanded || !hasOverflow ? "" : "…"))
                .font(.app(size: 15)).lineSpacing(4).foregroundStyle(Color(themed: "#C4C4CC"))
                .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("title-synopsis-text")
                .overlay(alignment: .bottomTrailing) {
                    if !expanded && hasOverflow {
                        Button("More") { setExpanded(true) }.font(.app(size: 15, weight: .semibold))
                            .frame(width: 52, height: 44).offset(y: 10)
                    }
                }
            // A synopsis that fits but has another source: More on a line of its own (its last line
            // has no room kept for it).
            if !expanded && !hasOverflow && synopsisSources.count > 1 {
                Button("More") { setExpanded(true) }.font(.app(size: 15, weight: .semibold)).frame(minHeight: 36)
            }
        }
    }
    private func setExpanded(_ value: Bool) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88)) { expanded = value }
    }
    private func measureSynopsis() {
        guard synopsisWidth > 36 else { return }
        // Full-width lines; only the last one leaves room for "… More".
        synopsisParts = SynopsisTextLayout.split(synopsisText, width: synopsisWidth, lastLineReserve: 76)
    }

}
/// The cover trailer's one player (shared by every title page, YouTube's player kept loaded) and
/// the trailers found this session.
@MainActor enum TitleTrailer {
    static let player: CinesPlayer = {
        let player = CinesPlayer()
        player.loops = false
        player.keepsStarting = true
        return player
    }()
    static var found: [String: String] = [:]
}

/// The sources of a synopsis as their logos (the size of the ratings' marks), the one shown lit.
struct SynopsisSwitcher: View {
    let sources: [SynopsisSource]
    let shown: SynopsisSource
    let pick: (SynopsisSource) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(sources, id: \.self) { source in
                let on = source == shown
                Button { pick(source) } label: {
                    BrandLogo(service: source.logo, size: 22)
                        .frame(width: 44, height: 32)
                        .background(on ? Color.white.opacity(0.14) : Color.clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0.35 : 0.1), lineWidth: 1))
                        .opacity(on ? 1 : 0.5)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(source.name + " synopsis")
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("synopsis-source-" + source.rawValue)
            }
        }
        .sensoryFeedback(.selection, trigger: shown)
    }
}

/// The cover's trailer is showing its picture (from TitleHero up to the page, which draws its cover
/// blurred under it meanwhile).
struct TitleTrailerShowing: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The title page's cover: the whole artwork at 16:9 of the screen width (the shape of TMDB's
/// backdrops, so nothing is cropped or covered), then its own colours spilling down as a soft glow
/// that fades into the page. No panel edge or outline, so there is no line between cover and page.
enum TitleCover {
    static func artworkHeight(width: CGFloat) -> CGFloat { (width * 9 / 16).rounded() }
    /// Where the page's content starts, from the top of the screen: just under the artwork.
    static func panelTop(width: CGFloat) -> CGFloat { artworkHeight(width: width) }
    /// The clear strip above the poster, measured from the safe area: the poster starts 6 pt under the artwork.
    static func strip(width: CGFloat, safeTop: CGFloat) -> CGFloat { max(60, panelTop(width: width) - safeTop + 6) }
}

struct TitleArtworkBackdrop: View {
    let path: String?
    let name: String
    var topExtension: CGFloat = 0
    /// A trailer plays over the cover: the cover is drawn blurred, so the trailer's foot fades into
    /// colour (as the cover's own foot fades into the wash), not into the cover's picture under it
    /// (two pictures at once there: owner's screenshots).
    var softened = false
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { proxy in cover(width: proxy.size.width) }
            .offset(y: -topExtension).allowsHitTesting(false).accessibilityHidden(true)
    }
    /// The page's ground: the original near-black, or pitch black in Native (no artwork tint: owner's
    /// note, it didn't follow the theme).
    private var ground: Color { ThemeStore.current.native ? .black : Color(themed: "#0a0a0e") }
    /// How much smaller the wash is drawn than it shows (see cover).
    private static let washScale: CGFloat = 8
    private func cover(width: CGFloat) -> some View {
        let artwork = TitleCover.artworkHeight(width: width)
        // Owner's reference: the cover stays crisp; below it a strong, very smooth wash of its own
        // colours runs behind the poster and title and is fully dark by about 190 pt under the cover.
        return ZStack(alignment: .top) {
            // The wash: the cover mirrored (its top row is the cover's bottom row) and blurred so far
            // that no shapes remain, only colour. Wider than the screen so its blurred sides don't show.
            // Drawn at an eighth of its size, blurred there and flattened into one picture, then scaled up:
            // the same wash, but the blur works on 1/64 of the pixels and once, not at full size on every
            // frame as the page scrolls (it moves with the page).
            // 1.6 times the cover's height, so it reaches past where the darkening below is fully dark
            // (it used to end ~55 pt before that, on a straight line above the ratings: owner's note).
            art.frame(width: width * 1.3 / Self.washScale, height: artwork * 1.6 / Self.washScale)
                .scaleEffect(x: 1, y: -1)
                .blur(radius: 60 / Self.washScale).saturation(1.2)
                .drawingGroup()
                .scaleEffect(Self.washScale)
                .frame(width: width * 1.3, height: artwork * 1.6)
                .opacity(0.95)
                .offset(y: artwork - 50)
                .frame(width: width)
            // The page darkens over the wash: clear at the cover's foot, dark by ~190 pt below it.
            // An even ramp (owner's light-cover reference): a pale cover stays pale behind the poster and
            // title, and every cover reaches the page's dark at about the rating boxes.
            LinearGradient(stops: [
                .init(color: ground.opacity(0), location: 0),
                .init(color: ground.opacity(0.18), location: 0.25),
                .init(color: ground.opacity(0.45), location: 0.5),
                .init(color: ground.opacity(0.78), location: 0.75),
                .init(color: ground, location: 1)
            ], startPoint: .top, endPoint: .bottom)
                .frame(height: 250).offset(y: artwork - 20)
            ground.frame(height: 4000).offset(y: artwork + 229)
            // The cover itself, crisp; only a light shade behind the status bar and buttons, and a
            // short soft foot so it melts into the wash instead of ending on a line.
            // Under a trailer, blurred the wash's way (drawn small, blurred and flattened once, scaled up).
            Group {
                if softened {
                    art.frame(width: width / Self.washScale, height: artwork / Self.washScale)
                        .blur(radius: 40 / Self.washScale, opaque: true)
                        .drawingGroup()
                        .scaleEffect(Self.washScale)
                        .frame(width: width, height: artwork)
                } else {
                    art.frame(width: width, height: artwork)
                }
            }
            .clipped()
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: softened)
                .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .black.opacity(0), location: 0.3)], startPoint: .top, endPoint: .bottom))
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.88), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        }.frame(width: width, alignment: .top)
    }
    @ViewBuilder private var art: some View {
        ZStack {
            LinearGradient(stops: [.init(color: theme.heroFallbackLead, location: 0), .init(color: Color(themed: "#473c37"), location: 0.45), .init(color: Color(themed: "#253b3b"), location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let path { Artwork(path: path, title: name) }
        }
    }
}
