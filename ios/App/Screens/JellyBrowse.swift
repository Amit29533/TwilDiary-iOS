import SwiftUI

// MARK: Sort, order and filters for a library, folder or list

/// What a library, folder or list shows: its sort and order, and its filters. Each one keeps its own
/// (Settings stay out of it: the ••• menu changes them, and they're remembered).
struct JellyBrowseOptions: Codable, Equatable {
    var sort: JellyfinClient.Sort = .name
    /// nil: the sort's own way round (A to Z, newest first, best first, shortest first).
    var ascending: Bool? = nil
    var show: Show = .all
    var genres: [String] = []
    /// 1990 for the 1990s.
    var decade: Int? = nil
    var quality: Quality = .any

    enum Show: String, Codable, CaseIterable {
        case all, unwatched, watched, inProgress, favourites
        var title: String {
            switch self {
            case .all: "All"
            case .unwatched: "Unwatched"
            case .watched: "Watched"
            case .inProgress: "In progress"
            case .favourites: "Favourites"
            }
        }
    }
    enum Quality: String, Codable, CaseIterable {
        case any, uhd, hd, sd
        var title: String {
            switch self {
            case .any: "Any"
            case .uhd: "4K"
            case .hd: "HD"
            case .sd: "SD"
            }
        }
    }
    static let decades = Array(stride(from: 2020, through: 1950, by: -10))

    var isAscending: Bool { ascending ?? sort.ascendingByDefault }
    /// Any filter on (the ••• button shows a dot).
    var filtering: Bool { show != .all || !genres.isEmpty || decade != nil || quality != .any }
    /// "Unwatched · Drama · 1990s", or "None".
    var filterSummary: String {
        let parts = [show == .all ? nil : show.title, genres.isEmpty ? nil : genres.joined(separator: ", "),
                     decade.map { "\($0)s" }, quality == .any ? nil : quality.title].compactMap { $0 }
        return parts.isEmpty ? "None" : parts.joined(separator: " · ")
    }
    /// Jellyfin's watch-state filter for `show`.
    var showFilter: String? {
        switch show {
        case .all: nil
        case .unwatched: "IsUnplayed"
        case .watched: "IsPlayed"
        case .inProgress: "IsResumable"
        case .favourites: "IsFavorite"
        }
    }
    /// The request's sort, order and filters. `attributes`: the genre, decade and quality filters
    /// too (a whole library's titles; not a folder's own level, whose folders they'd hide).
    func query(attributes: Bool) -> [URLQueryItem] {
        var items = sort.query(ascending: isAscending)
        if let showFilter { items.append(URLQueryItem(name: "Filters", value: showFilter)) }
        guard attributes else { return items }
        if !genres.isEmpty { items.append(URLQueryItem(name: "Genres", value: genres.joined(separator: "|"))) }
        if let decade { items.append(URLQueryItem(name: "Years", value: (decade..<decade + 10).map(String.init).joined(separator: ","))) }
        switch quality {
        case .any: break
        case .uhd: items.append(URLQueryItem(name: "is4K", value: "true"))
        case .hd: items += [URLQueryItem(name: "isHd", value: "true"), URLQueryItem(name: "is4K", value: "false")]
        case .sd: items.append(URLQueryItem(name: "isHd", value: "false"))
        }
        return items
    }

    /// Kept as JSON under one key per section; a section never set starts from the sort last used
    /// everywhere (the old single Sort setting).
    static func key(_ section: String) -> String { "jellyspace.options." + section }
    static func decode(_ raw: String) -> JellyBrowseOptions {
        if let data = raw.data(using: .utf8), let options = try? JSONDecoder().decode(JellyBrowseOptions.self, from: data) { return options }
        var fresh = JellyBrowseOptions()
        if let legacy = UserDefaults.standard.string(forKey: "jellyspace.sort").flatMap(JellyfinClient.Sort.init(rawValue:)) { fresh.sort = legacy }
        return fresh
    }
    var encoded: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
}

extension JellyfinClient.Sort: Codable {}

// MARK: The ••• menu

/// A library's, folder's or list's ••• menu, short: Content, View, Sort by and Filter, each a
/// submenu showing what it's on now (as the player's gear menu does). A dot on the button while any
/// filter is on.
struct JellyBrowseMenu: View {
    @Binding var options: JellyBrowseOptions
    /// Posters, Landscape or Canvas.
    var layout: Binding<JellyGridLayout>? = nil
    /// Library, Folder, Genres or Studios (a library or folder only).
    var content: Binding<JellyBrowse>? = nil
    /// The genres to filter by; nil where genre, decade and quality filters don't apply.
    var genres: [String]? = nil

