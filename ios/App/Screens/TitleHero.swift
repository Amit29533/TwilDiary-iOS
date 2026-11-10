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
    init(name: String, poster: String?, backdrop: String? = nil, genres: [String] = [], year: Int?, category: String, runtime: Int?, series: Bool, summary: String, expanded: Binding<Bool>, extras: TitleExtras? = nil, ratingsBelow: Bool = false, coverStrip: CGFloat = 167, onNameScrolled: ((CGFloat) -> Void)? = nil, @ViewBuilder ratings: () -> Ratings) {
        self.coverStrip = coverStrip
        self.name = name; self.poster = poster; self.backdrop = backdrop; self.genres = genres; self.year = year; self.category = category; self.runtime = runtime; self.series = series; self.summary = summary; self._expanded = expanded; self.extras = extras; self.ratingsBelow = ratingsBelow; self.onNameScrolled = onNameScrolled; self.ratings = ratings()
    }
    @State private var synopsisWidth: CGFloat = 0
    @State private var synopsisParts = SynopsisTextLayout.Parts(leading: "", continuation: "")
    private var synopsisText: String { summary.isEmpty ? "Add your own thoughts in Notes." : summary }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The cover art's visible strip, down to 18 pt into the panel where the poster starts
            // (TitleCover.panelTop + 18, measured from the safe area).
            Color.clear.frame(maxWidth: .infinity).frame(height: coverStrip).contentShape(Rectangle())
                .fullScreenArtwork(backdrop, title: name, aspect: 16.0 / 9.0)
        VStack(alignment: .leading, spacing: 20) {
            // Keep the identity down in the darkened lower artwork. The column is at least the
            // poster's height with its text at the bottom, so short names sit low beside the
            // poster; a long name makes the column taller downwards, never up past the poster's
            // top. Ratings scroll within the remaining column width.
            // Design: a 112 × 168 poster (radius 16, white 12 % hairline), the text column 14 pt to its
            // right starting 8 pt below the poster's top.
            HStack(alignment: .top, spacing: 14) {
                Artwork(path: poster, title: name, initialsOnly: false).frame(width: 112, height: 168).clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12), lineWidth: HomeStyle.hairline))
                    .shadow(color: .black.opacity(0.6), radius: 14, y: 10)
                    .contentShape(RoundedRectangle(cornerRadius: 16)).fullScreenArtwork(poster, title: name)
                    .accessibilityIdentifier("title-hero-poster")
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.system(size: 26, weight: .bold)).tracking(-0.52).foregroundStyle(HomeStyle.primary)
                        .lineLimit(2).truncationMode(.tail).allowsTightening(true)
                        .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                        .accessibilityIdentifier("title-hero-name")
                        .onGeometryChange(for: CGFloat.self) { CompactHeaderTransition.progress(nameBottom: $0.frame(in: .scrollView(axis: .vertical)).maxY) } action: { onNameScrolled?($0) }
                    Text([year.map(String.init) ?? "—", category, runtime.map { series ? "\($0) min per ep" : "\($0) min" }].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(HomeStyle.dateChipText).lineLimit(1).padding(.top, 6)
                    TitleMetaChips(genres: genres, extras: extras).padding(.top, 6)
                    if !ratingsBelow { ratings.padding(.top, 14) }
                }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if ratingsBelow { ratings }
            VStack(alignment: .leading, spacing: 6) {
                synopsisLead
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    synopsisWidth = width; measureSynopsis()
                }
                if expanded && !synopsisParts.continuation.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(synopsisParts.continuation.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 14)).lineSpacing(3).foregroundStyle(HomeStyle.soft)
                            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("title-synopsis-continuation")
                        Button("Less") { setExpanded(false) }.font(.system(size: 14, weight: .semibold)).frame(minHeight: 44)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .contain).accessibilityIdentifier("title-synopsis-expanded")
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 6)))
                }
            }
        }
        }.onChange(of: synopsisText) { _, _ in measureSynopsis() }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var synopsisLead: some View {
        let hasOverflow = !synopsisParts.continuation.isEmpty
        return Text(synopsisParts.leading.isEmpty ? synopsisText : synopsisParts.leading.trimmingCharacters(in: .whitespacesAndNewlines) + (expanded || !hasOverflow ? "" : "…"))
            .font(.system(size: 14)).lineSpacing(3).foregroundStyle(HomeStyle.soft)
            .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 36)
            .accessibilityIdentifier("title-synopsis-text")
            .overlay(alignment: .bottomTrailing) {
                if !expanded && hasOverflow {
                    Button("More") { setExpanded(true) }.font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44).offset(y: 8)
                }
            }
    }
    private func setExpanded(_ value: Bool) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88)) { expanded = value }
    }
    private func measureSynopsis() {
        guard synopsisWidth > 36 else { return }
        synopsisParts = SynopsisTextLayout.split(synopsisText, width: synopsisWidth - 36)
    }

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
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        GeometryReader { proxy in cover(width: proxy.size.width) }
            .offset(y: -topExtension).allowsHitTesting(false).accessibilityHidden(true)
    }
    private func cover(width: CGFloat) -> some View {
        let artwork = TitleCover.artworkHeight(width: width)
        return ZStack(alignment: .top) {
            // The cover's colours carried below it: a blurred mirror of the artwork whose top row is the
            // cover's bottom row, fading into the page — so the picture flows on with no seam.
            art.frame(width: width, height: artwork).clipped()
                .scaleEffect(x: 1, y: -1)
                .blur(radius: 26).saturation(1.15)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.55), location: 0.4), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .opacity(0.85)
                .offset(y: artwork - 40)
            // The page darkens gradually under the glow: no shape, no edge.
            LinearGradient(stops: [
                .init(color: Color(webHex: "#0a0a0e").opacity(0), location: 0),
                .init(color: Color(red: 12 / 255, green: 11 / 255, blue: 16 / 255).opacity(0.55), location: 0.35),
                .init(color: Color(webHex: "#0a0a0e").opacity(0.92), location: 1)
            ], startPoint: .top, endPoint: .bottom)
                .frame(height: 420).offset(y: artwork - 30)
            Color(webHex: "#0a0a0e").frame(height: 4000).offset(y: artwork + 390)
            // The whole artwork, solid; only its last few points soften so the edge disappears into the glow.
            art.frame(width: width, height: artwork).clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .overlay(LinearGradient(stops: [
                    // Only the status bar's corner gets a light shade, for its text and the buttons.
                    .init(color: .black.opacity(0.42), location: 0), .init(color: .black.opacity(0), location: 0.34)
                ], startPoint: .top, endPoint: .bottom))
        }.frame(width: width, alignment: .top)
    }
    @ViewBuilder private var art: some View {
        ZStack {
            LinearGradient(stops: [.init(color: theme.heroFallbackLead, location: 0), .init(color: Color(webHex: "#473c37"), location: 0.45), .init(color: Color(webHex: "#253b3b"), location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let path { Artwork(path: path, title: name) }
        }
    }
}
