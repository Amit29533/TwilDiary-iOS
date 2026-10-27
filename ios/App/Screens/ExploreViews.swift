import SwiftUI
import TwilDiaryCore

struct ExploreView: View {
    @Environment(DiaryStore.self) private var store
    @State private var showSearch = false
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                    ExploreContent(store: store)
                }.padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 100)
            }
        }.diaryScreenBackground().navigationTitle("Explore").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { showSearch.toggle() } label: { DiaryIcon(name: "search", size: 22) }.accessibilityLabel("Search").accessibilityIdentifier("search-explore") }
            }
    }
}

private struct ExploreContent: View {
    let store: DiaryStore
    @State private var service: LiveDiscoveryService
    init(store: DiaryStore) { self.store = store; _service = State(initialValue: LiveDiscoveryService(store: store)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 10) {
                ExploreHeading(section: .daily)
                if let title = DiscoveryTools.dailyPick(store.workspace, day: DiaryDate.day(store.now)) {
                    NavigationLink(value: title.id) { DailyDiscoveryCard(title: title) }.buttonStyle(.plain).accessibilityIdentifier("explore-daily-pick")
                } else {
                    VStack(spacing: 10) { Text("No unwatched titles in your library."); Button("Open library") { openLibrary() } }
                        .font(.system(size: 14)).diaryPanel().frame(maxWidth: .infinity, minHeight: 150)
                }
            }
            RecommendedDiscoveryView(service: service, section: false)
            ForEach(DiscoverySection.shelves) { section in DiscoveryShelfView(section: section, service: service) }
            DiscoveryBrowser(section: .genres, service: service, store: store, promptForGenre: true)
            Text("Discovery and artwork: TMDb · Personal recommendations: Trakt").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    @Environment(AppRouter.self) private var router
    private func openLibrary() { router.library("all") }
}

private struct ExploreHeading: View {
    let section: DiscoverySection
    var filters: DiscoveryFilters? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(section.label).font(.system(size: 20, weight: .semibold)).tracking(-0.5)
            Spacer(minLength: 0)
            NavigationLink(value: ExploreSectionRoute(section: section, filters: filters)) { Text("View more").font(.system(size: 13)).frame(minHeight: 44) }
                .accessibilityIdentifier("explore-more-" + section.id)
        }
    }
}

private struct DailyDiscoveryCard: View {
    let title: MediaTitle
    var body: some View {
        ZStack(alignment: .bottom) {
            Artwork(path: title.backdrop ?? title.poster, title: title.name)
            LinearGradient(colors: [.black.opacity(0.07), .black.opacity(0.13), .black.opacity(0.87)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 11) {
                Artwork(path: title.poster, title: title.name).frame(width: 46, height: 69).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.name).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                    Text((title.year.map(String.init) ?? "Year unknown") + " · " + (title.isSeries ? "Show" : "Movie")).font(.system(size: 13)).foregroundStyle(Color(webHex: "#c5c0cf"))
                    if let score = title.communityScore, score > 0 { HStack(spacing: 5) { DiaryIcon(name: "star", size: 14); Text(String(format: "%.1f", score)); Text("TMDb").font(.system(size: 12)).foregroundStyle(.secondary) }.font(.system(size: 13)).foregroundStyle(Color(webHex: "#e7ca90")) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                DiaryIcon(name: "arrow-up-right", size: 23).foregroundStyle(.white)
            }.padding(13)
        }.frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.14))).contentShape(Rectangle())
    }
}

private struct DiscoveryShelfView: View {
    let section: DiscoverySection
    @State private var results: DiscoveryResults
    init(section: DiscoverySection, service: any DiscoveryServing) { self.section = section; _results = State(initialValue: DiscoveryResults(service: service)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ExploreHeading(section: section)
            DiscoveryTrack(items: results.items)
            if results.loading && results.items.isEmpty { DiaryLoadingPlaceholder(height: 210, label: "Loading titles") }
            if let error = results.error { DiscoveryNotice(text: error) { Task { await load() } } }
            else if !results.loading && results.items.isEmpty { DiscoveryNotice(text: "No titles available.") }
        }.task { if results.page == 0 { await load() } }
    }
    private func load() async { await results.load(DiscoveryFilters(section: section).query(section: section)) }
}

