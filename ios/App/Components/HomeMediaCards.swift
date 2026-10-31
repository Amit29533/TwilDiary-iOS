import SwiftUI
import TwilDiaryCore

/// Home-only presentation. The overview and history projection still own order and identities.
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
                VStack(alignment: .leading, spacing: 0) {
                    artwork.aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay(alignment: model.isUpcoming ? .topLeading : .topTrailing) { badge.padding(8) }
                    VStack(alignment: .leading, spacing: 6) {
                        title.lineLimit(2, reservesSpace: true)
                        episode
                        Text(model.dateLabel).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }.containerRelativeFrame(.horizontal) { width, _ in min(280, max(200, width * 0.64)) }
            } else {
                HStack(spacing: 12) {
                    artwork.frame(width: 80, height: 45).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 5) {
                        title.lineLimit(2)
                        episode
                        if typeSize.isAccessibilitySize { dateColumn }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if !typeSize.isAccessibilitySize { dateColumn }
                }.padding(10).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            }
        }.foregroundStyle(Color(webHex: "#f3f0f7"))
            .background(Color(webHex: "#111115"), in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
            .multilineTextAlignment(.leading).contentShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .ignore).accessibilityLabel(model.accessibilityLabel)
    }
    private var artwork: some View { Artwork(path: model.artwork, title: model.name, initialsOnly: false) }
    private var title: some View { Text(model.name).font(.subheadline.weight(.semibold)) }
    private var episode: some View {
        HStack(spacing: 5) {
            Text(model.episode)
            if model.isRewatch { Image(systemName: "arrow.counterclockwise").accessibilityLabel("Rewatched") }
        }.font(.caption).foregroundStyle(.secondary)
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
    @ViewBuilder private var badge: some View {
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

/// The existing grid preference now selects a horizontal card shelf; list stays vertical.
struct HomeActivityLayout<Content: View>: View {
    let cards: Bool
    @ViewBuilder let content: Content
    var body: some View {
        if cards {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) { content }.scrollTargetLayout()
            }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
        } else { LazyVStack(spacing: 8) { content } }
    }
}

struct HomePlannedCard: View {
    let title: MediaTitle
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(path: title.poster, title: title.name, initialsOnly: false).aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(title.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(2, reservesSpace: true)
            Text(title.isSeries ? "Show" : (["Movie"] + [title.runtimeMinutes.map(DiaryDate.duration)].compactMap { $0 }).joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        }.multilineTextAlignment(.leading).accessibilityElement(children: .combine)
    }
}

struct HomeFavouriteCard: View {
    let item: Favourite
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(path: item.image, title: item.name).aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "heart.fill").font(.system(size: 12)).foregroundStyle(theme.accent)
                        .frame(width: 24, height: 24).background(.black.opacity(0.78), in: Circle()).padding(6).accessibilityHidden(true)
                }
            Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(2, reservesSpace: true)
            Text(item.kind.singular).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.multilineTextAlignment(.leading).accessibilityElement(children: .combine)
    }
}
