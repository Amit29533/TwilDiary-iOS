import SwiftUI
import TwilDiaryCore

struct HomeView: View {
    @Environment(DiaryStore.self) private var store
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(name: "TwilDiary").padding(.horizontal, -16)
                SectionHeading(name: "Pick up where you left off") { Text("Glance →").foregroundStyle(.tint) }
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(watching) { title in ProgressCard(title: title, compact: true).containerRelativeFrame(.horizontal, count: 1, spacing: 12) }
                    }.scrollTargetLayout()
                }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
                if watching.isEmpty { Text("Your next watch starts in Library.").foregroundStyle(.secondary) }
                HStack(spacing: 10) {
                    NavigationLink { HistoryView() } label: { Label("History", systemImage: "clock") }
                    NavigationLink { QueueView() } label: { Label("Queue", systemImage: "arrow.down") }
                    NavigationLink { FilesView() } label: { Label("Disk Map", systemImage: "externaldrive") }
                }.font(.system(size: 12, weight: .semibold)).buttonStyle(.bordered).controlSize(.large)
                SectionHeading(name: "This week") { NavigationLink { StatsView() } label: { Text("Stats →") } }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) { Text(DiaryDate.duration(weekMinutes)).foregroundStyle(.tint).font(.title2.bold()); Text("Watch time").font(.caption).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 4) { Text("\(weekEvents.count)").font(.title2.bold()); Text("Watches").font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).diaryPanel()
                SectionHeading(name: "Up next") { NavigationLink { QueueView(planned: true) } label: { Text("Planned →") } }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) { ForEach(planned.prefix(12)) { title in NavigationLink(value: title.id) { PosterCard(title: title).frame(width: 110) }.buttonStyle(.plain) } }
                }.scrollIndicators(.hidden)
                SectionHeading(name: "Recently watched") { NavigationLink { HistoryView() } label: { Text("All history →") } }
                VStack(spacing: 10) { ForEach(Array(store.workspace.activeEvents.sorted { $0.recordedAt > $1.recordedAt }.prefix(5))) { event in
                    if let title = store.title(event.titleId) { NavigationLink(value: title.id) { historyRow(event, title: title, workspace: store.workspace) }.buttonStyle(.plain) }
                } }
            }.padding(.horizontal, 16).padding(.bottom, 24)
        }.refreshable { await store.refresh() }
    }
    private var watching: [MediaTitle] { store.workspace.activeTitles.filter { $0.status == "watching" } }
    private var planned: [MediaTitle] { store.workspace.activeTitles.filter { $0.status == "planned" } }
    private var weekEvents: [WatchEvent] { store.workspace.activeEvents.filter { DiaryDate.parse($0.watchedAt).map { Period.week.contains($0, now: .now, calendar: .current) } ?? false } }
    private var weekMinutes: Int { weekEvents.reduce(0) { $0 + (store.title($1.titleId)?.runtimeMinutes ?? 0) } }
}

struct QueueView: View {
    @Environment(DiaryStore.self) private var store
    var planned = false
    var body: some View {
        ScrollView { LazyVStack { ForEach(store.workspace.activeTitles.filter { planned ? $0.status == "planned" : $0.queued == true }) { title in NavigationLink(value: title.id) { titleRow(title) }.buttonStyle(.plain) } }.padding(16) }
            .navigationTitle(planned ? "Planned" : "Queue").toolbar(.visible, for: .navigationBar)
    }
}

@MainActor func historyRow(_ event: WatchEvent, title: MediaTitle, workspace: Workspace) -> some View {
    HStack(spacing: 12) {
        Artwork(path: title.poster, title: title.name).frame(width: 42, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 5) {
            Text(title.name).font(.subheadline.bold()).lineLimit(2)
            if let episode = workspace.episodes.first(where: { $0.id == event.episodeId }) { Text("S\(episode.season) E\(episode.number)").font(.caption).foregroundStyle(.secondary) }
            else { Text(title.categoryName).font(.caption).foregroundStyle(.secondary) }
        }
        Spacer(minLength: 0)
        if let date = DiaryDate.parse(event.watchedAt) { Text(date, format: .dateTime.day().month(.abbreviated)).font(.caption).foregroundStyle(.secondary) }
        else { Text("Date unknown").font(.caption).foregroundStyle(.secondary) }
    }.foregroundStyle(.white).diaryPanel()
}

struct HistoryView: View {
    @Environment(DiaryStore.self) private var store
    @State private var query = ""
    @State private var period = Period.all
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack { Text("Your watch history").font(.title3.bold()); Spacer(); Picker("Date filter", selection: $period) { ForEach(Period.allCases) { Text($0.label).tag($0) } }.pickerStyle(.menu) }
                TextField("Find a watched title…", text: $query).textFieldStyle(.roundedBorder)
                LazyVStack(spacing: 10) { ForEach(events) { event in
                    if let title = store.title(event.titleId) { NavigationLink(value: title.id) { historyRow(event, title: title, workspace: store.workspace) }.buttonStyle(.plain) }
                } }
                if events.isEmpty { ContentUnavailableView("No watches found", systemImage: "clock") }
            }.padding(16)
        }.navigationTitle("Recently watched").toolbar(.visible, for: .navigationBar)
    }
    private var events: [WatchEvent] {
        store.workspace.activeEvents.filter { event in
            let queryMatches = query.isEmpty || (store.title(event.titleId)?.name.localizedCaseInsensitiveContains(query) ?? false)
            return queryMatches && (period == .all || (DiaryDate.parse(event.watchedAt).map { period.contains($0, now: .now, calendar: .current) } ?? false))
        }.sorted { ($0.watchedAt ?? $0.recordedAt) > ($1.watchedAt ?? $1.recordedAt) }
    }
}
