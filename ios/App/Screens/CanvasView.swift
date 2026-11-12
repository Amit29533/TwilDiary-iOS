import SwiftUI
import TwilDiaryCore

/// Canvas (owner's design): Movies · Shows · Lists as a lilac segmented pill in the top bar, a
/// row of filter pills, then an artwork mosaic for titles or poster-collage cards for Trakt lists.
struct CanvasView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("canvasTab") private var tab = CanvasTab.movies.rawValue
    var body: some View { CanvasContent(store: store, tab: Binding(get: { CanvasTab(rawValue: tab) ?? .movies }, set: { tab = $0.rawValue })) }
}

enum CanvasTab: String, CaseIterable { case movies, shows, lists
    var label: String { rawValue.capitalized }
}

/// Movies and Shows sorts. Recommended is the owner's personal Trakt recommendations.
enum CanvasSort: String, CaseIterable, Identifiable {
    case popular, trending, rating, recommended
    var id: Self { self }
    var label: String { switch self { case .popular: "Popular"; case .trending: "Trending"; case .rating: "Top rated"; case .recommended: "Recommended" } }
}

private struct CanvasContent: View {
    let store: DiaryStore
    @Binding var tab: CanvasTab
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.displayScale) private var displayScale
    @State private var results: DiscoveryResults
    @State private var recommendations: DiscoveryRecommendations
    @State private var lists: CanvasListsLoader
    /// Sort and list choices are remembered between visits; one-off filters (genre, year, rating) start fresh.
    @AppStorage("canvasSort") private var sort = CanvasSort.popular
    /// Genres picked in the Genres sheet (any number up to six; all must match). "Anime" is
    /// Animation made in Japanese.
    @State private var genres: [String] = []
    @State private var anime = false
    @State private var showGenres = false
    @State private var pageWidth: CGFloat = 390
    /// The big Movies · Shows · Lists words have scrolled under the top bar: it shows the chosen one.
    @State private var tabsHidden = false
    @State private var network: Int?
    @State private var year = ""
    @State private var minimum = "0"
    @AppStorage("canvasListSort") private var listSort = "trending"
    @AppStorage("canvasListKind") private var listKind = "personal"
    init(store: DiaryStore, tab: Binding<CanvasTab>) {
        self.store = store; _tab = tab
        let service = LiveDiscoveryService(store: store)
        _results = State(initialValue: DiscoveryResults(service: service))
        _recommendations = State(initialValue: DiscoveryRecommendations(service: service))
        _lists = State(initialValue: CanvasListsLoader(store: store))
    }
    private var kind: MediaKind { tab == .shows ? .tv : .movie }
    private var query: [String: String] {
        // An unfinished year is left out rather than sent and refused.
        let validYear = Int(year).map { year.count == 4 && (1880...2200).contains($0) } ?? false
        var value = ["source": "tmdb", "type": kind.rawValue, "sort": sort.rawValue, "genre": "", "year": validYear ? year : "", "minimum": minimum, "page": "1"]
        if let network, kind == .tv { value["network"] = String(network) }
        if !chosenGenres.isEmpty { value["genres"] = chosenGenres.joined(separator: ",") }
        if anime { value["language"] = "ja" }
        return value
    }
    /// The genres the list is narrowed to (Anime adds Animation).
    private var chosenGenres: [String] {
        let available = Set(DiscoveryGenre.names(type: kind.rawValue))
        var value = genres.filter { available.contains($0) }
        if anime && !value.contains("Animation") { value.append("Animation") }
        return Array(value.prefix(6))
    }
    private var genreLabel: String {
        let names = (anime ? ["Anime"] : []) + genres
        guard let first = names.first else { return "Genres" }
        return names.count == 1 ? first : first + " +\(names.count - 1)"
    }
    private var titles: [CatalogItem] {
        guard sort == .recommended else { return results.items }
        var filters = DiscoveryFilters(section: .recommended)
        filters.type = kind.rawValue; filters.year = year; filters.minimum = minimum
        let wanted = chosenGenres
        return filters.applying(recommendations.items).filter { item in wanted.allSatisfy { item.genres?.contains($0) == true } }
    }
    var body: some View {
        // Movies · Shows · Lists as large words at the top of the page (owner's layout); they
        // scroll away with it, leaving the art the whole screen.
        EdgeToEdgeScroll(scrolledPast: (40, $tabsHidden)) {
            VStack(alignment: .leading, spacing: 14) {
                tabs
                pills
                Group { if tab == .lists { listsContent } else { titlesContent } }
                    .smoothChange(of: [tab == .lists, titles.isEmpty, lists.lists.isEmpty])
            }.padding(.horizontal, 12).padding(.bottom, 100)
        }.diaryScreenBackground().navigationTitle(tabsHidden ? tab.label : "").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
            .sheet(isPresented: $showGenres) {
                CanvasGenreSheet(names: DiscoveryGenre.names(type: kind.rawValue), genres: $genres, anime: $anime)
            }
            .task(id: query) {
                guard tab != .lists, sort != .recommended else { return }
                do { try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation() } catch { return }
                await results.load(query)
            }
            .task(id: CanvasRecommendationKey(enabled: tab != .lists && sort == .recommended, revision: store.discoveryRevision)) {
                if tab != .lists && sort == .recommended { await recommendations.load(limit: 24) }
            }
            .task(id: [tab.rawValue, listSort, listKind]) { if tab == .lists { await lists.load(sort: listSort, kind: listKind) } }
    }
    private struct CanvasRecommendationKey: Hashable { let enabled: Bool; let revision: UUID }
    /// Movies · Shows · Lists on a Liquid Glass track; the chosen one is a lilac pill that slides across.
    private var tabs: some View {
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            ForEach(CanvasTab.allCases, id: \.self) { item in
                let on = tab == item
                // The page swaps at once (no cross-fade flash); only the words change weight.
                Button { tab = item; if item == .movies { network = nil } } label: {
                    Text(item.label).font(.system(size: 30, weight: .bold)).tracking(-0.6).lineLimit(1)
                        .foregroundStyle(on ? Color.white : Color(webHex: "#8a8794"))
                        .animation(.snappy(duration: 0.2), value: on)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : []).accessibilityIdentifier("canvas-tab-" + item.rawValue)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 4).padding(.top, 4)
    }
    private var pills: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                if tab == .lists {
                    Menu { Picker("Sort lists", selection: $listSort) { Text("Trending").tag("trending"); Text("Popular").tag("popular") } }
                        label: { pill(listSort.capitalized, icon: "arrow.up.arrow.down", accent: true) }.accessibilityIdentifier("canvas-list-sort")
                    Menu { Picker("List type", selection: $listKind) { Text("Personal").tag("personal"); Text("Official").tag("official") } }
                        label: { pill(listKind.capitalized) }.accessibilityIdentifier("canvas-list-kind")
                } else {
                    Menu { Picker("Sort", selection: $sort) { ForEach(CanvasSort.allCases) { Text($0.label).tag($0) } } }
                        label: { pill(sort.label, icon: "arrow.up.arrow.down", accent: true) }.accessibilityIdentifier("canvas-sort")
                    Button { showGenres = true } label: { pill(genreLabel, active: !genres.isEmpty || anime) }
                        .buttonStyle(.plain).accessibilityLabel("Genres, " + genreLabel).accessibilityIdentifier("canvas-genre")
                    if tab == .shows {
                        Menu { Picker("Network", selection: $network) { Text("All networks").tag(Int?.none); ForEach(CanvasNetwork.all, id: \.id) { Text($0.name).tag(Optional($0.id)) } } }
                            label: { pill(CanvasNetwork.all.first { $0.id == network }?.name ?? "Networks", active: network != nil) }
                            .disabled(sort == .recommended).accessibilityIdentifier("canvas-network")
                    }
                    Menu { Picker("Release year", selection: $year) { Text("Any year").tag(""); ForEach(Self.years, id: \.self) { Text(String($0)).tag(String($0)) } } }
                        label: { pill(year.isEmpty ? "Year" : year, active: !year.isEmpty) }.accessibilityLabel("Release year").accessibilityIdentifier("canvas-year")
                    Menu { Picker("Minimum rating", selection: $minimum) { Text("Any rating").tag("0"); ForEach([6, 7, 8, 9], id: \.self) { Text("\($0)+").tag(String($0)) } } }
                        label: { pill(minimum == "0" ? "Rating" : minimum + "+", active: minimum != "0") }.accessibilityLabel("Minimum rating").accessibilityIdentifier("canvas-rating")
                }
            }.padding(.horizontal, 2)
        }.scrollIndicators(.hidden).scrollClipDisabled()
            .onChange(of: tab) { _, _ in
                // Keep only the genres the other type has.
                let available = Set(DiscoveryGenre.names(type: kind.rawValue)); genres = genres.filter { available.contains($0) }
            }
    }
    /// A filter pill: the order pill is lilac-tinted with ⇅; a filter that's set turns lilac too.
    private func pill(_ label: String, icon: String? = nil, active: Bool = false, accent: Bool = false) -> some View {
        let tinted = active || accent
        return HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 13, weight: .bold)) }
            Text(label).lineLimit(1).truncationMode(.tail).frame(maxWidth: 170)
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).opacity(0.8)
        }.font(.system(size: 15, weight: .semibold)).fixedSize()
            .foregroundStyle(tinted ? HomeStyle.chipText : Color(webHex: "#e6e1ee"))
            .padding(.horizontal, 14).frame(height: 40)
            .background(tinted ? HomeStyle.chip : HomeStyle.card, in: Capsule())
            .overlay(Capsule().strokeBorder(tinted ? Color.clear : HomeStyle.dateChipBorder, lineWidth: 1))
            .frame(minHeight: 44).contentShape(Capsule())
    }
    @ViewBuilder private var titlesContent: some View {
        let items = titles
        let loading = sort == .recommended ? recommendations.loading : results.loading
        let error = sort == .recommended ? recommendations.error : results.error
        if !items.isEmpty { CanvasMosaic(items: items) { if sort != .recommended { Task { await results.load(query, more: true) } } } }
        if loading && items.isEmpty { DiaryLoadingPlaceholder(height: 320, label: "Loading titles") }
        if let error { notice(error) { Task { if sort == .recommended { await recommendations.load(limit: 24, refresh: true) } else { await results.load(query) } } } }
        else if !loading && items.isEmpty {
            if sort == .recommended && !recommendations.connected { notice("Connect Trakt in More to see your recommendations.") }
            else { notice("No titles match these filters.") }
        }
        if loading && !items.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12) }
    }
    @ViewBuilder private var listsContent: some View {
        if !lists.lists.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2), spacing: 12) {
                ForEach(lists.lists) { list in
                    NavigationLink(value: CanvasListRoute(id: list.id, name: list.name, user: list.user)) { CanvasListCard(list: list) }
                        .buttonStyle(.plain).accessibilityIdentifier("canvas-list-\(list.id)")
                        // A card that stays on screen for half a second starts reading its list's first
                        // page, so opening it shows the titles at once (it used to wait on Trakt and 24
                        // TMDB reads). Scrolled past sooner, nothing is read. Once started, the read
                        // finishes even if the card leaves the screen (opening the list does that).
                        .task {
                            try? await Task.sleep(for: .milliseconds(500))
                            guard !Task.isCancelled, !store.isPreview else { return }
                            let loader = CanvasListItemsLoader.shared(store: store, id: list.id)
                            // Columns as the list's grid draws them (14 pt margins, 12 pt gaps, 3 across, 2:3).
                            let cell = max(1, (pageWidth - 28 - 24) / 3), scale = displayScale
                            Task {
                                await loader.load()
                                // Its first posters too, so they're there when the list opens.
                                let requests = loader.items.prefix(12).compactMap {
                                    PublicArtworkRequest(path: $0.artwork, pixels: Double(cell * 1.5 * scale), width: Double(cell * scale))
                                }
                                await withTaskGroup(of: Void.self) { group in
                                    for request in requests { group.addTask { _ = await PublicArtworkCache.shared.image(request) } }
                                }
                            }
                        }
                        .onAppear { if list.id == lists.lists.last?.id { Task { await lists.load(sort: listSort, kind: listKind, more: true) } } }
                }
            }
        }
        if lists.loading && lists.lists.isEmpty { DiaryLoadingPlaceholder(height: 320, label: "Loading lists") }
        if let error = lists.error { notice(error) { Task { await lists.load(sort: listSort, kind: listKind) } } }
        else if !lists.loading && lists.lists.isEmpty { notice("No lists to show right now.") }
    }
    private func notice(_ text: String, retry: (() -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 14)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let retry { Button("Retry", action: retry).font(.system(size: 14, weight: .semibold)).frame(minHeight: 44) }
        }.padding(.horizontal, 14).padding(.vertical, 10).diaryPanel(padding: 0, radius: 14)
    }
    private static let years = Array((1950...Calendar.current.component(.year, from: .now)).reversed())
}

