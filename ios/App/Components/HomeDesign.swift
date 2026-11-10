import SwiftUI
import TwilDiaryCore

/// Home, to the owner's design file ("Home Redesign – 2 · Home with watch data"): exact sizes,
/// colours, radii and spacing at a 390 pt wide phone.
enum HomeStyle {
    static let primary = Color(webHex: "#f5f5f7")
    static let secondary = Color(webHex: "#9a9aa8")
    static let muted = Color(webHex: "#6e6e7c")
    static let soft = Color(webHex: "#d8d4e6")
    static let card = Color(webHex: "#0e0e12")
    static let cardBorder = Color(webHex: "#23232b")
    static let round = Color(webHex: "#17171d")
    static let chip = Color(webHex: "#2a2440")
    static let chipText = Color(webHex: "#cdbbff")
    static let dateChipBorder = Color(webHex: "#26262e")
    static let dateChipText = Color(webHex: "#b4b3c2")
    static let shortcut = Color(webHex: "#14111f")
    static let shortcutBorder = Color(webHex: "#2a2440")
    static let match = Color(webHex: "#7be495")
    static let hairline: CGFloat = 0.67
}

/// 22 pt bold section title with its round 36 pt controls on the right.
struct HomeSectionHeader<Trailing: View>: View {
    let title: String
    var icon: String? = nil
    var subtitle: String? = nil
    @ViewBuilder let trailing: Trailing
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if let icon { Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.accent).frame(width: 20, height: 20).accessibilityHidden(true) }
                    Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary).lineLimit(1)
                }
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { trailing }
        }.accessibilityElement(children: .contain)
    }
}

/// The 36 pt round control: a chevron (see all) or a layout icon.
struct HomeRoundIcon: View {
    var system: String = "chevron.right"
    var selected = false
    var body: some View {
        Image(systemName: system).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.dateChipText)
            .frame(width: 36, height: 36).background(selected ? HomeStyle.chip : HomeStyle.round, in: Circle())
            .frame(width: 44, height: 44).contentShape(Circle())
    }
}

