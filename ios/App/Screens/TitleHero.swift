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
    init(name: String, poster: String?, backdrop: String? = nil, genres: [String] = [], year: Int?, category: String, runtime: Int?, series: Bool, summary: String, expanded: Binding<Bool>, extras: TitleExtras? = nil, ratingsBelow: Bool = false, onNameScrolled: ((CGFloat) -> Void)? = nil, @ViewBuilder ratings: () -> Ratings) {
        self.name = name; self.poster = poster; self.backdrop = backdrop; self.genres = genres; self.year = year; self.category = category; self.runtime = runtime; self.series = series; self.summary = summary; self._expanded = expanded; self.extras = extras; self.ratingsBelow = ratingsBelow; self.onNameScrolled = onNameScrolled; self.ratings = ratings()
    }
    @State private var synopsisWidth: CGFloat = 0
    @State private var synopsisParts = SynopsisTextLayout.Parts(leading: "", continuation: "")
    private var synopsisText: String { summary.isEmpty ? "Add your own thoughts in Notes." : summary }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The cover art's visible strip above the poster.
            Color.clear.frame(maxWidth: .infinity).frame(height: 142).contentShape(Rectangle())
                .fullScreenArtwork(backdrop, title: name, aspect: 16.0 / 9.0)
        VStack(alignment: .leading, spacing: 18) {
            // Keep the identity down in the darkened lower artwork. The column is at least the
            // poster's height with its text at the bottom, so short names sit low beside the
            // poster; a long name makes the column taller downwards, never up past the poster's
            // top. Ratings scroll within the remaining column width.
            HStack(alignment: .top, spacing: 15) {
                Artwork(path: poster, title: name, initialsOnly: false).frame(width: 114, height: 171).clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12)).fullScreenArtwork(poster, title: name)
                    .accessibilityIdentifier("title-hero-poster")
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.system(size: 24, weight: .bold)).tracking(-1.08).foregroundStyle(.white)
                        .lineLimit(3).minimumScaleFactor(0.72).allowsTightening(true)
                        .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                        .accessibilityIdentifier("title-hero-name")
                        .onGeometryChange(for: CGFloat.self) { CompactHeaderTransition.progress(nameBottom: $0.frame(in: .scrollView(axis: .vertical)).maxY) } action: { onNameScrolled?($0) }
                    Text([year.map(String.init) ?? "—", category, runtime.map { series ? "\($0) min per episode" : "\($0) min" }].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 14.4)).lineSpacing(4.3).foregroundStyle(.secondary).frame(minHeight: 21.6, alignment: .top).padding(.top, 14)
                    TitleMetaChips(genres: genres, extras: extras).padding(.top, 10)
                    if !ratingsBelow { ratings.padding(.top, 14) }
                }.frame(maxWidth: .infinity, minHeight: 171, alignment: .bottomLeading)
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
                            .font(.system(size: 15.04)).lineSpacing(6).foregroundStyle(Color(webHex: "#c5c0cf"))
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
            .font(.system(size: 15.04)).lineSpacing(6).foregroundStyle(Color(webHex: "#c5c0cf"))
            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
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
struct TitleArtworkBackdrop: View {
    let path: String?
    let name: String
    var topExtension: CGFloat = 0
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        ZStack {
            LinearGradient(stops: [.init(color: theme.heroFallbackLead, location: 0), .init(color: Color(webHex: "#473c37"), location: 0.45), .init(color: Color(webHex: "#253b3b"), location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let path { Artwork(path: path, title: name) }
        }.frame(height: 440 + topExtension)
            .overlay(LinearGradient(stops: [
                // Preserve contrast for the status bar and tinted toolbar over light artwork.
                .init(color: .black.opacity(0.48), location: 0),
                .init(color: .black.opacity(0.40), location: 0.25),
                .init(color: .black.opacity(0.62), location: 0.48),
                .init(color: .black.opacity(0.94), location: 0.73),
                .init(color: .black, location: 1)
            ], startPoint: .top, endPoint: .bottom))
            .mask { if theme == .glass { LinearGradient(stops: [.init(color: .white, location: 0.55), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom) } else { Color.white } }
            .offset(y: -topExtension).allowsHitTesting(false).accessibilityHidden(true)
    }
}