/// TMDb network IDs offered for shows; mirrors discoveryNetworks on the server.
enum CanvasNetwork {
    struct Network { let name: String; let id: Int }
    static let all: [Network] = [
        .init(name: "Netflix", id: 213), .init(name: "HBO", id: 49), .init(name: "Max", id: 3186),
        .init(name: "Prime Video", id: 1024), .init(name: "Apple TV+", id: 2552), .init(name: "Disney+", id: 2739),
        .init(name: "Hulu", id: 453), .init(name: "Paramount+", id: 4330), .init(name: "Peacock", id: 3353),
        .init(name: "AMC", id: 174), .init(name: "FX", id: 88), .init(name: "BBC One", id: 4),
        .init(name: "Crunchyroll", id: 1112), .init(name: "Adult Swim", id: 80)
    ]
}

/// Repeats every six titles: one wide hero, three posters, then a wide tile beside a poster.
struct CanvasMosaic: View {
    let items: [CatalogItem]
    var loadMore: () -> Void = {}
    @State private var width: CGFloat = 0
    private let gap: CGFloat = 8
    var body: some View {
        let column = max(0, (width - gap * 2) / 3), poster = column * 1.5
        LazyVStack(spacing: gap) {
            ForEach(Array(stride(from: 0, to: items.count, by: 6)), id: \.self) { start in
                let group = Array(items[start..<min(start + 6, items.count)])
                tile(group[0], wide: true).frame(width: width, height: width * 0.5)
                // A short last group still fills its rows: no lone poster beside an empty gap.
                let posters = Array(group[1..<min(4, group.count)])
                if posters.count == 1 {
                    tile(posters[0], wide: true).frame(width: width, height: width * 0.5)
                } else if !posters.isEmpty {
                    let each = (width - gap * CGFloat(posters.count - 1)) / CGFloat(posters.count)
                    HStack(spacing: gap) { ForEach(posters, id: \.displayKey) { tile($0).frame(width: each, height: poster) } }
                        .frame(width: width, alignment: .leading)
                }
                if group.count == 5 {
                    tile(group[4], wide: true).frame(width: width, height: width * 0.5)
                } else if group.count > 5 {
                    HStack(spacing: gap) {
                        tile(group[4], wide: true).frame(width: column * 2 + gap, height: poster)
                        tile(group[5]).frame(width: column, height: poster)
                    }.frame(width: width, alignment: .leading)
                }
            }
            Color.clear.frame(height: 1).onAppear(perform: loadMore)
        }.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
    @ViewBuilder private func tile(_ item: CatalogItem, wide: Bool = false) -> some View {
        let art = wide ? (CatalogTools.image(item.backdropPath, size: "w780") ?? item.backdrop ?? item.artwork) : item.artwork
        let label = Artwork(path: art, title: item.name, initialsOnly: false)
            .overlay(alignment: .bottomLeading) {
                if wide {
                    Text(item.name).font(.system(size: width * 0.5 > 150 && item == items.first ? 26 : 18, weight: .bold)).tracking(-0.4)
                        .foregroundStyle(.white).lineLimit(1).truncationMode(.tail).padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12)).contentShape(RoundedRectangle(cornerRadius: 12))
        Group {
            if let id = item.inLibraryId { NavigationLink(value: id) { label.zoomSource(ZoomID.title(id)) } }
            else { NavigationLink(value: item.route) { label.zoomSource(ZoomID.catalog(item.route)) } }
        }.buttonStyle(.springPress).accessibilityLabel(item.name).accessibilityIdentifier("canvas-tile-" + item.displayKey)
    }
}

/// A 2 × 2 poster collage with the list's name and owner.
struct CanvasListCard: View {
    let list: CanvasList
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Plain rows of fixed squares (one layout pass), not a Grid of aspect-filled tiles,
            // which measured each of the four posters several times per card while scrolling.
            VStack(spacing: 2) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<2, id: \.self) { column in
                            let index = row * 2 + column
                            Color.clear.aspectRatio(1, contentMode: .fit)
                                .overlay { Artwork(path: index < list.posters.count ? CatalogTools.image(list.posters[index], size: "w185") : nil, title: list.name) }
                                .clipped()
                        }
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
                .padding([.horizontal, .top], 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(list.name).font(.system(size: 15, weight: .bold)).foregroundStyle(Color(webHex: "#f3f0f7")).lineLimit(1).truncationMode(.tail)
                Text("by " + list.user).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1).truncationMode(.tail)
            }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 14)
        }.background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 18)).accessibilityElement(children: .combine)
    }
}

