import SwiftUI
import Charts
import TwilDiaryCore

/// "54d 5h", "6h 20m", "45m": long totals in days and hours.
func longDuration(_ minutes: Int) -> String {
    guard minutes >= 1440 else { return DiaryDate.duration(minutes) }
    let days = minutes / 1440, hours = (minutes % 1440) / 60
    return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
}

/// The panel every Statistics section sits on.
struct StatsCard<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let title { Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(.white) }
                    if let subtitle { Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary) }
                }
            }
            content
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).diaryPanel(padding: 0, radius: 24)
    }
}

/// Movies | Shows, as the Most played and Highest rated cards switch them.
struct KindSwitch: View {
    @Binding var shows: Bool
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        HStack(spacing: 14) {
            Button("Movies") { shows = false }.foregroundStyle(shows ? Color.secondary : theme.accent)
            Button("Shows") { shows = true }.foregroundStyle(shows ? theme.accent : Color.secondary)
        }.font(.system(size: 15, weight: .semibold)).buttonStyle(.plain)
    }
}

// MARK: Overview

struct StatsJourneyCard: View {
    let insights: StatsInsights
    let coverage: StatsOverview.Coverage
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) { DiaryIcon(name: "sparkles", size: 14); Text("YOUR JOURNEY").font(.system(size: 13, weight: .semibold)).tracking(2) }.foregroundStyle(theme.accent.opacity(0.9))
            VStack(alignment: .leading, spacing: 2) {
                Text(longDuration(insights.totalMinutes)).font(.system(size: 52, weight: .heavy)).tracking(-1.5).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                Text("total watch time").font(.system(size: 16)).foregroundStyle(.white.opacity(0.75))
            }
            HStack(spacing: 10) {
                tile(insights.episodes, "episodes"); tile(insights.shows, "shows"); tile(insights.movies, "movies")
            }
            Capsule().fill(.white.opacity(0.12)).frame(height: 7)
                .overlay(alignment: .leading) { GeometryReader { proxy in Capsule().fill(theme.accent).frame(width: proxy.size.width * Double(coverage.percent) / 100) } }
                .accessibilityLabel("Watches with dates").accessibilityValue("\(coverage.percent)%")
            HStack {
                Text("\(coverage.dated.formatted()) watches dated")
                Spacer(minLength: 6)
                Text("\(coverage.unknown.formatted()) undated · \(coverage.missingRuntime.formatted()) no runtime")
            }.font(.system(size: 13)).foregroundStyle(.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.8)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Color(webHex: "#2a1f45")
                    RadialGradient(colors: [theme.accent.opacity(0.45), .clear], center: .topLeading, startRadius: 0, endRadius: 320)
                    LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 26)).overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.14)))
            .accessibilityElement(children: .contain).accessibilityIdentifier("stats-journey")
    }
    private func tile(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted()).font(.system(size: 19, weight: .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.14)))
            .accessibilityElement(children: .combine)
    }
}

struct StatsPeriodTiles: View {
    let insights: StatsInsights
    var body: some View {
        HStack(spacing: 12) {
            tile("This month", insights.monthMinutes, insights.monthPlays)
            tile("This year", insights.yearMinutes, insights.yearPlays)
        }
    }
    private func tile(_ label: String, _ minutes: Int, _ plays: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 14)).foregroundStyle(.secondary)
            Text(longDuration(minutes)).font(.system(size: 24, weight: .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            Text(plays.counted("play", "plays")).font(.system(size: 13)).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).diaryPanel(padding: 0, radius: 20)
            .accessibilityElement(children: .combine)
    }
}

