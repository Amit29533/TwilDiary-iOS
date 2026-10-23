import SwiftUI
import Charts
import TwilDiaryCore

struct StatsView: View {
    @Environment(DiaryStore.self) private var store
    @State private var period = Period.today
    @State private var year = Calendar.current.component(.year, from: Date.now)
    @State private var selectedDay: Date?
    @State private var showGenres = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(name: "Stats").padding(.horizontal, -16)
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("\(datedCount) of \(store.workspace.activeEvents.count) watches have dates").font(.subheadline.bold()); Spacer() }
                    ProgressView(value: Double(datedCount), total: Double(max(1, store.workspace.activeEvents.count)))
                    Text("\(store.workspace.activeEvents.count - datedCount) undated watches are left out of periods and trends. Unknown runtimes are left out of watch time.").font(.caption).foregroundStyle(.secondary)
                }.diaryPanel()
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 6) {
                        Text("Watch time").font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        Picker("Watch time period", selection: $period) { ForEach(Period.allCases) { Text($0.label).tag($0) } }.pickerStyle(.menu).fixedSize()
                        if period == .year { Picker("Year", selection: $year) { ForEach(years, id: \.self) { Text(String($0)).tag($0) } }.pickerStyle(.menu).fixedSize() }
                    }
                    Text(DiaryDate.duration(minutes)).font(.system(size: 38, weight: .bold)).foregroundStyle(.tint).tracking(-1)
                    Text("\(events.count) watches · \(Set(events.map(\.titleId)).count) movies & shows").font(.caption).foregroundStyle(.secondary)
                    Chart(daily) { day in BarMark(x: .value("Day", day.date, unit: .day), y: .value("Minutes", day.minutes)).foregroundStyle(.tint).cornerRadius(3) }
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }.chartYAxis(.hidden)
                        .chartXSelection(value: $selectedDay).frame(height: 120)
                    if let selectedDay {
                        let selected = events.filter { DiaryDate.parse($0.watchedAt).map { Calendar.current.isDate($0, inSameDayAs: selectedDay) } ?? false }
                        Text(selectedDay, format: .dateTime.day().month(.wide).year()).font(.subheadline.bold())
                        ForEach(selected) { event in if let title = store.title(event.titleId) { NavigationLink(value: title.id) { titleRow(title) }.buttonStyle(.plain) } }
                    }
                    Text("Dated watches only. Estimated from title runtimes. Includes rewatches.").font(.caption).foregroundStyle(.secondary)
                }.diaryPanel()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Backlog").font(.title3.bold())
                    ForEach(["planned", "watching", "completed", "dropped"], id: \.self) { status in HStack { Text(status.capitalized); Spacer(); Text("\(store.workspace.activeTitles.filter { $0.status == status }.count)").bold() }.font(.subheadline) }
                    NavigationLink { QueueView(planned: true) } label: { Text("Open planned →").font(.subheadline.bold()) }
                }.diaryPanel()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Genre mix").font(.title3.bold())
                    Text("Share of your \(store.workspace.activeTitles.count) titles with each genre").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(genres.prefix(showGenres ? genres.count : 5)), id: \.name) { genre in
                        VStack(spacing: 5) { HStack { Text(genre.name).bold(); Spacer(); Text("\(genre.percent)% · \(genre.count) titles").foregroundStyle(.secondary) }.font(.caption); ProgressView(value: Double(genre.percent), total: 100) }
                    }
                    if genres.count > 5 { Button(showGenres ? "Show top 5" : "All other genres") { showGenres.toggle() }.font(.subheadline.bold()) }
                    Text("Titles can have several genres, so these shares add up to more than 100%.").font(.caption).foregroundStyle(.secondary)
                }.diaryPanel()
            }.padding(.horizontal, 16).padding(.bottom, 24)
        }.refreshable { await store.refresh() }
    }
    private var events: [WatchEvent] { store.workspace.activeEvents.filter { event in DiaryDate.parse(event.watchedAt).map { period.contains($0, now: .now, calendar: .current, year: year) } ?? false } }
    private var minutes: Int { events.reduce(0) { $0 + max(0, store.title($1.titleId)?.runtimeMinutes ?? 0) } }
    private var datedCount: Int { store.workspace.activeEvents.filter { DiaryDate.parse($0.watchedAt) != nil }.count }
    private var years: [Int] { Set(store.workspace.activeEvents.compactMap { DiaryDate.parse($0.watchedAt).map { Calendar.current.component(.year, from: $0) } } + [Calendar.current.component(.year, from: Date.now)]).sorted(by: >) }
    private struct Day: Identifiable { var id: Date { date }; let date: Date; let minutes: Int }
    private var daily: [Day] {
        var values: [Date: Int] = [:]
        for event in events { if let date = DiaryDate.parse(event.watchedAt) { values[Calendar.current.startOfDay(for: date), default: 0] += max(0, store.title(event.titleId)?.runtimeMinutes ?? 0) } }
        return values.map { Day(date: $0.key, minutes: $0.value) }.sorted { $0.date < $1.date }
    }
    private struct Genre { let name: String; let count: Int; let percent: Int }
    private var genres: [Genre] {
        var counts: [String: Int] = [:]
        for title in store.workspace.activeTitles { for genre in Set(title.genres) { counts[genre, default: 0] += 1 } }
        return counts.map { Genre(name: $0.key, count: $0.value, percent: Int((Double($0.value) / Double(max(1, store.workspace.activeTitles.count)) * 100).rounded())) }.sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }
}