/// Genres: every genre as a chip, any number picked (up to six), with Reset and ✕.
private struct CanvasGenreSheet: View {
    let names: [String]
    @Binding var genres: [String]
    @Binding var anime: Bool
    @Environment(\.dismiss) private var dismiss
    private var options: [String] { (names + ["Anime"]).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
    private var count: Int { genres.count + (anime ? 1 : 0) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("Genres").font(.system(size: 24, weight: .bold)).tracking(-0.4).foregroundStyle(HomeStyle.primary)
                    Spacer()
                    Button("Reset") { withAnimation(.snappy) { genres = []; anime = false } }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.chipText).buttonStyle(.plain)
                        .disabled(count == 0).opacity(count == 0 ? 0.45 : 1).frame(minHeight: 44).accessibilityIdentifier("canvas-genres-reset")
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.dateChipText)
                            .frame(width: 44, height: 44).background(HomeStyle.round, in: Circle())
                            .overlay(Circle().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                    }.buttonStyle(.plain).accessibilityLabel("Close")
                }
                Text(count >= 6 ? "Up to six genres; remove one to pick another." : "Pick one or more genres.").font(.system(size: 14)).foregroundStyle(HomeStyle.secondary)
                InlineFlowLayout {
                    ForEach(options, id: \.self) { name in
                        let on = name == "Anime" ? anime : genres.contains(name)
                        Button { withAnimation(.snappy(duration: 0.2)) { toggle(name) } } label: {
                            HStack(spacing: 6) {
                                if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
                                Text(name).lineLimit(1)
                            }.font(.system(size: 15, weight: .semibold)).foregroundStyle(on ? Color(webHex: "#1a1030") : Color(webHex: "#e6e1ee"))
                                .padding(.horizontal, 15).frame(height: 40)
                                .background(on ? AnyShapeStyle(LinearGradient(colors: [Color(webHex: "#cdbbff"), Color(webHex: "#a98bff")], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(HomeStyle.card), in: Capsule())
                                .overlay(Capsule().strokeBorder(on ? Color.clear : HomeStyle.dateChipBorder, lineWidth: 1))
                                .contentShape(Capsule())
                        }.buttonStyle(.plain).disabled(!on && count >= 6).opacity(!on && count >= 6 ? 0.45 : 1)
                            .accessibilityAddTraits(on ? .isSelected : []).accessibilityIdentifier("canvas-genre-" + name)
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 30)
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible).presentationBackground(Color(webHex: "#111116"))
            .sensoryFeedback(.selection, trigger: count)
    }
    private func toggle(_ name: String) {
        if name == "Anime" { anime.toggle(); return }
        if let index = genres.firstIndex(of: name) { genres.remove(at: index) } else if count < 6 { genres.append(name) }
    }
}