struct StatsOverTimeCard: View {
    let years: [StatsInsights.YearMinutes]
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        if years.count >= 2 {
            StatsCard(title: "Over time", subtitle: "Watch time per year") {
                let peak = years.max { $0.minutes < $1.minutes }
                Chart(years) { item in
                    AreaMark(x: .value("Year", item.year), y: .value("Minutes", item.minutes)).interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [theme.accent.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Year", item.year), y: .value("Minutes", item.minutes)).interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5)).foregroundStyle(theme.accent)
                    if item.year == peak?.year || item.year == years.last?.year {
                        PointMark(x: .value("Year", item.year), y: .value("Minutes", item.minutes)).symbolSize(60).foregroundStyle(theme.accent)
                            .annotation(position: .top) { Text(longDuration(item.minutes).components(separatedBy: " ").first ?? "").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                    }
                }.chartYAxis(.hidden)
                    .chartXAxis { AxisMarks(values: years.map(\.year)) { value in AxisValueLabel { Text("'" + String((value.as(Int.self) ?? 0) % 100).leftPadded(2)).font(.system(size: 11)) } } }
                    .frame(height: 170).accessibilityLabel("Watch time per year")
            }
        }
    }
}
private extension String {
    func leftPadded(_ length: Int) -> String { count >= length ? self : String(repeating: "0", count: length - count) + self }
}

struct StatsSplitCard: View {
    let insights: StatsInsights
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        let total = max(1, insights.totalMinutes)
        let showShare = Double(insights.showMinutes) / Double(total)
        if insights.totalMinutes > 0 {
            StatsCard(title: "Watch time split") {
                ZStack {
                    Circle().stroke(Color(webHex: "#f2b45a"), lineWidth: 22)
                    Circle().trim(from: 0, to: showShare).stroke(theme.accent, style: StrokeStyle(lineWidth: 22, lineCap: .butt)).rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        Text("\(Int((max(showShare, 1 - showShare) * 100).rounded()))%").font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
                        Text(showShare >= 0.5 ? "Shows" : "Movies").font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                }.frame(width: 170, height: 170).frame(maxWidth: .infinity).padding(.vertical, 6).accessibilityHidden(true)
                row("Shows", theme.accent, showShare, insights.showMinutes)
                row("Movies", Color(webHex: "#f2b45a"), 1 - showShare, insights.movieMinutes)
            }
        }
    }
    private func row(_ label: String, _ color: Color, _ share: Double, _ minutes: Int) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            Text("\(Int((share * 100).rounded()))% · \(longDuration(minutes))").font(.system(size: 14)).foregroundStyle(.secondary)
        }.padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14)).accessibilityElement(children: .combine)
    }
}

// MARK: Habits

struct StatsWhenCard: View {
    let insights: StatsInsights
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    private static let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    var body: some View {
        if insights.hours.contains(where: { $0 > 0 }) {
            StatsCard(title: "When you watch") {
                HStack {
                    Text("Time of day").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    if let hour = insights.peakHour { Text("Peaks around " + hourLabel(hour)).font(.system(size: 14)).foregroundStyle(theme.accent) }
                }
                Chart(Array(insights.hours.enumerated()), id: \.offset) { item in
                    AreaMark(x: .value("Hour", item.offset), y: .value("Plays", item.element)).interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [theme.accent.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Hour", item.offset), y: .value("Plays", item.element)).interpolationMethod(.catmullRom).foregroundStyle(theme.accent)
                }.chartYAxis(.hidden)
                    .chartXAxis { AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21]) { value in AxisValueLabel { Text(String(format: "%02d", value.as(Int.self) ?? 0)).font(.system(size: 11)) } } }
                    .frame(height: 130).accessibilityLabel("Plays by hour of day")
                HStack {
                    Text("Day of week").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    if let day = insights.peakWeekday { Text(Self.days[day] + "s lead").font(.system(size: 14)).foregroundStyle(theme.accent) }
                }.padding(.top, 6)
                let most = max(1, insights.weekdays.max() ?? 1)
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(0..<7, id: \.self) { index in
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 6).fill(index == insights.peakWeekday ? theme.accent : theme.accent.opacity(0.35))
                                .frame(height: max(8, 90 * CGFloat(insights.weekdays[index]) / CGFloat(most)))
                            Text(Self.days[index]).font(.system(size: 12, weight: index == insights.peakWeekday ? .bold : .regular)).foregroundStyle(index == insights.peakWeekday ? .white : .secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }.frame(height: 116, alignment: .bottom).accessibilityLabel("Plays by day of week")
            }
        }
    }
    private func hourLabel(_ hour: Int) -> String { hour == 0 ? "midnight" : hour == 12 ? "noon" : hour < 12 ? "\(hour) AM" : "\(hour - 12) PM" }
}