    var body: some View {
        Menu {
            if let content {
                Picker(selection: content) {
                    ForEach(JellyBrowse.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                } label: { Label("Content", systemImage: "square.stack.3d.up") }.pickerStyle(.menu)
            }
            if let layout {
                Picker(selection: layout) {
                    ForEach(JellyGridLayout.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                } label: { Label("View", systemImage: "rectangle.grid.2x2") }.pickerStyle(.menu)
            }
            if content?.wrappedValue.listsTitles ?? true {
                sortMenu
                filterMenu
            }
        } label: {
            TitleMoreButtonLabel()
                .overlay(alignment: .topTrailing) {
                    if options.filtering {
                        Circle().fill(ThemeStore.accent).frame(width: 9, height: 9).offset(x: 6, y: -6).accessibilityHidden(true)
                    }
                }
        }
        .accessibilityLabel(options.filtering ? "Sort and filter, filters on" : "Sort and filter")
        .accessibilityIdentifier("jellyspace-sort")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $options.sort) {
                ForEach(JellyfinClient.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.inline)
            if options.sort != .random {
                let labels = options.sort.orderLabels
                Picker("Order", selection: Binding(get: { options.isAscending }, set: { options.ascending = $0 })) {
                    Label(labels.ascending, systemImage: "arrow.up").tag(true)
                    Label(labels.descending, systemImage: "arrow.down").tag(false)
                }.pickerStyle(.inline)
            }
        } label: {
            Label { Text("Sort by"); Text(options.sort.rawValue) } icon: { Image(systemName: "arrow.up.arrow.down") }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $options.show) {
                ForEach(JellyBrowseOptions.Show.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.inline)
            if let genres {
                if !genres.isEmpty {
                    Menu {
                        ForEach(genres, id: \.self) { name in
                            Toggle(name, isOn: Binding(get: { options.genres.contains(name) }, set: { on in
                                if on { options.genres.append(name) } else { options.genres.removeAll { $0 == name } }
                            }))
                        }
                    } label: {
                        Label { Text("Genres"); Text(options.genres.isEmpty ? "Any" : options.genres.joined(separator: ", ")) } icon: { Image(systemName: "theatermasks") }
                    }
                }
                Picker(selection: $options.decade) {
                    Text("Any").tag(Int?.none)
                    ForEach(JellyBrowseOptions.decades, id: \.self) { Text("\($0)s").tag(Int?.some($0)) }
                } label: { Label("Decade", systemImage: "calendar") }.pickerStyle(.menu)
                Picker(selection: $options.quality) {
                    ForEach(JellyBrowseOptions.Quality.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { Label("Quality", systemImage: "4k.tv") }.pickerStyle(.menu)
            }
            if options.filtering {
                Divider()
                Button(role: .destructive) {
                    options.show = .all; options.genres = []; options.decade = nil; options.quality = .any
                } label: { Label("Clear filters", systemImage: "xmark.circle") }
            }
        } label: {
            Label { Text("Filter"); Text(options.filterSummary) } icon: {
                Image(systemName: options.filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
        }
    }
}

// MARK: Genres and Studios as tiles

/// A genre or studio as a tile: its picture when Jellyfin has one, else a colour of its own, with
/// the name over it.
struct JellyNameTile: View {
    let item: JellyfinClient.Item
    let client: JellyfinClient
    private static let palette: [Color] = [
        Color(red: 0.42, green: 0.25, blue: 0.62), Color(red: 0.16, green: 0.38, blue: 0.62), Color(red: 0.62, green: 0.25, blue: 0.33),
        Color(red: 0.18, green: 0.48, blue: 0.40), Color(red: 0.62, green: 0.42, blue: 0.16), Color(red: 0.30, green: 0.32, blue: 0.62),
        Color(red: 0.52, green: 0.20, blue: 0.52), Color(red: 0.20, green: 0.45, blue: 0.55)
    ]
    var body: some View {
        let name = item.Name ?? ""
        // The same colour for the same name every time (a sum of its letters, not Swift's hash,
        // which changes from launch to launch).
        let colour = Self.palette[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.palette.count]
        let picture = (item.ImageTags?["Thumb"].map { ("Thumb", $0) } ?? item.ImageTags?["Primary"].map { ("Primary", $0) })
            .flatMap { JellyfinClient.imageURL(base: client.base, item: item.Id, type: $0.0, tag: $0.1, width: 600) }
        return Color.clear.aspectRatio(16 / 9, contentMode: .fit)
            .background(LinearGradient(colors: [colour, colour.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay { if let picture { JellyImage(url: picture) } }
            .overlay {
                if picture != nil {
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(name).font(.app(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.35), radius: 4).padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
            .accessibilityElement().accessibilityLabel(name)
    }
}

extension JellyfinClient {
    /// The studios and networks in one library (each a studio item: its name, id, and a logo when
    /// the server has one).
    func studios(in library: String, user: String?) async throws -> [Item] {
        var query = [URLQueryItem(name: "ParentId", value: library), URLQueryItem(name: "SortBy", value: "SortName"),
                     URLQueryItem(name: "Recursive", value: "true")]
        if let user { query.append(URLQueryItem(name: "userId", value: user)) }
        let page: Page = try await get("Studios", query)
        return page.Items
    }
}