private struct DiscoveryTrack: View {
    let items: [CatalogItem]
    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.displayKey) { item in
                        Group {
                            if let id = item.inLibraryId { NavigationLink(value: id) { CatalogPoster(item: item) } }
                            else { NavigationLink(value: item.route) { CatalogPoster(item: item) } }
                        }.buttonStyle(.plain).containerRelativeFrame(.horizontal, count: 3, spacing: 12).accessibilityIdentifier("catalog-" + item.displayKey)
                    }
                }
            }.scrollIndicators(.hidden).padding(.bottom, 10)
        }
    }
}

private struct DiscoveryNotice: View {
    let text: String
    var retry: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 10) { Text(text).font(.system(size: 13)).foregroundStyle(.secondary).frame(minHeight: 21.5); Spacer(minLength: 0); if let retry { Button("Retry", action: retry).font(.system(size: 13)).frame(minHeight: 44) } }
            .padding(.horizontal, 14).padding(.vertical, 12).diarySectionBackground(radius: 11)
    }
}

private struct RecommendedDiscoveryView: View {
    @Environment(DiaryStore.self) private var store
    let section: Bool
    @State private var results: DiscoveryRecommendations
    init(service: any DiscoveryServing, section: Bool) { self.section = section; _results = State(initialValue: DiscoveryRecommendations(service: service)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ExploreHeading(section: .recommended)
            DiscoveryTrack(items: results.items)
            if results.loading && results.items.isEmpty { DiaryLoadingPlaceholder(height: 210, label: "Loading recommendations") }
            if let error = results.error { DiscoveryNotice(text: error) { Task { await results.load(refresh: true) } } }
            else if !results.loading && !results.connected { DiscoveryNotice(text: "Trakt not connected.") }
            else if !results.loading && results.items.isEmpty { DiscoveryNotice(text: "No recommendations yet.") }
        }.task(id: store.discoveryRevision) { await results.load(limit: section ? 24 : 8) }
    }
}

struct ExploreSectionView: View {
    let route: ExploreSectionRoute
    let store: DiaryStore
    @State private var showSearch = false
    @State private var service: LiveDiscoveryService
    init(route: ExploreSectionRoute, store: DiaryStore) { self.route = route; self.store = store; _service = State(initialValue: LiveDiscoveryService(store: store)) }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                    DiscoveryBrowser(section: route.section, service: service, store: store, initialFilters: route.filters)
                }.padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 100)
            }
        }.diaryScreenBackground().navigationTitle("Explore").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showSearch.toggle() } label: { DiaryIcon(name: "search", size: 22) }.accessibilityLabel("Search").accessibilityIdentifier("search-explore-section") } }
    }
}

