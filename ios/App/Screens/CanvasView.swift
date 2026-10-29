import SwiftUI
import TwilDiaryCore

/// Canvas (owner's design): Movies · Shows · Lists as large text tabs, a row of filter pills,
/// then an artwork mosaic for titles or poster-collage cards for Trakt lists.
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
    @State private var results: DiscoveryResults
    @State private var recommendations: DiscoveryRecommendations
    @State private var lists: CanvasListsLoader
    /// Sort and list choices are remembered between visits; one-off filters (genre, year, rating) start fresh.
    @AppStorage("canvasSort") private var sort = CanvasSort.popular
    @State private var genre = ""
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
        var value = ["source": "tmdb", "type": kind.rawValue, "sort": sort.rawValue, "genre": genre, "year": validYear ? year : "", "minimum": minimum, "page": "1"]
        if let network, kind == .tv { value["network"] = String(network) }
        return value
    }
    private var titles: [CatalogItem] {
        guard sort == .recommended else { return results.items }
        var filters = DiscoveryFilters(section: .recommended)
        filters.type = kind.rawValue; filters.genre = genre; filters.year = year; filters.minimum = minimum
        return filters.applying(recommendations.items)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pills
                if tab == .lists { listsContent } else { titlesContent }
            }.padding(.horizontal, 12).padding(.bottom, 100)
        }.diaryScreenBackground().navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            // The tabs share the navigation bar with the back button.
            .toolbar { ToolbarItem(placement: .principal) { tabs } }
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
    private var tabs: some View {
        HStack(spacing: 18) {
            ForEach(CanvasTab.allCases, id: \.self) { item in
                Button { tab = item; if item == .movies { network = nil } } label: {
                    Text(item.label).font(.system(size: 24, weight: .bold)).tracking(-0.6)
                        .foregroundStyle(tab == item ? Color(webHex: "#f3f0f7") : .white.opacity(0.4))
                }.buttonStyle(.plain).accessibilityAddTraits(tab == item ? .isSelected : []).accessibilityIdentifier("canvas-tab-" + item.rawValue)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var pills: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                if tab == .lists {
                    Menu { Picker("Sort lists", selection: $listSort) { Text("Trending").tag("trending"); Text("Popular").tag("popular") } }
                        label: { pill(listSort.capitalized, icon: "sliders-horizontal") }.accessibilityIdentifier("canvas-list-sort")
                    Menu { Picker("List type", selection: $listKind) { Text("Personal").tag("personal"); Text("Official").tag("official") } }
                        label: { pill(listKind.capitalized) }.accessibilityIdentifier("canvas-list-kind")
                } else {
                    Menu { Picker("Sort", selection: $sort) { ForEach(CanvasSort.allCases) { Text($0.label).tag($0) } } }
                        label: { pill(sort.label, icon: "sliders-horizontal") }.accessibilityIdentifier("canvas-sort")
                    Menu { Picker("Genre", selection: $genre) { Text("All genres").tag(""); ForEach(DiscoveryGenre.names(type: kind.rawValue), id: \.self) { Text($0).tag($0) } } }
                        label: { pill(genre.isEmpty ? "Genres" : genre, active: !genre.isEmpty) }.accessibilityIdentifier("canvas-genre")
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
            .onChange(of: tab) { _, _ in genre = "" }
    }
    private func pill(_ label: String?, icon: String? = nil, active: Bool = false) -> some View {
        HStack(spacing: 8) {
            if let icon { DiaryIcon(name: icon, size: 18) }
            if let label { Text(label).font(.system(size: 17, weight: .medium)).lineLimit(1); DiaryIcon(name: "chevron-down", size: 14) }
        }.foregroundStyle(active ? theme.accent : Color(webHex: "#f3f0f7"))
            .padding(.horizontal, label == nil ? 18 : 16).frame(height: 44)
            .background(.white.opacity(0.09), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.14)))
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
                if group.count > 1 {
                    HStack(spacing: gap) { ForEach(group[1..<min(4, group.count)], id: \.displayKey) { tile($0).frame(width: column, height: poster) } }
                        .frame(width: width, alignment: .leading)
                }
                if group.count > 4 {
                    HStack(spacing: gap) {
                        tile(group[4], wide: true).frame(width: column * 2 + gap, height: poster)
                        if group.count > 5 { tile(group[5]).frame(width: column, height: poster) }
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
                        .foregroundStyle(.white).lineLimit(2).shadow(color: .black.opacity(0.6), radius: 6, y: 1).padding(16)
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
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow { ForEach(0..<2, id: \.self) { column in
                        let index = row * 2 + column
                        Artwork(path: index < list.posters.count ? CatalogTools.image(list.posters[index], size: "w185") : nil, title: list.name)
                            .aspectRatio(1, contentMode: .fill).frame(minWidth: 0, maxWidth: .infinity).clipped()
                    } }
                }
            }.aspectRatio(1, contentMode: .fit).clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text(list.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7")).lineLimit(1)
                Text("by " + list.user).font(.system(size: 14)).foregroundStyle(Color(webHex: "#a09aa9")).lineLimit(1)
            }.padding(.horizontal, 12).padding(.vertical, 10)
        }.background(.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityElement(children: .combine)
    }
}

/// The titles on one Trakt list, in the list's order.
struct CanvasListView: View {
    let route: CanvasListRoute
    @Environment(DiaryStore.self) private var store
    @State private var loader: CanvasListItemsLoader?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("by " + route.user).font(.system(size: 14)).foregroundStyle(.secondary)
                if let loader {
                    if !loader.items.isEmpty { CatalogGrid(items: loader.items, showsLayoutToggle: false) }
                    if loader.loading { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20) }
                    if let error = loader.error { Text(error).font(.system(size: 14)).foregroundStyle(.secondary) }
                    if loader.hasMore && !loader.loading { Button("Load more") { Task { await loader.load(more: true) } }.buttonStyle(.glass).frame(maxWidth: .infinity) }
                }
            }.padding(.horizontal, 14).padding(.bottom, 100)
        }.diaryScreenBackground().navigationTitle(route.name).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .task {
                if loader == nil { loader = CanvasListItemsLoader(store: store, id: route.id) }
                await loader?.load()
            }
    }
}