/// Explore / Canvas: a 56 pt dark rounded card with a 36 pt accent icon, label and chevron.
struct HomeShortcut: View {
    let name: String
    let icon: String
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        HStack(spacing: 10) {
            DiaryIcon(name: icon, size: 17).foregroundStyle(theme.ink).frame(width: 36, height: 36).background(theme.accent, in: Circle())
            Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
        }.padding(.leading, 11).padding(.trailing, 16).frame(height: 56).frame(maxWidth: .infinity)
            .background(HomeStyle.shortcut, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HomeStyle.shortcutBorder, lineWidth: HomeStyle.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}

/// This week: watch time, watches and streak, then the seven days with their bars.
struct HomeWeekCard: View {
    let overview: HomeOverview
    let now: Date
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        let maximum = max(1, overview.days.map(\.minutes).max() ?? 0)
        VStack(alignment: .leading, spacing: 0) {
            // Three equal columns; the second and third start with a hairline and 15 pt of space.
            HStack(alignment: .top, spacing: 0) {
                metric(DiaryDate.duration(overview.minutes), "Watch time", accent: true).frame(maxWidth: .infinity, alignment: .leading)
                metric(String(overview.watches), "Watches").padding(.leading, 15).frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                    .overlay(alignment: .leading) { Rectangle().fill(HomeStyle.cardBorder).frame(width: HomeStyle.hairline) }
                metric("\(overview.streak) \(overview.streak == 1 ? "day" : "days")", "Streak").padding(.leading, 15).frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                    .overlay(alignment: .leading) { Rectangle().fill(HomeStyle.cardBorder).frame(width: HomeStyle.hairline) }
            }
            Rectangle().fill(HomeStyle.cardBorder).frame(height: 1).padding(.top, 14)
            HStack(spacing: 0) {
                ForEach(overview.days) { day in
                    let today = DiaryDate.calendar().isDate(day.date, inSameDayAs: now)
                    NavigationLink(value: HistoryRoute(day: day.date)) {
                        VStack(spacing: 0) {
                            Text(day.date, format: .dateTime.weekday(.narrow)).font(.system(size: 11, weight: .semibold)).foregroundStyle(HomeStyle.muted)
                            Text(day.date, format: .dateTime.day()).font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(today ? HomeStyle.chipText : day.future ? HomeStyle.muted : HomeStyle.soft)
                                .frame(width: 32, height: 32).background(today ? HomeStyle.chip : .clear, in: Circle())
                                .padding(.top, 7).padding(.bottom, 6)
                            RoundedRectangle(cornerRadius: 5).fill(HomeStyle.round).frame(width: 14, height: 22)
                                .overlay(alignment: .bottom) {
                                    if day.minutes > 0 {
                                        Rectangle().fill(theme.accent).frame(height: max(4, 22 * CGFloat(day.minutes) / CGFloat(maximum)))
                                    }
                                }.clipShape(RoundedRectangle(cornerRadius: 5))
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.plain).disabled(day.future)
                        .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)), \(day.count) watches")
                }
            }.padding(.top, 15)
            if overview.watches == 0 {
                // Design: nothing this week yet, with last week's total as a chip.
                HStack(spacing: 8) {
                    Text("Nothing logged yet. Mark an episode to start a streak.").font(.system(size: 13)).foregroundStyle(HomeStyle.dateChipText)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    if overview.lastWeekMinutes > 0 {
                        Text("Last week " + DiaryDate.duration(overview.lastWeekMinutes)).font(.system(size: 11, weight: .bold)).foregroundStyle(HomeStyle.chipText)
                            .lineLimit(1).fixedSize().padding(.horizontal, 9).frame(height: 24).background(HomeStyle.chip, in: RoundedRectangle(cornerRadius: 9))
                    }
                }.padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color(webHex: "#17142a"), in: RoundedRectangle(cornerRadius: 16)).padding(.top, 14)
            }
        }.padding(.horizontal, 17).padding(.top, 17).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
    }
    private func metric(_ value: String, _ label: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .bold)).foregroundStyle(accent ? theme.accent : HomeStyle.primary).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
        }.accessibilityElement(children: .combine)
    }
}

/// A 128 × 192 poster with its name and one line under it; an optional badge sits on the poster.
struct HomePoster<Badge: View>: View {
    let artwork: String?
    let name: String
    let subtitle: String
    var initialsOnly = false
    @ViewBuilder var badge: Badge
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Artwork(path: artwork, title: name, initialsOnly: initialsOnly).frame(width: 128, height: 192)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08), lineWidth: HomeStyle.hairline))
                .overlay(alignment: .bottomLeading) { badge }
            Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2)
                .multilineTextAlignment(.leading).padding(.top, 9)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1).padding(.top, 4)
        }.frame(width: 128, alignment: .leading).accessibilityElement(children: .combine)
    }
}
extension HomePoster where Badge == EmptyView {
    init(artwork: String?, name: String, subtitle: String, initialsOnly: Bool = false) {
        self.artwork = artwork; self.name = name; self.subtitle = subtitle; self.initialsOnly = initialsOnly; self.badge = EmptyView()
    }
}

/// "94% match" on a dark frosted pill.
struct HomeMatchBadge: View {
    let percent: Int
    var body: some View {
        HStack(spacing: 3) { Text("\(percent)%"); Text("match") }
            .font(.system(size: 12, weight: .bold)).foregroundStyle(HomeStyle.match)
            .padding(.horizontal, 9).frame(height: 24)
            .background(.ultraThinMaterial, in: Capsule()).background(HomeStyle.card.opacity(0.72), in: Capsule())
            .padding(9).accessibilityLabel("\(percent) percent match")
    }
}