struct StatsHallOfFameCard: View {
    let insights: StatsInsights
    let longestStreak: Int
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        if insights.biggestDay != nil || insights.first != nil {
            StatsCard(title: "Hall of fame") {
                if let day = insights.biggestDay {
                    row("calendar-days", "Biggest day", day.day.formatted(.dateTime.day().month(.abbreviated).year()), longDuration(day.minutes))
                }
                if longestStreak > 0 { row("activity", "Best streak", nil, longestStreak.counted("day", "days")) }
                if let first = insights.first, let latest = insights.latest {
                    HStack(spacing: 10) {
                        moment(first)
                        VStack(spacing: 6) {
                            Text(span(first.date, latest.date)).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                            HStack(spacing: 0) { Circle().fill(theme.accent).frame(width: 8, height: 8); Rectangle().fill(theme.accent.opacity(0.5)).frame(height: 2); Circle().fill(theme.accent).frame(width: 8, height: 8) }
                        }.frame(maxWidth: .infinity)
                        moment(latest)
                    }.padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityElement(children: .combine)
                }
            }
        }
    }
    private func row(_ icon: String, _ label: String, _ detail: String?, _ value: String) -> some View {
        HStack(spacing: 12) {
            DiaryIcon(name: icon, size: 17).foregroundStyle(theme.accent).frame(width: 40, height: 40).background(theme.accent.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 14)).foregroundStyle(.secondary)
                if let detail { Text(detail).font(.system(size: 17, weight: .bold)).foregroundStyle(.white) }
            }
            Spacer()
            Text(value).font(.system(size: 22, weight: .bold)).foregroundStyle(theme.accent)
        }.padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16)).accessibilityElement(children: .combine)
    }
    private func moment(_ value: StatsInsights.Moment) -> some View {
        NavigationLink(value: value.title.id) {
            VStack(spacing: 6) {
                Artwork(path: value.title.poster, title: value.title.name, initialsOnly: false).frame(width: 54, height: 76).clipShape(RoundedRectangle(cornerRadius: 9))
                Text(value.date.formatted(.dateTime.day().month(.abbreviated).year())).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain)
    }
    private func span(_ from: Date, _ to: Date) -> String {
        let parts = DiaryDate.calendar().dateComponents([.year, .month, .day], from: from, to: to)
        if let years = parts.year, years > 0 { return years.counted("year", "years") }
        if let months = parts.month, months > 0 { return months.counted("month", "months") }
        return max(0, parts.day ?? 0).counted("day", "days")
    }
}

