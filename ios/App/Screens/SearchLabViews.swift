import SwiftUI
import TwilDiaryCore

struct SearchLabRoute: Hashable {}
struct SearchLabResultsRoute: Hashable { let filters: DiscoveryFilters }

/// Search Lab: every discover filter on one page, then "Show 48 titles".
struct SearchLabView: View {
    @Environment(DiaryStore.self) private var store
    @State private var filters = SearchLabView.blank
    @State private var tagQuery = ""
    @State private var foundTags: [TitleKeyword] = []
    @State private var tagNames: [Int: String] = [:]
    @State private var allGenres = false
    @State private var matchCount: Int?
    @State private var yourTags = SearchLabTags.shared
    static var blank: DiscoveryFilters { var value = DiscoveryFilters(section: .genres); value.type = "tv"; return value }
    private static let languages: [(String, String)] = [("ja", "Japanese"), ("en", "English"), ("ko", "Korean"), ("hi", "Hindi"), ("zh", "Chinese"), ("es", "Spanish"), ("fr", "French")]
    private static let decades: [(String, Int?, Int?)] = [("Any", nil, nil), ("2020s", 2020, nil), ("2010s", 2010, 2019), ("2000s", 2000, 2009), ("1990s", 1990, 1999), ("Older", nil, 1989)]
    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 22) {
                keywordField
                section("Type") {
                    LabSegments(options: [("all", "All titles"), ("tv", "Shows"), ("movie", "Movies")], selection: filters.type) { value in
                        filters.type = value
                        if value == "movie" { filters.showStatus = nil }
                        if let rating = filters.certification, !SearchLabData.ratings(type: value).contains(rating) { filters.certification = nil }
                        normalizeGenres()
                    }
                }
                section("Genre", trailing: (filters.genres ?? []).isEmpty ? nil : "\((filters.genres ?? []).count) selected") {
                    let names = DiscoveryGenre.names(type: filters.type)
                    InlineFlowLayout {
                        ForEach(allGenres ? names : Array(names.prefix(7)), id: \.self) { name in
                            LabChip(label: name, on: filters.genres?.contains(name) == true) { toggleGenre(name) }
                        }
                        if names.count > 7 {
                            Button { withAnimation(.snappy) { allGenres.toggle() } } label: {
                                HStack(spacing: 5) { Text(allGenres ? "Fewer" : "\(names.count - 7) more"); Image(systemName: allGenres ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .bold)) }
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.chipText).padding(.horizontal, 15).frame(height: 40)
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                                    .contentShape(Capsule())
                            }.buttonStyle(.plain).accessibilityIdentifier("search-lab-more-genres")
                        }
                    }
                }
                tagsSection
                section("Age rating") {
                    InlineFlowLayout {
                        LabChip(label: "Any", on: filters.certification == nil) { filters.certification = nil }
                        ForEach(SearchLabData.ratings(type: filters.type), id: \.self) { value in
                            LabChip(label: value, on: filters.certification == value) { filters.certification = filters.certification == value ? nil : value }
                        }
                    }
                }
                section("Minimum rating") {
                    HStack(spacing: 8) {
                        ForEach(["0", "6", "7", "8", "9"], id: \.self) { value in
                            LabChip(label: value == "0" ? "Any" : value + "+", on: filters.minimum == value, wide: true) { filters.minimum = value }
                        }
                    }
                }
                section("Year", trailing: yearText) {
                    VStack(spacing: 2) {
                        YearRangeSlider(from: $filters.yearFrom, to: $filters.yearTo, bounds: SearchLabData.lowestYear...SearchLabData.highestYear)
                        HStack { Text(String(SearchLabData.lowestYear)); Spacer(); Text(String(SearchLabData.highestYear)) }
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(HomeStyle.secondary).monospacedDigit()
                    }
                    InlineFlowLayout {
                        ForEach(Self.decades, id: \.0) { decade in
                            LabChip(label: decade.0, on: filters.yearFrom == decade.1 && filters.yearTo == decade.2) { filters.yearFrom = decade.1; filters.yearTo = decade.2 }
                        }
                    }
                }
                if filters.type != "movie" {
                    section("Status") {
                        InlineFlowLayout {
                            LabChip(label: "Any", on: filters.showStatus == nil) { filters.showStatus = nil }
                            ForEach([("returning", "Returning"), ("ended", "Ended"), ("canceled", "Canceled"), ("production", "In production")], id: \.0) { item in
                                LabChip(label: item.1, on: filters.showStatus == item.0) { filters.showStatus = filters.showStatus == item.0 ? nil : item.0 }
                            }
                        }
                    }
                }
                section("Language") {
                    InlineFlowLayout {
                        LabChip(label: "Any", on: filters.language == nil) { filters.language = nil }
                        ForEach(Self.languages, id: \.0) { item in LabChip(label: item.1, on: filters.language == item.0) { filters.language = filters.language == item.0 ? nil : item.0 } }
                    }
                }
                section("In your library") {
                    LabSegments(options: [("", "Any"), ("in", "In library"), ("not", "Not yet")], selection: filters.library ?? "") { filters.library = $0.isEmpty ? nil : $0 }
                }
                section("Sort by") {
                    InlineFlowLayout {
                        ForEach(LabSort.all, id: \.0) { item in LabChip(label: item.1, on: filters.sort == item.0) { filters.sort = item.0 } }
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 120)
        }.scrollDismissesKeyboard(.interactively)
            .diaryScreenBackground().navigationTitle("Search Lab").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { filters = Self.blank; tagQuery = ""; foundTags = []; allGenres = false } label: { Text("Reset").lineLimit(1).fixedSize() }
                        .font(.system(size: 15, weight: .semibold)).disabled(filters == Self.blank)
                        .accessibilityIdentifier("search-lab-reset")
                }
            }
            .safeAreaInset(edge: .bottom) {
                NavigationLink(value: SearchLabResultsRoute(filters: filters)) {
                    Text(showLabel).lineLimit(1).contentTransition(.numericText())
                }.buttonStyle(LabShowButtonStyle()).padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 8).accessibilityIdentifier("search-lab-show")
                    .background {
                        LinearGradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0.9), location: 0.4),
                                               .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea(edges: .bottom).allowsHitTesting(false)
                    }
            }
            .task(id: tagQuery) {
                let query = tagQuery.trimmingCharacters(in: .whitespaces)
                guard query.count >= 2 else { foundTags = []; return }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                struct Reply: Decodable { let items: [TitleKeyword] }
                if let token = TMDBDirect.token(store) {
                    if let tags = try? await TMDBDirect.keywords(query, token: token) { foundTags = tags }
                } else if let reply: Reply = try? await store.read(CatalogTools.apiPath("/api/metadata/keywords", query: ["q": query])) { foundTags = reply.items }
            }
            .task(id: filters) {
                // "Show 48 titles": TMDB's count for these filters (not knowable once your library narrows it).
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                guard filters.library == nil, filters.searchText.isEmpty else { withAnimation { matchCount = nil }; return }
                let page = try? await SearchLabData.page(filters, page: 1, store: store)
                if !Task.isCancelled { withAnimation { matchCount = page?.totalResults } }
            }
            .task { await yourTags.load(store: store) }
    }
    private var showLabel: String {
        guard let matchCount else { return "Show titles" }
        return matchCount == 0 ? "No titles match" : "Show " + matchCount.formatted() + (matchCount == 1 ? " title" : " titles")
    }
    private var keywordField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)).foregroundStyle(HomeStyle.secondary)
                TextField("Keyword or title (optional)", text: Binding(get: { filters.text ?? "" }, set: { filters.text = $0.isEmpty ? nil : $0 }))
                    .font(.system(size: 16)).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .accessibilityIdentifier("search-lab-keyword")
                if !(filters.text ?? "").isEmpty {
                    Button { filters.text = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(HomeStyle.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear keyword")
                }
            }.labField()
            if !filters.searchText.isEmpty {
                Text("A title search keeps type, genre, rating, year and language. Tags, age rating and status apply without a keyword.")
                    .font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder private var tagsSection: some View {
        let chosen = (filters.keywords ?? []).enumerated().map { index, id in TitleKeyword(id: id, name: tagNames[id] ?? filters.keywordNames?[safe: index] ?? "tag") }
        let found = foundTags.filter { tag in !chosen.contains { $0.id == tag.id } }
        let suggested = tagQuery.trimmingCharacters(in: .whitespaces).count >= 2 ? [] : yourTags.top.filter { tag in !chosen.contains { $0.id == tag.id } }
        section("Tags", trailing: chosen.isEmpty ? nil : "\(chosen.count) selected") {
            HStack(spacing: 10) {
                Text("#").font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                TextField("Find a tag", text: $tagQuery).font(.system(size: 16)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("search-lab-tag-field")
            }.labField()
            if !(chosen.isEmpty && found.isEmpty && suggested.isEmpty) {
                InlineFlowLayout {
                    ForEach(chosen) { tag in LabChip(label: "#" + tag.name, on: true) { toggleTag(tag) } }
                    ForEach(found) { tag in LabChip(label: "#" + tag.name, on: false) { toggleTag(tag) } }
                    ForEach(suggested) { tag in LabChip(label: "#" + tag.keyword.name, count: tag.count, on: false) { toggleTag(tag.keyword) } }
                }
            }
            if chosen.count > 1 {
                HStack(spacing: 10) {
                    Button { filters.matchAllKeywords = !(filters.matchAllKeywords ?? false) } label: {
                        Text(filters.matchAllKeywords == true ? "Match all" : "Match any").font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                            .padding(.horizontal, 12).frame(height: 32).background(HomeStyle.chip, in: Capsule())
                    }.buttonStyle(.plain).frame(minHeight: 44).contentShape(Rectangle()).accessibilityIdentifier("search-lab-match")
                    Text(filters.matchAllKeywords == true ? "Every tag is required" : "Switch to \u{201C}Match all\u{201D} to require every tag")
                        .font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(2)
                }
            }
        }
    }
    private var yearText: String? {
        switch (filters.yearFrom, filters.yearTo) {
        case (nil, nil): nil
        case (let from?, let to?): "\(from) – \(to)"
        case (let from?, nil): "\(from) – \(SearchLabData.highestYear)"
        case (nil, let to?): "Up to \(to)"
        }
    }
    private func section<Content: View>(_ title: String, trailing: String? = nil, badge: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title.uppercased()).font(.system(size: 12, weight: .bold)).tracking(1).foregroundStyle(HomeStyle.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.chipText).monospacedDigit().contentTransition(.numericText()) }
                if let badge { Text(badge).font(.system(size: 11, weight: .bold)).foregroundStyle(Color(webHex: "#c5c0cf")).padding(.horizontal, 9).frame(height: 24).background(.white.opacity(0.08), in: Capsule()) }
            }
            content()
        }
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
        var ids = filters.keywords ?? [], names = filters.keywordNames ?? ids.map { tagNames[$0] ?? "tag" }
        if let index = ids.firstIndex(of: tag.id) { ids.remove(at: index); if index < names.count { names.remove(at: index) } }
        else if ids.count < 10 { ids.append(tag.id); names.append(tag.name); tagNames[tag.id] = tag.name }
        filters.keywords = ids.isEmpty ? nil : ids
        filters.keywordNames = ids.isEmpty ? nil : names
        filters.label = nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

