import SwiftUI
import TwilDiaryCore

/// Keep the first matching cover in place while filters or pagination update.
struct ExploreBrowseHeader: View {
    let title: String
    var symbol = "safari"
    var emoji: String? = nil
    var subtitle: String? = nil
    var artwork: String? = nil
    /// The title's accessibility identifier, when a page has its own.
    var titleIdentifier: String? = nil
    /// A control beside the title (a layout toggle).
    var accessory: AnyView? = nil
    /// A picture of the page's own across the top (an award ceremony's logo), in place of artwork.
    var banner: AnyView? = nil
    @State private var cover: String?

    static func artwork(in items: [CatalogItem]) -> String? {
        items.lazy.compactMap { $0.backdrop ?? CatalogTools.image($0.backdropPath, size: "w780") }.first
            ?? items.lazy.compactMap { $0.poster ?? CatalogTools.image($0.posterPath, size: "w780") }.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(colors: [HomeStyle.chip, HomeStyle.card], startPoint: .topTrailing, endPoint: .bottomLeading)
                if let banner {
                    banner
                } else if let path = cover ?? artwork {
                    Artwork(path: path, title: "", initialsOnly: false)
                } else {
                    Image(systemName: symbol).font(.system(size: 95, weight: .light))
                        .foregroundStyle(HomeStyle.chipText.opacity(0.32))
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 36)
                }
                LinearGradient(colors: [.black.opacity(0.4), .clear], startPoint: .top, endPoint: .center)
            }
            .frame(height: 192)
            .mask(LinearGradient(stops: [.init(color: .white, location: 0),
                                         .init(color: .white, location: 0.55),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Group {
                            if let emoji { Text(emoji) }
                            else { Image(systemName: symbol).foregroundStyle(HomeStyle.chipText) }
                        }.font(.title2).accessibilityHidden(true)
                        Text(title).font(.title.bold()).foregroundStyle(HomeStyle.primary)
                            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier(titleIdentifier ?? (emoji == nil ? "explore-browse-title" : "tag-results-title"))
                    }
                    if let accessory { Spacer(minLength: 8); accessory }
                }
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }.padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: artwork, initial: true) { _, path in
            if cover == nil { cover = path }
        }
    }
}

/// Tile directories can reuse the first visible tile's existing art without a second metadata request.
struct BrowseCoverPreference: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if value == nil { value = nextValue() }
    }
}

struct ExploreBrowsePage<Content: View>: View {
    let title: String
    var symbol = "safari"
    var emoji: String? = nil
    var subtitle: String? = nil
    var artwork: String? = nil
    var titleIdentifier: String? = nil
    var accessory: AnyView? = nil
    var banner: AnyView? = nil
    @ViewBuilder let content: Content
    @State private var tileCover: String?
    @State private var header = CompactHeaderState()

    var body: some View {
        EdgeToEdgeScroll(artworkUnderBar: true) {
            VStack(alignment: .leading, spacing: 0) {
                ExploreBrowseHeader(title: title, symbol: symbol, emoji: emoji, subtitle: subtitle,
                                    artwork: artwork ?? tileCover, titleIdentifier: titleIdentifier, accessory: accessory, banner: banner)
                    .id(title)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom in
                        header.update(ScrollLinkedBarTitle.progress(headingBottom: bottom))
                    }
                content
                    .onPreferenceChange(BrowseCoverPreference.self) { path in
                        if tileCover == nil { tileCover = path }
                    }
            }
        }
        .diaryScreenBackground().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { ScrollLinkedBarTitle(resting: "", scrolled: title, state: header) }
        }
    }
}