private struct DiscoveryBrowser: View {
    let section: DiscoverySection
    let service: any DiscoveryServing
    let store: DiaryStore
    var promptForGenre: Bool
    @State private var filters: DiscoveryFilters
    @State private var openFilters = false
    @State private var localLimit = 40
    @State private var results: DiscoveryResults
    @State private var recommendations: DiscoveryRecommendations
    init(section: DiscoverySection, service: any DiscoveryServing, store: DiaryStore, initialFilters: DiscoveryFilters? = nil, promptForGenre: Bool = false) {
        self.section = section; self.service = service; self.store = store; self.promptForGenre = promptForGenre
        _filters = State(initialValue: initialFilters ?? DiscoveryFilters(section: section))
        _results = State(initialValue: DiscoveryResults(service: service)); _recommendations = State(initialValue: DiscoveryRecommendations(service: service))
    }
    private var local: [CatalogItem] { filters.applying(section == .daily ? DiscoveryTools.unwatched(store.workspace).map(DiscoveryTools.item) : recommendations.items) }
    private var displayed: [CatalogItem] { section.source == "tmdb" ? results.items : Array(local.prefix(localLimit)) }
    private var genres: [String] {
        if section != .daily { return DiscoveryGenre.names(type: filters.type) }
        return Set(DiscoveryTools.unwatched(store.workspace).filter { filters.type == "all" || ($0.isSeries ? "tv" : "movie") == filters.type }.flatMap(\.genres)).sorted()
    }
    private var busy: Bool { section == .recommended ? recommendations.loading : results.loading }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(section.label).font(.system(size: promptForGenre ? 20 : 26, weight: .semibold)).tracking(-0.5)
                Spacer(minLength: 0)
                if promptForGenre { NavigationLink(value: ExploreSectionRoute(section: section, filters: filters)) { Text("View more").font(.system(size: 13)) }.accessibilityIdentifier("explore-more-genres") }
                Button { openFilters.toggle() } label: { DiaryIcon(name: "sliders-horizontal", size: 18).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("More discovery filters").accessibilityValue(openFilters ? "Expanded" : "Collapsed").accessibilityIdentifier("explore-filters")
            }
            if promptForGenre { genreToolbar }
            if openFilters { filterForm }
            content
        }.task(id: filters) {
            localLimit = 40
            guard section.source == "tmdb" else { return }
            guard filters.error(section: section) == nil, !promptForGenre || !filters.genre.isEmpty else { results.clear(); return }
            do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation(); await results.load(filters.query(section: section)) } catch { }
        }.task(id: store.discoveryRevision) { if section == .recommended { await recommendations.load(limit: 24) } }
    }
    private var genreToolbar: some View {
        HStack(spacing: 10) {
            Picker("Explore genre", selection: $filters.genre) { Text("Choose a genre").tag(""); ForEach(genres, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("explore-genre")
            Picker("Explore media type", selection: $filters.type) { Text("Shows").tag("tv"); Text("Movies").tag("movie") }.pickerStyle(.segmented).frame(width: 145).accessibilityIdentifier("explore-type").onChange(of: filters.type) { _, _ in filters.genre = "" }
        }.font(.system(size: 13))
    }
    private var filterForm: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 12) {
            if !promptForGenre && section.fixedType == nil { Picker("Content type", selection: $filters.type) { if section.source != "tmdb" { Text("All titles").tag("all") }; Text("Shows").tag("tv"); Text("Movies").tag("movie") }.onChange(of: filters.type) { _, _ in filters.genre = "" } }
            if !promptForGenre { Picker("Section genre", selection: $filters.genre) { Text("All genres").tag(""); ForEach(genres, id: \.self) { Text($0).tag($0) } } }
            VStack(alignment: .leading, spacing: 5) { Text("Released year").font(.system(size: 12)).foregroundStyle(.secondary); TextField("Any year", text: $filters.year).textFieldStyle(.roundedBorder).keyboardType(.numberPad).accessibilityLabel("Explore release year") }
            Picker("Sort discoveries", selection: $filters.sort) { Text(section.source == "library" ? "Library order" : "Recommended order").tag("popular"); Text("Highest rated").tag("rating"); Text("Newest releases").tag("newest"); if section.source != "tmdb" { Text("Title A–Z").tag("title") } }
            Picker("Explore minimum rating", selection: $filters.minimum) { Text("Any rating").tag("0"); ForEach([6, 7, 8, 9], id: \.self) { Text("\($0)+").tag(String($0)) } }.accessibilityIdentifier("explore-minimum")
            Button("Reset filters") { filters = DiscoveryFilters(section: section) }.frame(minHeight: 44)
        }.pickerStyle(.menu).font(.system(size: 13)).padding(14).diarySectionBackground(radius: 13)
    }
    @ViewBuilder private var content: some View {
        if let error = filters.error(section: section) { DiscoveryNotice(text: error) }
        else if promptForGenre && filters.genre.isEmpty { Text("Choose a genre to explore shows and movies.").font(.system(size: 13)).foregroundStyle(.secondary) }
        else {
            if !displayed.isEmpty {
                Text("\(section.source == "tmdb" ? displayed.count : local.count) titles").font(.system(size: 12)).foregroundStyle(.secondary)
                CatalogGrid(items: displayed)
            }
            if busy && displayed.isEmpty { DiaryLoadingPlaceholder(height: 240, label: "Loading titles") }
            if let error = section == .recommended ? recommendations.error : results.error {
                DiscoveryNotice(text: error) { Task { if section == .recommended { await recommendations.load(limit: 24, refresh: true) } else { await results.load(filters.query(section: section), more: results.page > 0) } } }
            } else if !busy && displayed.isEmpty {
                if section == .recommended && !recommendations.connected { DiscoveryNotice(text: "Connect Trakt in More to load your recommendations.") }
                else { ContentUnavailableView(section == .daily ? "No unwatched titles in this mix" : "No titles in this mix", systemImage: "sparkles", description: Text("Try another genre, year or rating.")) }
            }
            if section.source == "tmdb" ? results.hasMore : localLimit < local.count {
                Button("Load more") { if section.source == "tmdb" { Task { await results.load(filters.query(section: section), more: true) } } else { localLimit += 40 } }.buttonStyle(.glass).disabled(busy).frame(maxWidth: .infinity)
            }
        }
    }
}