struct StatsMarathonsCard: View {
    let marathons: [StatsInsights.Marathon]
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        if !marathons.isEmpty {
            StatsCard(title: "Longest marathons") {
                ForEach(marathons) { item in
                    NavigationLink(value: item.title.id) {
                        HStack(spacing: 12) {
                            Artwork(path: item.title.poster, title: item.title.name, initialsOnly: false).frame(width: 46, height: 64).clipShape(RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                                Text(item.day.formatted(.dateTime.day().month(.abbreviated).year())).font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(spacing: 0) {
                                Text("\(item.episodes)").font(.system(size: 24, weight: .bold)).foregroundStyle(theme.accent)
                                Text("episodes").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }.padding(10).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16)).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: Taste

struct StatsPosterItem: Identifiable {
    let title: MediaTitle
    let badge: String
    var detail: String? = nil
    var id: String { title.id }
}

struct StatsPosterRow: View {
    let title: String
    let items: [StatsPosterItem]
    @Binding var shows: Bool
    var body: some View {
        StatsCard {
            HStack { Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(.white); Spacer(); KindSwitch(shows: $shows) }
            if items.isEmpty { Text("Nothing here yet.").font(.subheadline).foregroundStyle(.secondary) }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink(value: item.title.id) {
                            Artwork(path: item.title.poster, title: item.title.name, initialsOnly: false).frame(width: 104, height: 150).clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(alignment: .bottomLeading) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(item.badge).font(.system(size: 13, weight: .bold))
                                        if let detail = item.detail { Text(detail).font(.system(size: 11)) }
                                    }.foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 4).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8)).padding(6)
                                }
                        }.buttonStyle(.springPress).accessibilityLabel(item.title.name + ", " + item.badge)
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }
}

struct StatsRatingsCard: View {
    let insights: StatsInsights
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        if insights.ratedCount > 0 {
            StatsCard(title: "Your ratings", subtitle: insights.ratedCount.counted("title", "titles")) {
                let most = max(1, insights.ratingCounts.max() ?? 1)
                let top = insights.ratingCounts.firstIndex(of: most)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(0..<10, id: \.self) { index in
                        let count = insights.ratingCounts[index]
                        VStack(spacing: 5) {
                            if count > 0 { Text("\(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white) }
                            RoundedRectangle(cornerRadius: 5).fill(index == top ? theme.accent : theme.accent.opacity(count > 0 ? 0.55 : 0.12))
                                .frame(height: count > 0 ? max(6, 110 * CGFloat(count) / CGFloat(most)) : 3)
                            Text("\(index + 1)").font(.system(size: 12, weight: index == top ? .bold : .regular)).foregroundStyle(index == top ? .white : .secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }.frame(height: 150, alignment: .bottom).accessibilityLabel("Your ratings from 1 to 10")
                HStack(spacing: 12) {
                    average("Movies avg", insights.movieAverage)
                    average("Shows avg", insights.showAverage)
                }
            }
        }
    }
    private func average(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 14)).foregroundStyle(.secondary)
            Text(value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—").font(.system(size: 22, weight: .bold)).foregroundStyle(theme.accent)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct StatsDecadesCard: View {
    let decades: [StatsInsights.Decade]
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        if !decades.isEmpty {
            StatsCard(title: "Through the decades", subtitle: "Titles by release decade") {
                let most = max(1, decades.map(\.count).max() ?? 1)
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(decades.suffix(6)) { item in
                        VStack(spacing: 6) {
                            Text("\(item.count)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            RoundedRectangle(cornerRadius: 8).fill(item.count == most ? theme.accent : theme.accent.opacity(0.55))
                                .frame(height: max(6, 110 * CGFloat(item.count) / CGFloat(most)))
                            Text("\(String(item.decade))s").font(.system(size: 12, weight: item.count == most ? .bold : .regular)).foregroundStyle(item.count == most ? .white : .secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }.frame(height: 160, alignment: .bottom).accessibilityLabel("Titles by release decade")
            }
        }
    }
}

// MARK: Library

struct StatsGlanceCard: View {
    let insights: StatsInsights
    var body: some View {
        StatsCard(title: "At a glance") {
            VStack(spacing: 0) {
                if let runtime = insights.averageRuntime { row("Avg runtime", "\(runtime) min") }
                if let movie = insights.longestMovie, let runtime = movie.runtimeMinutes { row("Longest movie", "\(runtime) min", detail: movie.name) }
                if let value = insights.movieAverage { row("Movies avg", value.formatted(.number.precision(.fractionLength(1)))) }
                if let value = insights.showAverage { row("Shows avg", value.formatted(.number.precision(.fractionLength(1)))) }
                row("Rewatches", insights.rewatches.formatted())
                if let first = insights.first { row("First watch", first.date.formatted(.dateTime.month(.abbreviated).year())) }
                if let latest = insights.latest { row("Latest watch", latest.date.formatted(.dateTime.month(.abbreviated).year()), last: true) }
            }
        }
    }
    private func row(_ label: String, _ value: String, detail: String? = nil, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 16)).foregroundStyle(Color(webHex: "#c5c0cf"))
                    if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Text(value).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
            }.padding(.vertical, 12)
            if !last { Divider().overlay(.white.opacity(0.07)) }
        }.accessibilityElement(children: .combine)
    }
}
