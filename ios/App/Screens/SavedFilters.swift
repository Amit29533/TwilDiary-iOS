import Foundation
import Observation
import SwiftUI
import TwilDiaryCore

/// A Library filter saved under a name ("Anime · Watching · Rated 8+"): a shelf on Home, one tap
/// from the titles it finds. Kept on this iPhone.
struct SavedFilter: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var name: String
    /// LibraryCategory's raw value ("All", "Movies", "Shows", "Anime").
    var category: String
    var status: String
    var genres: [String]
    var tag: String
    var drive: String
    var favorites: Bool
    var minScore: Int?
    var sort: String

    /// Its Library query (the same one the Library runs).
    @MainActor func query(store: DiaryStore) -> LibraryQuery {
        var query = LibraryQuery()
        let picked = LibraryCategory(rawValue: category) ?? .all
        query.category = picked == .movies ? "movie" : picked == .shows ? "show" : picked == .anime ? "anime" : "all"
        query.tag = tag
        query.status = ["queue", "jellyfin"].contains(status) ? "all" : status
        query.queued = status == "queue"
        query.genres = Set(genres)
        query.favorites = favorites
        query.jellyfin = status == "jellyfin"
        query.jellyfinTitles = status == "jellyfin" ? JellyfinShelf.shared.titleIDs(diary: store.activeTitles) : []
        query.disk = Self.diskKey(drive)
        query.minScore = minScore.flatMap { $0 > 0 ? Double($0) : nil }
        query.sort = LibraryQuery.Sort(rawValue: sort) ?? .added
        query.ignoreArticles = UserDefaults.standard.bool(forKey: "ignoreTitleArticles")
        return query
    }
    /// The Library's drive key: "mapped", "unmapped", a Jellyfin set, or "drive:E:".
    static func diskKey(_ drive: String) -> String {
        drive.isEmpty ? "all" : ["mapped", "unmapped"].contains(drive) || drive.hasPrefix("[") || drive.hasPrefix("drive:") ? drive : "drive:" + drive.uppercased()
    }
}

/// Your saved filters, in the order you saved them.
@MainActor @Observable final class SavedFilters {
    static let shared = SavedFilters()
    nonisolated private static let key = "library.savedFilters"
    private(set) var all: [SavedFilter] = SavedFilters.load() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: Self.key) }
    }
    nonisolated private static func load() -> [SavedFilter] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([SavedFilter].self, from: $0) } ?? []
    }
    func add(_ filter: SavedFilter) { all.append(filter) }
    func rename(_ id: String, to name: String) {
        let kept = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kept.isEmpty, let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].name = kept
    }
    func remove(_ id: String) { all.removeAll { $0.id == id } }
}

/// Home: one shelf per saved filter. › opens the Library with that filter; ••• renames or removes it.
struct HomeSavedShelves: View {
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    private let saved = SavedFilters.shared
    @State private var renaming: SavedFilter?
    @State private var newName = ""
    /// Each shelf's titles, worked out in the background when the diary or the shelves change.
    @State private var found: [String: [MediaTitle]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            ForEach(saved.all) { filter in shelf(filter) }
        }
        .task(id: "\(store.homeWorkspaceRevision)|" + saved.all.map { "\($0.id)\($0.name)\($0.minScore ?? 0)" }.joined(separator: ",")) { await load() }
        .alert("Rename shelf", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let renaming { saved.rename(renaming.id, to: newName) } }
            Button("Cancel", role: .cancel) { }
        }
    }

    private func load() async {
        let snapshot = store.workspace
        let queries = saved.all.map { ($0.id, $0.query(store: store)) }
        let result = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: queries.map { id, query in (id, Array(query.titles(in: snapshot).prefix(12))) })
        }.value
        guard !Task.isCancelled else { return }
        found = result
    }
    private func shelf(_ filter: SavedFilter) -> some View {
        let titles = found[filter.id] ?? []
        return VStack(alignment: .leading, spacing: 16) {
            HomeSectionHeader(title: filter.name) {
                Menu {
                    Button("Rename", systemImage: "pencil") { newName = filter.name; renaming = filter }
                    Button("Remove from Home", systemImage: "trash", role: .destructive) { withAnimation(.snappy) { saved.remove(filter.id) } }
                } label: { HomeRoundIcon(system: "ellipsis") }
                    .accessibilityLabel("Shelf options").accessibilityIdentifier("saved-shelf-menu-" + filter.id)
                Button { router.librarySaved(filter) } label: { HomeRoundIcon() }.buttonStyle(.plain)
                    .accessibilityLabel("Open in Library").accessibilityIdentifier("saved-shelf-open-" + filter.id)
            }
            if titles.isEmpty && found[filter.id] == nil {
                Color.clear.frame(height: 190)
            } else if titles.isEmpty {
                Text("Nothing matches this shelf right now.").font(.system(size: 14)).foregroundStyle(HomeStyle.secondary)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(titles.prefix(12)) { title in
                            NavigationLink(value: title.id) {
                                HomePoster(artwork: title.poster, name: title.name, subtitle: subtitle(title))
                            }.buttonStyle(.springPress).accessibilityIdentifier("saved-shelf-title-" + title.id).shelfTransition()
                        }
                    }.scrollTargetLayout()
                }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden).scrollClipDisabled()
            }
        }.accessibilityIdentifier("saved-shelf-" + filter.id)
    }

    /// "Rated 9", or the kind and year.
    private func subtitle(_ title: MediaTitle) -> String {
        if let score = title.score { return "Rated \(Int(score.rounded()))" }
        return ([title.isSeries ? title.categoryName : "Movie"] + [title.year.map(String.init)].compactMap { $0 }).joined(separator: " · ")
    }
}