enum LabSort {
    static let all: [(String, String)] = [("popular", "Recommended"), ("rating", "Highest rated"), ("newest", "Newest"), ("votes", "Most popular")]
    static func label(_ sort: String) -> String { all.first { $0.0 == sort }?.1 ?? "Recommended" }
}

/// A Search Lab choice: accent when chosen, a dark outlined pill otherwise; a tag can show how
/// many of your titles carry it.
struct LabChip: View {
    let label: String
    var count: Int? = nil
    let on: Bool
    var wide = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label).lineLimit(1).truncationMode(.tail)
                if let count { Text(String(count)).font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color(webHex: "#1a1030").opacity(0.7) : HomeStyle.secondary).monospacedDigit() }
            }
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(on ? Color(webHex: "#1a1030") : Color(webHex: "#e6e1ee"))
            .padding(.horizontal, 15).frame(maxWidth: wide ? .infinity : nil).frame(height: 40)
            .background(on ? AnyShapeStyle(LinearGradient(colors: [Color(webHex: "#cdbbff"), Color(webHex: "#a98bff")], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(HomeStyle.card), in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color.clear : HomeStyle.dateChipBorder, lineWidth: 1))
            .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Two or three choices in one track (Type, In your library).
struct LabSegments: View {
    let options: [(String, String)]
    let selection: String
    let choose: (String) -> Void
    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { option in
                let on = option.0 == selection
                Button { withAnimation(.snappy(duration: 0.25)) { choose(option.0) } } label: {
                    Text(option.1).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                        .foregroundStyle(on ? Color(webHex: "#1a1030") : Color(webHex: "#c5c0cf"))
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background { if on { Capsule().fill(LinearGradient(colors: [Color(webHex: "#cdbbff"), Color(webHex: "#a98bff")], startPoint: .top, endPoint: .bottom)) } }
                        .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }.padding(4).background(HomeStyle.card, in: Capsule()).overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: 1))
    }
}

