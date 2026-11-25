import SwiftUI
import TwilDiaryCore

/// A list you saved from wherever it was (its bookmark button): a Trakt list, a TMDb collection,
/// a TheTVDB franchise or list, an awards ceremony, or a Jellyfin list. Enough of it is kept to open
/// it again. Shown in Lists (Library's Lists chip, and Profile → Lists), kept on this iPhone and in the
/// settings backup.
struct SavedList: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case trakt, tmdbCollection, tvdb, ceremony, jellyfin }
    let kind: Kind
    /// Unique within its kind (the list's own id).
    let key: String
    let name: String
    var detail: String?
    var image: String?
    var savedAt = Date.now
    // What reopens it.
    var traktID: Int?
    var traktUser: String?
    var tmdbID: Int?
    var tvdb: TVDBDirect.Franchise?
    var ceremony: SearchAwardCeremony?
    var jellyKind: String?
    var jellyID: String?
    var jellyLibrary: String?
    var id: String { kind.rawValue + ":" + key }

    static func trakt(_ route: CanvasListRoute, image: String?) -> SavedList {
        SavedList(kind: .trakt, key: String(route.id), name: route.name, detail: "by " + route.user, image: image, traktID: route.id, traktUser: route.user)
    }
    static func tmdbCollection(id: Int, name: String, image: String?) -> SavedList {
        SavedList(kind: .tmdbCollection, key: String(id), name: name, detail: "TMDb collection", image: image, tmdbID: id)
    }
    static func tvdb(_ franchise: TVDBDirect.Franchise, detail: String, image: String?) -> SavedList {
        SavedList(kind: .tvdb, key: String(franchise.id), name: franchise.name, detail: detail, image: image, tvdb: franchise)
    }
    static func ceremony(_ ceremony: SearchAwardCeremony) -> SavedList {
        SavedList(kind: .ceremony, key: String(ceremony.id), name: ceremony.displayName, detail: "Awards ceremony", ceremony: ceremony)
    }
    static func jellyfin(_ route: JellyListRoute) -> SavedList {
        SavedList(kind: .jellyfin, key: route.kind.rawValue + "|" + (route.id ?? "") + "|" + (route.library ?? ""), name: route.name,
                  detail: "Jellyfin", jellyKind: route.kind.rawValue, jellyID: route.id, jellyLibrary: route.library)
    }

    /// The symbol shown when there's no picture.
    var symbol: String {
        switch kind {
        case .trakt: "list.bullet.rectangle"
        case .tmdbCollection: "square.stack"
        case .tvdb: "square.stack.3d.up"
        case .ceremony: "trophy"
        case .jellyfin: "server.rack"
        }
    }
}

/// Your saved lists, newest first.
@MainActor @Observable final class SavedLists {
    static let shared = SavedLists()
    nonisolated static let key = "library.savedLists"
    private(set) var all: [SavedList] = SavedLists.load() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: Self.key) }
    }
    nonisolated private static func load() -> [SavedList] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([SavedList].self, from: $0) } ?? []
    }
    /// Read again (a backup's were put back).
    func reload() { all = Self.load() }
    func contains(_ list: SavedList) -> Bool { all.contains { $0.id == list.id } }
    func toggle(_ list: SavedList) {
        if contains(list) { remove(list.id) } else { all.insert(list, at: 0) }
    }
    func remove(_ id: String) { all.removeAll { $0.id == id } }
}

/// A list page's bookmark: saves the list to Lists, or takes it back out.
struct SaveListButton: View {
    let list: SavedList
    /// In a navigation bar (a plain symbol) rather than a page header (a round icon).
    var inBar = false
    private var lists: SavedLists { .shared }
    var body: some View {
        let saved = lists.contains(list)
        Button {
            withAnimation(.snappy(duration: 0.2)) { lists.toggle(list) }
        } label: {
            if inBar { Image(systemName: saved ? "bookmark.fill" : "bookmark") }
            else { HomeRoundIcon(system: saved ? "bookmark.fill" : "bookmark") }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: saved)
        .accessibilityLabel(saved ? "Remove from saved lists" : "Save list")
        .accessibilityIdentifier("save-list")
    }
}

/// Opens a saved list where it came from.
struct SavedListLink<Label: View>: View {
    let list: SavedList
    @ViewBuilder let label: () -> Label
    var body: some View {
        switch list.kind {
        case .trakt:
            if let id = list.traktID { NavigationLink(value: CanvasListRoute(id: id, name: list.name, user: list.traktUser ?? "")) { label() } }
        case .tmdbCollection:
            if let id = list.tmdbID { NavigationLink(value: ShowPageRoute.tmdbCollection(id: id, name: list.name)) { label() } }
        case .tvdb:
            if let franchise = list.tvdb { NavigationLink(value: SearchBrowseRoute.tvdbFranchise(franchise)) { label() } }
        case .ceremony:
            if let ceremony = list.ceremony { NavigationLink(value: SearchBrowseRoute.ceremony(ceremony)) { label() } }
        case .jellyfin:
            if let kind = list.jellyKind.flatMap(JellyListRoute.Kind.init(rawValue:)) {
                NavigationLink(value: JellyListRoute(kind: kind, id: list.jellyID, name: list.name, library: list.jellyLibrary)) { label() }
            }
        }
    }
}

/// Lists' Saved section: each saved list as a row (its picture or symbol, name and where it's from).
/// Long-press to take one out.
struct SavedListsSection: View {
    private var lists: SavedLists { .shared }
    var body: some View {
        if !lists.all.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Saved").font(.app(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary).accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Array(lists.all.enumerated()), id: \.element.id) { index, list in
                        if index > 0 { SettingsDivider() }
                        SavedListLink(list: list) { row(list) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove", systemImage: "bookmark.slash", role: .destructive) {
                                    withAnimation(.snappy(duration: 0.2)) { lists.remove(list.id) }
                                }
                            }
                            .accessibilityIdentifier("saved-list-" + list.id)
                    }
                }.modifier(SettingsCard())
            }
        }
    }
    private func row(_ list: SavedList) -> some View {
        HStack(spacing: 12) {
            Group {
                if let image = list.image {
                    Artwork(path: image, title: list.name)
                } else {
                    Image(systemName: list.symbol).font(.app(size: 18, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(HomeStyle.chip)
                }
            }
            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(list.name).font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                if let detail = list.detail { Text(detail).font(.app(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.app(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
    }
}
