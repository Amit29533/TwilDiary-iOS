import SwiftUI
import TwilDiaryCore

struct SearchLabRoute: Hashable {}
struct SearchLabResultsRoute: Hashable { let filters: DiscoveryFilters }

/// Search Lab: every TMDB discover filter on one page, then "Show titles".
struct SearchLabView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var filters = SearchLabView.blank
    @State private var tagQuery = ""
    @State private var foundTags: [TitleKeyword] = []
    @State private var tagNames: [Int: String] = [:]
    @State private var allGenres = false
    static var blank: DiscoveryFilters { var value = DiscoveryFilters(section: .genres); value.type = "tv"; return value }
    private static let languages: [(String, String)] = [("ja", "Japanese"), ("en", "English"), ("ko", "Korean"), ("hi", "Hindi"), ("zh", "Chinese"), ("es", "Spanish"), ("fr", "French")]
    private static let decades: [(String, Int?, Int?)] = [("Any", nil, nil), ("2020s", 2020, 2029), ("2010s", 2010, 2019), ("2000s", 2000, 2009), ("1990s", 1990, 1999), ("Older", nil, 1989)]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Type") {
                    HStack(spacing: 4) {
                        segment("Shows", on: filters.type == "tv") { filters.type = "tv"; filters.certification = nil; normalizeGenres() }
                        segment("Movies", on: filters.type == "movie") { filters.type = "movie"; filters.showStatus = nil; normalizeGenres() }
                    }.padding(4).background(.white.opacity(0.06), in: Capsule())
                }
                section("Genre", trailing: (filters.genres ?? []).isEmpty ? nil : "\((filters.genres ?? []).count) selected") {
                    let names = DiscoveryGenre.names(type: filters.type)
                    InlineFlowLayout {
                        ForEach(allGenres ? names : Array(names.prefix(7)), id: \.self) { name in
                            chip(name, on: filters.genres?.contains(name) == true) { toggleGenre(name) }
                        }
                        if !allGenres && names.count > 7 {
                            Button { allGenres = true } label: {
                                HStack(spacing: 4) { Text("\(names.count - 7) more"); DiaryIcon(name: "chevron-down", size: 12) }
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent).padding(.horizontal, 14).frame(height: 40)
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                section("Tags", trailing: (filters.keywords ?? []).isEmpty ? nil : "\((filters.keywords ?? []).count) selected") {
                    HStack(spacing: 8) {
                        Text("#").foregroundStyle(.secondary)
                        TextField("Find a tag", text: $tagQuery).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }.padding(.horizontal, 16).frame(height: 50).background(.white.opacity(0.07), in: Capsule())
                    let chosen = (filters.keywords ?? []).compactMap { id in tagNames[id].map { TitleKeyword(id: id, name: $0) } }
                    let shown = chosen + foundTags.filter { tag in !chosen.contains(where: { $0.id == tag.id }) }
                    if !shown.isEmpty {
                        InlineFlowLayout {
                            ForEach(shown) { tag in chip("#" + tag.name, on: filters.keywords?.contains(tag.id) == true) { toggleTag(tag) } }
                        }
                    }
                    if (filters.keywords ?? []).count > 1 {
                        HStack(spacing: 10) {
                            Button { filters.matchAllKeywords = !(filters.matchAllKeywords ?? false) } label: {
                                Text(filters.matchAllKeywords == true ? "Match all" : "Match any").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 12).frame(height: 32).background(theme.accent.opacity(0.3), in: Capsule())
                            }.buttonStyle(.plain)
                            Text(filters.matchAllKeywords == true ? "Every tag is required" : "Switch to \u{201C}Match all\u{201D} to require every tag").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
                if filters.type == "movie" {
                    section("Age rating") {
                        InlineFlowLayout {
                            chip("Any", on: filters.certification == nil) { filters.certification = nil }
                            ForEach(["G", "PG", "PG-13", "R", "NC-17"], id: \.self) { value in chip(value, on: filters.certification == value) { filters.certification = value } }
                        }
                    }
                }
                section("Minimum rating", badge: "TMDB") {
                    HStack(spacing: 8) {
                        ForEach(["0", "6", "7", "8", "9"], id: \.self) { value in
                            chip(value == "0" ? "Any" : value + "+", on: filters.minimum == value, wide: true) { filters.minimum = value }
                        }
                    }
                }
                section("Year", trailing: yearText) {
                    InlineFlowLayout {
                        ForEach(Self.decades, id: \.0) { decade in
                            chip(decade.0, on: filters.yearFrom == decade.1 && filters.yearTo == decade.2) { filters.yearFrom = decade.1; filters.yearTo = decade.2 }
                        }
                    }
                    HStack(spacing: 10) {
                        yearMenu("From", value: $filters.yearFrom)
                        yearMenu("To", value: $filters.yearTo)
                    }
                }
                if filters.type == "tv" {
                    section("Status") {
                        InlineFlowLayout {
                            chip("Any", on: filters.showStatus == nil) { filters.showStatus = nil }
                            ForEach([("returning", "Returning"), ("ended", "Ended"), ("canceled", "Canceled"), ("production", "In production")], id: \.0) { item in
                                chip(item.1, on: filters.showStatus == item.0) { filters.showStatus = item.0 }
                            }
                        }
                    }
                }
                section("Language") {
                    InlineFlowLayout {
                        chip("Any", on: filters.language == nil) { filters.language = nil }
                        ForEach(Self.languages, id: \.0) { item in chip(item.1, on: filters.language == item.0) { filters.language = item.0 } }
                    }
                }
                section("In your library") {
                    HStack(spacing: 4) {
                        segment("Any", on: filters.library == nil) { filters.library = nil }
                        segment("In library", on: filters.library == "in") { filters.library = "in" }
                        segment("Not yet", on: filters.library == "not") { filters.library = "not" }
                    }.padding(4).background(.white.opacity(0.06), in: Capsule())
                }
                section("Sort by") {
                    InlineFlowLayout {
                        ForEach([("popular", "Recommended"), ("rating", "Highest rated"), ("newest", "Newest")], id: \.0) { item in
                            chip(item.1, on: filters.sort == item.0) { filters.sort = item.0 }
                        }
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 120)
        }.diaryScreenBackground().navigationTitle("Search Lab").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Reset") { filters = Self.blank; tagQuery = ""; foundTags = [] }.accessibilityIdentifier("search-lab-reset") } }
            .safeAreaInset(edge: .bottom) {
                NavigationLink(value: SearchLabResultsRoute(filters: filters)) {
                    Text("Show titles").font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 58).background(theme.accent, in: Capsule())
                }.buttonStyle(.springPress).padding(.horizontal, 16).padding(.bottom, 8).accessibilityIdentifier("search-lab-show")
            }
            .task(id: tagQuery) {
                let query = tagQuery.trimmingCharacters(in: .whitespaces)
                guard query.count >= 2 else { foundTags = []; return }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                struct Reply: Decodable { let items: [TitleKeyword] }
                if let reply: Reply = try? await store.read(CatalogTools.apiPath("/api/metadata/keywords", query: ["q": query])) { foundTags = reply.items }
            }
    }
    private var yearText: String? {
        switch (filters.yearFrom, filters.yearTo) {
        case (nil, nil): nil
        case (let from?, let to?): "\(from) – \(to)"
        case (let from?, nil): "From \(from)"
        case (nil, let to?): "Up to \(to)"
        }
    }
    private func yearMenu(_ label: String, value: Binding<Int?>) -> some View {
        let years = Array((1950...Calendar.current.component(.year, from: .now) + 1).reversed())
        return Menu {
            Picker(label, selection: value) { Text("Any").tag(Int?.none); ForEach(years, id: \.self) { Text(String($0)).tag(Int?.some($0)) } }
        } label: { FilterPill(label: label + " " + (value.wrappedValue.map(String.init) ?? "any"), active: value.wrappedValue != nil) }
    }
    private func section<Content: View>(_ title: String, trailing: String? = nil, badge: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title.uppercased()).font(.system(size: 13, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent) }
                if let badge { Text(badge).font(.system(size: 11, weight: .bold)).foregroundStyle(Color(webHex: "#c5c0cf")).padding(.horizontal, 9).frame(height: 24).background(.white.opacity(0.08), in: Capsule()) }
            }
            content()
        }
    }
    private func chip(_ label: String, on: Bool, wide: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(on ? theme.ink : Color(webHex: "#e6e1ee")).lineLimit(1)
                .padding(.horizontal, 15).frame(maxWidth: wide ? .infinity : nil).frame(height: 40)
                .background(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.white.opacity(0.07)), in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
    private func segment(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(on ? theme.ink : Color(webHex: "#c5c0cf"))
                .frame(maxWidth: .infinity).frame(height: 42).background { if on { Capsule().fill(theme.accent) } }.contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
    private func toggleGenre(_ name: String) {
        var values = filters.genres ?? []
        if let index = values.firstIndex(of: name) { values.remove(at: index) } else if values.count < 6 { values.append(name) }
        filters.genres = values.isEmpty ? nil : values
    }
    private func normalizeGenres() {
        let allowed = Set(DiscoveryGenre.names(type: filters.type))
        let kept = (filters.genres ?? []).filter { allowed.contains($0) }
        filters.genres = kept.isEmpty ? nil : kept
    }
    private func toggleTag(_ tag: TitleKeyword) {
        var values = filters.keywords ?? []
        if let index = values.firstIndex(of: tag.id) { values.remove(at: index) } else if values.count < 10 { values.append(tag.id); tagNames[tag.id] = tag.name }
        filters.keywords = values.isEmpty ? nil : values
        filters.label = nil
    }
}

/// Search Lab's results: what was chosen as removable chips, the count and order, then the grid.
struct SearchLabResultsView: View {
    @State private var filters: DiscoveryFilters
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CatalogItem] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var failure: String?
    init(route: SearchLabResultsRoute) { _filters = State(initialValue: route.filters) }
    private var shown: [CatalogItem] {
        switch filters.library {
        case "in": items.filter { CatalogTools.libraryIdentity($0, in: store.workspace) != nil }
        case "not": items.filter { CatalogTools.libraryIdentity($0, in: store.workspace) == nil }
        default: items
        }
    }
    var body: some View {
        let shown = shown
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InlineFlowLayout { ForEach(chips, id: \.0) { chip in removable(chip.0, chip.1) } }
                HStack {
                    Text(loading && items.isEmpty ? "Loading…" : shown.count.counted("title", "titles") + (page < totalPages ? "+" : "")).font(.system(size: 15)).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Picker("Sort", selection: $filters.sort) { Text("Recommended").tag("popular"); Text("Highest rated").tag("rating"); Text("Newest").tag("newest") }
                    } label: { FilterPill(label: filters.sort == "rating" ? "Highest rated" : filters.sort == "newest" ? "Newest" : "Recommended", icon: "arrow-down-up") }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 18) {
                    ForEach(shown, id: \.key) { item in
                        Group {
                            if let id = CatalogTools.libraryIdentity(item, in: store.workspace) { NavigationLink(value: id) { CatalogPoster(item: item) } }
                            else { NavigationLink(value: item.route) { CatalogPoster(item: item) } }
                        }.buttonStyle(.springPress).onAppear { if item.key == items.last?.key { Task { await load(more: true) } } }
                    }
                }
                if let failure { RetryNotice(message: failure) { Task { await load() } } }
                if !loading && shown.isEmpty && failure == nil { Text("No titles match these filters. Remove one to widen the search.").font(.subheadline).foregroundStyle(.secondary) }
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 40)
        }.diaryScreenBackground().navigationTitle("Search Lab").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Edit filters") } }
            .task(id: filters) { await load() }
    }
    private var chips: [(String, () -> Void)] {
        var result: [(String, () -> Void)] = [(filters.type == "movie" ? "Movies" : "Shows", {})]
        for genre in filters.genres ?? [] { result.append((genre, { filters.genres = (filters.genres ?? []).filter { $0 != genre }; if filters.genres?.isEmpty == true { filters.genres = nil } })) }
        if let count = filters.keywords?.count, count > 0 { result.append(("\(count) \(count == 1 ? "tag" : "tags")", { filters.keywords = nil })) }
        if let value = filters.certification { result.append((value, { filters.certification = nil })) }
        if filters.minimum != "0" { result.append((filters.minimum + "+", { filters.minimum = "0" })) }
        if filters.yearFrom != nil || filters.yearTo != nil { result.append(("\(filters.yearFrom.map(String.init) ?? "…")–\(filters.yearTo.map(String.init) ?? "now")", { filters.yearFrom = nil; filters.yearTo = nil })) }
        if let value = filters.showStatus { result.append((value.capitalized, { filters.showStatus = nil })) }
        if let value = filters.language { result.append((Locale.current.localizedString(forLanguageCode: value) ?? value, { filters.language = nil })) }
        if let value = filters.library { result.append((value == "in" ? "In library" : "Not yet in library", { filters.library = nil })) }
        return result
    }
    private func removable(_ label: String, _ remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 6) { Text(label); Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(webHex: "#e6e1ee")).padding(.horizontal, 12).frame(height: 36)
                .background(Color(webHex: "#2a2440"), in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel("Remove " + label)
    }
    private func load(more: Bool = false) async {
        if more && (loading || page >= totalPages) { return }
        if !more { items = []; page = 0; totalPages = 1 }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let next = try await LiveDiscoveryService(store: store).page(filters.query(section: .genres, page: page + 1))
            items = CatalogTools.merging(items, next.items); page = next.page; totalPages = next.totalPages
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}
