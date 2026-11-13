import SwiftUI
import TwilDiaryCore

/// Shared activity presentation. The overview/history projections own order and identities.
struct HomeEpisodeCardModel {
    enum Activity {
        case upcoming(date: Date, daysAway: Int)
        case watched(date: Date?, rewatched: Bool)
    }
    let id: String
    let name: String
    let artwork: String?
    let episode: String
    let activity: Activity

    init(upcoming item: HomeOverview.Upcoming) {
        id = item.id; name = item.title.name
        // Unwatched episode stills can be spoilers; use the existing title artwork.
        artwork = item.title.backdrop ?? item.title.poster
        episode = "S\(item.episode.season) · E\(item.episode.number)"
        activity = .upcoming(date: item.date, daysAway: item.daysAway)
    }
    init(history entry: HistoryEntry) {
        id = entry.id; name = entry.title.name
        artwork = entry.title.backdrop ?? entry.title.poster
        episode = entry.episode.map { "S\($0.season) · E\($0.number)" } ?? "Movie"
        activity = .watched(date: DiaryDate.parse(entry.event.watchedAt), rewatched: entry.rewatched)
    }
    var status: String {
        switch activity {
        case .upcoming(_, let days): days == 0 ? "Today" : days == 1 ? "Tomorrow" : "In \(days) days"
        case .watched(_, let rewatched): rewatched ? "Rewatched" : "Watched"
        }
    }
    var date: Date? {
        switch activity { case .upcoming(let date, _), .watched(let date?, _): date; case .watched(nil, _): nil }
    }
    var isUpcoming: Bool { if case .upcoming = activity { true } else { false } }
    var isRewatch: Bool { if case .watched(_, let rewatched) = activity { rewatched } else { false } }
    var dateLabel: String {
        guard let date else { return "Watch date unknown" }
        return isUpcoming ? date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) : date.formatted(.dateTime.day().month(.abbreviated).year())
    }
    var accessibilityLabel: String { [name, episode, status, dateLabel].joined(separator: ", ") }
}

/// Width comes from the shelf or grid cell, never a second viewport-relative
/// frame. Both watched surfaces use this same compact landscape composition.
struct WatchActivityCard: View {
    let model: HomeEpisodeCardModel
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Artwork(path: model.artwork, title: model.name, initialsOnly: false)
                .frame(height: 120).clipped()
                .overlay(alignment: model.isUpcoming ? .topLeading : .topTrailing) { ActivityStatusBadge(model: model).padding(8) }
            VStack(alignment: .leading, spacing: 6) {
                Text(model.name).font(.subheadline.weight(.semibold)).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    episode.lineLimit(1).fixedSize(horizontal: true, vertical: true)
                    date.font(.caption2).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
        }.foregroundStyle(Color(webHex: "#f3f0f7"))
            .background(Color(webHex: "#111115"), in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
            .multilineTextAlignment(.leading).contentShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .ignore).accessibilityLabel(model.accessibilityLabel)
    }
    private var episode: some View { Text(model.episode).font(.footnote).foregroundStyle(.secondary) }
    private var date: some View { Text(model.dateLabel).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

private struct ActivityStatusBadge: View {
    let model: HomeEpisodeCardModel
    var body: some View {
        if model.isUpcoming {
            Text(model.status).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 4)
                .background(.black.opacity(0.75), in: Capsule())
        } else {
            Image(systemName: model.isRewatch ? "arrow.counterclockwise" : "checkmark")
                .font(.caption.weight(.semibold)).frame(width: 26, height: 26)
                .background(.black.opacity(0.75), in: Circle()).overlay(Circle().strokeBorder(.white.opacity(0.65)))
        }
    }
}

/// Matching image, typography and date treatment for both Home activity sections.
/// Artwork uses the existing memory/disk cache in either layout; no metadata requests here.
struct HomeEpisodeCard: View {
    let model: HomeEpisodeCardModel
    let cards: Bool
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if cards {
                WatchActivityCard(model: model)
                    .containerRelativeFrame(.horizontal) { width, _ in
                        typeSize.isAccessibilitySize ? width : model.isUpcoming ? (width - 12) / 2 : min(220, width * 0.44)
                    }
            } else {
                HStack(spacing: 12) {
                    artwork.aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .containerRelativeFrame(.horizontal) { width, _ in min(120, width * 0.3) }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 5) {
                        title.lineLimit(2)
                        episode
                        if typeSize.isAccessibilitySize { dateColumn }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if !typeSize.isAccessibilitySize { dateColumn }
                }.padding(6).frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                    .foregroundStyle(Color(webHex: "#f3f0f7"))
                    .background(Color(webHex: "#111115"), in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
                    .multilineTextAlignment(.leading).contentShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .ignore).accessibilityLabel(model.accessibilityLabel)
            }
        }
    }
    private var artwork: some View { Artwork(path: model.artwork, title: model.name, initialsOnly: false) }
    private var title: some View { Text(model.name).font(cards ? .subheadline.weight(.semibold) : .callout.weight(.semibold)) }
    private var episode: some View {
        HStack(spacing: 5) {
            Text(model.episode)
            if model.isRewatch { Image(systemName: "arrow.counterclockwise").accessibilityLabel("Rewatched") }
        }.font(.footnote).foregroundStyle(.secondary)
    }
    private var dateColumn: some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
            if model.isUpcoming { Text(model.status).font(.caption.weight(.semibold)).foregroundStyle(theme.accent) }
            if let date = model.date {
                Text(date, format: .dateTime.day().month(.abbreviated)).font(.caption).foregroundStyle(.secondary)
                if !model.isUpcoming { Text(date, format: .dateTime.year()).font(.caption2).foregroundStyle(.secondary) }
            } else { Text("Watch date\nunknown").font(.caption2).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: true, vertical: false)
    }
}

/// A favourite on Home: the same 128 × 192 poster, name and kind as the other shelves (design).
struct HomeFavouriteCard: View {
    let item: Favourite
    var body: some View {
        // No heart on the poster: the shelf is already "Favourites".
        HomePoster(artwork: item.image, name: item.name, subtitle: item.kind.singular, initialsOnly: true)
    }
}