/// "From" and "to" on one track. A thumb at either end means no limit that side.
struct YearRangeSlider: View {
    @Binding var from: Int?
    @Binding var to: Int?
    let bounds: ClosedRange<Int>
    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 14
            let width = max(1, geo.size.width - inset * 2)
            let span = CGFloat(max(1, bounds.upperBound - bounds.lowerBound))
            let lower = min(max(from ?? bounds.lowerBound, bounds.lowerBound), bounds.upperBound)
            let upper = max(min(to ?? bounds.upperBound, bounds.upperBound), lower)
            let x: (Int) -> CGFloat = { inset + width * CGFloat($0 - bounds.lowerBound) / span }
            let year: (CGFloat) -> Int = { bounds.lowerBound + Int(((min(max($0, inset), inset + width) - inset) / width * span).rounded()) }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(width: width, height: 4).offset(x: inset)
                Capsule().fill(LinearGradient(colors: [Color(webHex: "#cdbbff"), Color(webHex: "#a98bff")], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, x(upper) - x(lower)), height: 4).offset(x: x(lower))
                thumb("Earliest year", value: lower)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("years")).onChanged { drag in
                        let value = min(year(drag.location.x), upper); from = value == bounds.lowerBound ? nil : value
                    })
                    .accessibilityAdjustableAction { direction in
                        let value = min(max(lower + (direction == .increment ? 1 : -1), bounds.lowerBound), upper); from = value == bounds.lowerBound ? nil : value
                    }
                    .position(x: x(lower), y: 22)
                thumb("Latest year", value: upper)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("years")).onChanged { drag in
                        let value = max(year(drag.location.x), lower); to = value == bounds.upperBound ? nil : value
                    })
                    .accessibilityAdjustableAction { direction in
                        let value = max(min(upper + (direction == .increment ? 1 : -1), bounds.upperBound), lower); to = value == bounds.upperBound ? nil : value
                    }
                    .position(x: x(upper), y: 22)
            }.frame(width: geo.size.width, height: 44).coordinateSpace(.named("years"))
        }.frame(height: 44).sensoryFeedback(.selection, trigger: (from ?? 0) + (to ?? 0) * 10_000)
    }
    private func thumb(_ label: String, value: Int) -> some View {
        Circle().fill(.white).frame(width: 26, height: 26).shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            .frame(width: 44, height: 44).contentShape(Circle())
            .accessibilityElement().accessibilityLabel(label).accessibilityValue(String(value))
    }
}