/// The titles on one Trakt list, in the list's order.
struct CanvasListView: View {
    let route: CanvasListRoute
    @Environment(DiaryStore.self) private var store
    @State private var loader: CanvasListItemsLoader?
    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 14) {
                Text("by " + route.user).font(.system(size: 14)).foregroundStyle(.secondary)
                if let loader {
                    if !loader.items.isEmpty { CatalogGrid(items: loader.items, showsLayoutToggle: false) }
                    if loader.loading && loader.items.isEmpty { DiaryLoadingPlaceholder(height: 320, label: "Loading titles") }
                    if let error = loader.error { Text(error).font(.system(size: 14)).foregroundStyle(.secondary) }
                    if loader.hasMore || (loader.loading && !loader.items.isEmpty) {
                        ScrollLoadTrigger(token: loader.items.count, loading: loader.loading) { Task { await loader.load(more: true) } }
                    }
                }
            }.padding(.horizontal, 14).padding(.bottom, 100)
                .smoothChange(of: loader?.items.isEmpty ?? true)
        }.diaryScreenBackground().navigationTitle(route.name).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .task {
                // Kept for a while across visits, so going back and forth shows the list at once.
                if loader == nil { loader = CanvasListItemsLoader.shared(store: store, id: route.id) }
                await loader?.load()
            }
    }
}
