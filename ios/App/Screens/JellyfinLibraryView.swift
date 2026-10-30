import SwiftUI
import TwilDiaryCore

/// "Jellyfin": every movie and show in the Jellyfin libraries Sync now reads, as posters, with
/// filters for the diary (not in it, in it) and for drives, like Files & drives. A title in the
/// diary opens its page; one that isn't opens its TMDB page, where it can be added.
/// The list last read at home is saved (JellyfinShelf), so away from home the page still shows it.
struct JellyfinLibraryView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var sync: JellyfinSync?
    @State private var shelf = JellyfinShelf.shared
    @State private var loaded = false
    @State private var loading = false
    @State private var failure: String?
    @State private var show = Show.all
    @State private var drive: String?
    @State private var query = ""
    enum Show: String, CaseIterable { case all = "All", missing = "Not in diary", saved = "In diary" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if loading && entries.isEmpty { DiaryLoadingPlaceholder(height: 220, label: "Reading Jellyfin") }
                else if let failure, entries.isEmpty { RetryNotice(message: failure) { Task { await load() } } }
                else { content }
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 100)
        }.diaryScreenBackground().navigationTitle("Jellyfin").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            // Once per visit (coming back from a title page doesn't read Jellyfin again).
            .task { if !loaded { loaded = true; await load() } }
            .refreshable { await load() }
    }
    /// The saved list, matched against the diary as it is now.
    private var entries: [JellyfinEntry] { JellyfinShelf.matched(shelf.entries, diary: store.workspace.activeTitles) }
    @ViewBuilder private var content: some View {
        Text(summary)
            .font(.system(size: 13)).foregroundStyle(.secondary).accessibilityIdentifier("jellyfin-library-summary")
        if let failure, let at = shelf.savedAt {
            // Away from home: the saved list stays, and says how old it is.
            Text("Jellyfin can’t be reached, so this is the list from \(at.formatted(.relative(presentation: .named))). It updates when you’re home.")
                .font(.system(size: 12)).foregroundStyle(.secondary).accessibilityIdentifier("jellyfin-library-saved")
                .accessibilityHint(failure)
        }
        chipRow {
            ForEach(Show.allCases, id: \.self) { option in
                chip(option.rawValue + " " + count(option).formatted(), on: show == option, id: "jellyfin-show-" + String(describing: option)) { show = option }
            }
        }
        // Drives, as Files & drives groups them; they combine with the diary filter above.
        chipRow {
            chip("All drives", on: drive == nil, id: "jellyfin-drive-all") { drive = nil }
            ForEach(drives, id: \.self) { item in
                chip(Self.driveLabel(item.name) + " " + item.count.formatted(), on: drive == item.name, id: "jellyfin-drive-" + item.name) { drive = drive == item.name ? nil : item.name }
            }
        }
        SearchField(placeholder: "Find in Jellyfin", text: $query, label: "Search Jellyfin")
        let items = shown
        if items.isEmpty { Text("Nothing here with these filters.").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 8) }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 18) {
            ForEach(items) { entry in JellyfinEntryCard(entry: entry) }
        }
    }
    /// "312 movies and shows · 46 in your diary · 3 personal items left out".
    private var summary: String {
        let list = entries
        var parts = [list.count.counted("movie or show", "movies and shows"), list.filter { $0.diaryID != nil }.count.formatted() + " in your diary"]
        if shelf.personal > 0 { parts.append(shelf.personal.counted("personal item", "personal items") + " left out") }
        return parts.joined(separator: " · ")
    }
    struct DriveCount: Hashable { let name: String; let count: Int }
    /// Drives read as they do in Library and Home ("E: Toshiba (4TB)"); others by letter or path.
    static func driveLabel(_ name: String) -> String {
        HomeDiskShortcut.all.first { $0.key == "drive:" + name }?.label ?? name
    }
    /// Every drive stays listed; its count follows the diary filter, so it matches what shows.
    private var drives: [DriveCount] {
        Set(entries.map(\.drive)).sorted().map { name in
            DriveCount(name: name, count: entries.filter { $0.drive == name && matches($0, show: show, drive: nil) }.count)
        }
    }
    private func count(_ option: Show) -> Int { entries.filter { matches($0, show: option, drive: drive) }.count }
    private func matches(_ entry: JellyfinEntry, show option: Show, drive: String?) -> Bool {
        (drive == nil || entry.drive == drive)
            && (option == .all || (option == .saved) == (entry.diaryID != nil))
    }
    private var shown: [JellyfinEntry] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return entries.filter { matches($0, show: show, drive: drive) && (text.isEmpty || $0.name.localizedCaseInsensitiveContains(text)) }
    }
    private func chipRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal) { HStack(spacing: 8) { content() } }.scrollIndicators(.hidden)
    }
    private func chip(_ text: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(on ? theme.accent : Color(webHex: "#c5c0cf"))
                .padding(.horizontal, 12).frame(height: 32).background(on ? theme.accent.opacity(0.12) : .white.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(on ? theme.accent.opacity(0.5) : .white.opacity(0.12)))
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : []).accessibilityIdentifier(id)
    }
    private func load() async {
        if sync == nil { sync = JellyfinSync(store: store) }
        guard let sync else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let found = try await sync.browse()
            shelf.replace(found.entries, personal: found.personal, save: !store.isPreview)
            if let drive, !shelf.entries.contains(where: { $0.drive == drive }) { self.drive = nil }
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

/// A Jellyfin title as a poster card (the Jellyfin page, and Library's Jellyfin chip): a title in
/// the diary opens its page, one that isn't opens its TMDB page, where it can be added.
struct JellyfinEntryCard: View {
    let entry: JellyfinEntry
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        let label = VStack(alignment: .leading, spacing: 6) {
            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { poster(entry) }
                .clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)))
                .overlay(alignment: .topLeading) {
                    if entry.diaryID != nil {
                        Text("In diary").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).frame(height: 18).background(theme.accent, in: Capsule()).padding(6)
                    }
                }
            Text(entry.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).foregroundStyle(.primary)
            Text([entry.year.map(String.init), entry.movie ? "Movie" : "Show"].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.multilineTextAlignment(.leading).accessibilityElement(children: .combine)
        if let id = entry.diaryID {
            NavigationLink(value: id) { label }.buttonStyle(.springPress).accessibilityIdentifier("jellyfin-item-" + entry.id)
        } else if let tmdb = entry.tmdb {
            NavigationLink(value: CatalogRoute(kind: entry.movie ? .movie : .tv, id: tmdb)) { label }.buttonStyle(.springPress).accessibilityIdentifier("jellyfin-item-" + entry.id)
        } else {
            label.accessibilityIdentifier("jellyfin-item-" + entry.id)
        }
    }
    /// Jellyfin's own poster (saved on this iPhone); the diary's while it loads or when there is none.
    @ViewBuilder private func poster(_ entry: JellyfinEntry) -> some View {
        let fallback = Artwork(path: entry.diaryID.flatMap { store.title($0)?.poster }, title: entry.name)
        if let url = entry.poster { JellyfinPoster(url: url) { fallback } } else { fallback }
    }
}

/// A Jellyfin poster from JellyfinPosterCache: shown at once when it's in memory, otherwise the
/// fallback until the saved (or, at home, downloaded) copy arrives.
struct JellyfinPoster<Fallback: View>: View {
    let url: URL
    @ViewBuilder let fallback: () -> Fallback
    @State private var image: UIImage?
    var body: some View {
        if let image = image ?? JellyfinPosterCache.shared.resident(url) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            fallback().task(id: url) { image = await JellyfinPosterCache.shared.image(url) }
        }
    }
}