/// "Show 48 titles": the full-width gradient pill at the bottom of Search Lab.
struct LabShowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 17, weight: .bold)).foregroundStyle(HomeStyle.chipText)
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(HomeStyle.chip, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1).scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private extension View {
    /// Search Lab's text fields: a dark rounded box with a hairline edge.
    func labField() -> some View {
        padding(.horizontal, 16).frame(height: 50)
            .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HomeStyle.dateChipBorder, lineWidth: 1))
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
    @State private var total: Int?
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
    private var countText: String {
        if loading && items.isEmpty { return "Loading…" }
        if filters.library == nil, let total { return total.counted("title", "titles") }
        return shown.count.counted("title", "titles") + (page < totalPages ? "+" : "")
    }
    var body: some View {
        let shown = shown
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 14) {
                let chips = chips
                if !chips.isEmpty {
                    InlineFlowLayout { ForEach(chips, id: \.0) { chip in removable(chip.0, chip.1) } }
                }
                HStack(spacing: 10) {
                    Text(countText).font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).monospacedDigit().lineLimit(1)
                    Spacer(minLength: 8)
                    Menu {
                        Picker("Sort", selection: $filters.sort) { ForEach(LabSort.all, id: \.0) { Text($0.1).tag($0.0) } }
                    } label: {
                        HStack(spacing: 6) { Image(systemName: "arrow.up.arrow.down").font(.system(size: 12, weight: .bold)); Text(LabSort.label(filters.sort)).lineLimit(1) }
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(webHex: "#e6e1ee"))
                            .padding(.horizontal, 14).frame(height: 34).background(HomeStyle.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: 1)).frame(minHeight: 44).contentShape(Capsule())
                    }.accessibilityLabel("Sort, " + LabSort.label(filters.sort)).accessibilityIdentifier("search-lab-sort")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 18) {
                    ForEach(shown, id: \.key) { item in
                        Group {
                            if let id = CatalogTools.libraryIdentity(item, in: store.workspace) { NavigationLink(value: id) { CatalogPoster(item: item) } }
                            else { NavigationLink(value: item.route) { CatalogPoster(item: item) } }
                        }.buttonStyle(.springPress).onAppear { if item.key == items.last?.key { Task { await load(more: true) } } }
                    }
                }
                if loading && items.isEmpty { DiaryLoadingPlaceholder(height: 240, label: "Loading titles") }
                if let failure { RetryNotice(message: failure) { Task { await load() } } }
                if !loading && shown.isEmpty && failure == nil {
                    Text("No titles match these filters. Remove one to widen the search.").font(.system(size: 14)).foregroundStyle(HomeStyle.secondary)
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }.diaryScreenBackground().navigationTitle("Search Lab").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 16, weight: .semibold))
                    }.accessibilityLabel("Edit filters").accessibilityIdentifier("search-lab-edit")
                }
            }
            .task(id: filters) { await load() }
    }
    /// Every filter that narrows the list, each removable on its own.
    private var chips: [(String, () -> Void)] {
        var result: [(String, () -> Void)] = []
        if !filters.searchText.isEmpty { result.append(("\u{201C}" + filters.searchText + "\u{201D}", { filters.text = nil })) }
        if filters.type != "all" { result.append((filters.type == "movie" ? "Movies" : "Shows", { filters.type = "all" })) }
        for genre in filters.genres ?? [] { result.append((genre, { filters.genres = (filters.genres ?? []).filter { $0 != genre }; if filters.genres?.isEmpty == true { filters.genres = nil } })) }
        for (index, id) in (filters.keywords ?? []).enumerated() {
            let name = filters.keywordNames.flatMap { index < $0.count ? $0[index] : nil } ?? "tag"
            result.append(("#" + name, { removeTag(id) }))
        }
        if let value = filters.certification { result.append((value, { filters.certification = nil })) }
        if filters.minimum != "0" { result.append((filters.minimum + "+", { filters.minimum = "0" })) }
        if filters.yearFrom != nil || filters.yearTo != nil {
            let label = filters.yearFrom == nil ? "Up to \(filters.yearTo ?? 0)" : "\(filters.yearFrom ?? 0)–\(filters.yearTo ?? SearchLabData.highestYear)"
            result.append((label, { filters.yearFrom = nil; filters.yearTo = nil }))
        }
        if let value = filters.showStatus { result.append((value == "production" ? "In production" : value.capitalized, { filters.showStatus = nil })) }
        if let value = filters.language { result.append((Locale.current.localizedString(forLanguageCode: value) ?? value, { filters.language = nil })) }
        if let value = filters.library { result.append((value == "in" ? "In library" : "Not yet in library", { filters.library = nil })) }
        return result
    }
    private func removeTag(_ id: Int) {
        guard let index = filters.keywords?.firstIndex(of: id) else { return }
        filters.keywords?.remove(at: index)
        if let count = filters.keywordNames?.count, index < count { filters.keywordNames?.remove(at: index) }
        if filters.keywords?.isEmpty == true { filters.keywords = nil; filters.keywordNames = nil }
    }
    private func removable(_ label: String, _ remove: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { remove() } } label: {
            HStack(spacing: 6) { Text(label).lineLimit(1).truncationMode(.tail); Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).opacity(0.8) }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.chipText).padding(.horizontal, 12).frame(height: 32)
                .background(HomeStyle.chip, in: Capsule()).frame(minHeight: 40).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel("Remove " + label)
    }
    private func load(more: Bool = false) async {
        if more && (loading || page >= totalPages) { return }
        if !more { items = []; page = 0; totalPages = 1; total = nil }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let next = try await SearchLabData.page(filters, page: page + 1, store: store)
            items = CatalogTools.merging(items, next.items); page = next.page; totalPages = next.totalPages
            if !more { total = next.totalResults }
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}