/// New episodes: a 236 × 211 card with the artwork, "In 4 days", the name and two chips.
struct HomeNewEpisodeCard: View {
    let item: HomeOverview.Upcoming
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Artwork(path: item.title.backdrop ?? item.title.poster, title: item.title.name, initialsOnly: false)
                .frame(width: 236, height: 133).clipped()
                .overlay(alignment: .topLeading) {
                    Text(status).font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        .padding(.horizontal, 10).frame(height: 24).background(.ultraThinMaterial, in: Capsule())
                        .background(.black.opacity(0.55), in: Capsule()).padding(11)
                }
            VStack(alignment: .leading, spacing: 9) {
                Text(item.title.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                HStack(spacing: 8) {
                    Text("S\(item.episode.season) · E\(item.episode.number)").font(.system(size: 12, weight: .bold)).foregroundStyle(HomeStyle.chipText)
                        .padding(.horizontal, 9).frame(height: 24).background(HomeStyle.chip, in: RoundedRectangle(cornerRadius: 8))
                    Spacer(minLength: 0)
                    Text(item.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))).font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeStyle.dateChipText)
                        .padding(.horizontal, 9).frame(height: 24).background(HomeStyle.round, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                }
            }.padding(.horizontal, 15).padding(.top, 13).padding(.bottom, 14)
        }.frame(width: 236, height: 211, alignment: .top)
            .background(HomeStyle.card).clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.title.name), S\(item.episode.season) E\(item.episode.number), \(status)")
    }
    private var status: String { item.daysAway == 0 ? "Today" : item.daysAway == 1 ? "Tomorrow" : "In \(item.daysAway) days" }
}

/// New episodes as a list: the same facts in an 82 pt row.
struct HomeNewEpisodeRow: View {
    let item: HomeOverview.Upcoming
    var body: some View {
        HomeRow(artwork: item.title.backdrop ?? item.title.poster, name: item.title.name,
                chip: "S\(item.episode.season) · E\(item.episode.number)",
                detail: item.daysAway == 0 ? "Today" : item.daysAway == 1 ? "Tomorrow" : "In \(item.daysAway) days",
                date: item.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
    }
}

/// Recently watched: thumbnail, name, "S1 · E2 to E5" chip, "4 episodes", and the date.
struct HomeRow: View {
    let artwork: String?
    let name: String
    let chip: String
    let detail: String?
    let date: String?
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Artwork(path: artwork, title: name, initialsOnly: false).frame(width: 96, height: 64).clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(chip).font(.system(size: 11, weight: .bold)).foregroundStyle(HomeStyle.chipText).lineLimit(1)
                        .padding(.horizontal, 8).frame(height: 22).background(HomeStyle.chip, in: RoundedRectangle(cornerRadius: 8))
                    if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let date { Text(date).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1).padding(.top, 4) }
        }.padding(9).frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .combine)
    }
}

/// Recently watched as cards: a 236 pt card like New episodes.
struct HomeRecentCard: View {
    let group: RecentWatchGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Artwork(path: group.title.backdrop ?? group.title.poster, title: group.title.name, initialsOnly: false)
                .frame(width: 236, height: 133).clipped()
            VStack(alignment: .leading, spacing: 9) {
                Text(group.title.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                HStack(spacing: 8) {
                    Text(group.episodeText).font(.system(size: 12, weight: .bold)).foregroundStyle(HomeStyle.chipText)
                        .padding(.horizontal, 9).frame(height: 24).background(HomeStyle.chip, in: RoundedRectangle(cornerRadius: 8))
                    Spacer(minLength: 0)
                    if let date = group.date {
                        Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))).font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeStyle.dateChipText)
                    }
                }
            }.padding(.horizontal, 15).padding(.top, 13).padding(.bottom, 14)
        }.frame(width: 236, height: 211, alignment: .top)
            .background(HomeStyle.card).clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
            .accessibilityElement(children: .combine)
    }
}
