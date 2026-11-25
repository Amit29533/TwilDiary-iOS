import SwiftUI
import TwilDiaryCore

// Your own lists (owner's request, 2026-11-19): your Trakt lists, made, renamed, filled and
// ordered from TwilDiary. They live on Trakt (owner's choice, Trakt's plan limits are fine), so
// trakt.tv and other Trakt apps see the same lists.

// MARK: Data

/// One of your Trakt lists.
struct YourList: Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var description: String
    var privacy: String
    var itemCount: Int
    var slug: String?
    /// Trakt's own link to the list (for a list others may see).
    var shareLink: String?
}

/// A title on one of your lists: Trakt's list item (its id is what reordering names) and the title.
struct YourListEntry: Identifiable, Hashable, Sendable {
    let id: Int
    let rank: Int
    let listedAt: String?
    let item: CatalogItem
}

struct YourListsRoute: Hashable {}
struct YourListRoute: Hashable { let id: Int; let name: String }

/// Your Trakt lists and their titles, read when needed and kept for the session.
@MainActor @Observable final class YourListsStore {
    static let shared = YourListsStore()
    private(set) var lists: [YourList] = []
    private(set) var entries: [Int: [YourListEntry]] = [:]
    private(set) var loaded = false
    private(set) var loading = false
    /// Your Trakt username (for a public list's link).
    private(set) var username: String?
    var failure: String?
    /// Lists whose titles are being changed (a tick waits while it goes).
    private(set) var busy: Set<String> = []

    // MARK: Reading

    func load(store: DiaryStore, force: Bool = false) async {
        guard force || !loaded, !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let client = try await TraktDirectStore.shared.client(store: store)
            username = client.token.username
            let data = try await client.get("/users/me/lists").data
            let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            lists = rows.compactMap { Self.list($0) }
            loaded = true
        } catch { failure = FriendlyError.message(error) }
    }

    /// A list's titles, in your order.
    func loadEntries(_ id: Int, store: DiaryStore, force: Bool = false) async {
        guard force || entries[id] == nil else { return }
        do {
            let client = try await TraktDirectStore.shared.client(store: store)
            let data = try await client.get("/users/me/lists/\(id)/items", query: ["extended": "full,images"]).data
            let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            let found = rows.compactMap { Self.entry($0, store: store) }.sorted { $0.rank < $1.rank }
            entries[id] = found
            if let index = lists.firstIndex(where: { $0.id == id }) { lists[index].itemCount = found.count }
        } catch { failure = FriendlyError.message(error) }
    }

    /// Every list's titles (for the Add to list ticks): your lists are few, read one after another.
    func loadAllEntries(store: DiaryStore) async {
        await load(store: store)
        for list in lists where entries[list.id] == nil { await loadEntries(list.id, store: store) }
    }

    func contains(_ list: Int, _ key: String) -> Bool { entries[list]?.contains { $0.item.key == key } ?? false }

    // MARK: Changing (each straight to Trakt; the page shows what Trakt answered)

    @discardableResult func create(name: String, description: String, privacy: String, store: DiaryStore) async -> YourList? {
        let body: [String: Any] = ["name": name, "description": description, "privacy": privacy,
                                   "display_numbers": false, "allow_comments": false, "sort_by": "rank", "sort_how": "asc"]
        do {
            let client = try await TraktDirectStore.shared.client(store: store)
            let reply = try await client.post("/users/me/lists", body: JSONSerialization.data(withJSONObject: body))
            guard let row = try JSONSerialization.jsonObject(with: reply) as? [String: Any], let list = Self.list(row) else { return nil }
            lists.append(list); entries[list.id] = []
            Haptics.play(.success)
            return list
        } catch { failure = Self.message(error); return nil }
    }

    func update(_ list: YourList, name: String, description: String, privacy: String, store: DiaryStore) async {
        let body: [String: Any] = ["name": name, "description": description, "privacy": privacy]
        do {
            let client = try await TraktDirectStore.shared.client(store: store)
            let reply = try await client.send("PUT", "/users/me/lists/\(list.id)", body: JSONSerialization.data(withJSONObject: body))
            if let row = try? JSONSerialization.jsonObject(with: reply) as? [String: Any], var updated = Self.list(row),
               let index = lists.firstIndex(where: { $0.id == list.id }) {
                updated.itemCount = lists[index].itemCount
                lists[index] = updated
            }
        } catch { failure = Self.message(error) }
    }

    func delete(_ list: YourList, store: DiaryStore) async -> Bool {
        do {
            let client = try await TraktDirectStore.shared.client(store: store)
            _ = try await client.send("DELETE", "/users/me/lists/\(list.id)")
            lists.removeAll { $0.id == list.id }; entries[list.id] = nil
            Haptics.play(.warning)
            return true
        } catch { failure = Self.message(error); return false }
    }

    /// Adds the title to the list, or takes it off.
    func set(_ item: CatalogItem, in list: YourList, on: Bool, store: DiaryStore) async {
        let token = "\(list.id)|\(item.key)"
        guard busy.insert(token).inserted else { return }
        defer { busy.remove(token) }
        let slot = item.mediaType == .movie ? "movies" : "shows"
        let body: [String: Any] = [slot: [["ids": ["tmdb": item.id]]]]
        do {
            let client = try await TraktDirectStore.shared.client(store: store)
            _ = try await client.post("/users/me/lists/\(list.id)/items" + (on ? "" : "/remove"), body: JSONSerialization.data(withJSONObject: body))
            Haptics.play(on ? .success : .light)
            await loadEntries(list.id, store: store, force: true)
        } catch { failure = Self.message(error) }
    }

    /// Your order: the list's items, by their Trakt list-item ids, first to last.
    func reorder(_ list: YourList, to ordered: [YourListEntry], store: DiaryStore) async {
        entries[list.id] = ordered.enumerated().map { YourListEntry(id: $0.element.id, rank: $0.offset + 1, listedAt: $0.element.listedAt, item: $0.element.item) }
        Haptics.play(.soft)
        do {
            let client = try await TraktDirectStore.shared.client(store: store)
            _ = try await client.post("/users/me/lists/\(list.id)/items/reorder", body: JSONSerialization.data(withJSONObject: ["rank": ordered.map(\.id)]))
        } catch {
            failure = Self.message(error)
            await loadEntries(list.id, store: store, force: true)
        }
    }

    func forget() { lists = []; entries = [:]; loaded = false }

    // MARK: Trakt's shapes

    nonisolated static func list(_ row: [String: Any]) -> YourList? {
        guard let ids = row["ids"] as? [String: Any], let id = ids["trakt"] as? Int, let name = row["name"] as? String else { return nil }
        return YourList(id: id, name: name, description: row["description"] as? String ?? "", privacy: row["privacy"] as? String ?? "private",
                        itemCount: row["item_count"] as? Int ?? 0, slug: ids["slug"] as? String, shareLink: row["share_link"] as? String)
    }
    private static func entry(_ row: [String: Any], store: DiaryStore) -> YourListEntry? {
        guard let id = row["id"] as? Int, let type = row["type"] as? String, type == "movie" || type == "show",
              let media = row[type] as? [String: Any], let ids = media["ids"] as? [String: Any], let tmdb = ids["tmdb"] as? Int, tmdb > 0 else { return nil }
        let kind: MediaKind = type == "movie" ? .movie : .tv
        let key = (kind == .movie ? "movie:" : "tv:") + String(tmdb)
        func image(_ name: String) -> String? {
            ((media["images"] as? [String: Any])?[name] as? [String])?.first.map { $0.hasPrefix("http") ? $0 : "https://" + $0 }
        }
        // The poster: your library's or the phone's catalog (TMDB), else Trakt's own.
        let known = store.libraryIdentity(CatalogItem(id: tmdb, mediaType: kind, name: "")).flatMap { store.title($0) } ?? PhoneCatalog.shared.title(forKey: key)
        let rating = (media["rating"] as? NSNumber).map { $0.doubleValue }.flatMap { $0 > 0 ? (($0 * 10).rounded() / 10) : nil }
        let item = CatalogItem(id: tmdb, mediaType: kind, name: media["title"] as? String ?? known?.name ?? "", year: media["year"] as? Int ?? known?.year,
                               overview: media["overview"] as? String ?? "", rating: known?.communityScore ?? rating,
                               inLibraryId: store.libraryIdentity(CatalogItem(id: tmdb, mediaType: kind, name: "")),
                               poster: known?.poster ?? image("poster"), backdrop: known?.backdrop ?? image("fanart"))
        return YourListEntry(id: id, rank: row["rank"] as? Int ?? Int.max, listedAt: row["listed_at"] as? String, item: item)
    }
    private static func message(_ error: Error) -> String {
        (error as? TraktWriteError)?.message ?? FriendlyError.message(error)
    }
}

// MARK: Your lists

/// Profile → Lists: your Trakt lists, a card each, and New list.
struct YourListsView: View {
    @Environment(DiaryStore.self) private var store
    @State private var creating = false
    private var model: YourListsStore { .shared }
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ExploreBrowsePage(title: "Your lists", symbol: "list.bullet.rectangle", subtitle: "On Trakt · " + model.lists.count.counted("list", "lists"),
                          artwork: model.lists.lazy.compactMap { model.entries[$0.id]?.first?.item.backdrop ?? model.entries[$0.id]?.first?.item.artwork }.first,
                          titleIdentifier: "your-lists-title",
                          accessory: AnyView(Button { creating = true } label: { HomeRoundIcon(system: "plus") }.buttonStyle(.plain)
                            .accessibilityLabel("New list").accessibilityIdentifier("your-lists-new"))) {
            VStack(alignment: .leading, spacing: 14) {
                // Lists you saved from anywhere (their bookmark), then yours on Trakt.
                SavedListsSection()
                if model.lists.isEmpty {
                    // A first load that failed shows Retry (it stayed "not loaded", so the placeholder hid it).
                    if !model.loading, let failure = model.failure { RetryNotice(message: failure) { Task { await model.load(store: store, force: true) } } }
                    else if model.loading || !model.loaded { DiaryLoadingPlaceholder(label: "Loading your lists", layout: .posterGrid(columns: 2, rows: 2)) }
                    else {
                        DiaryEmptyState(title: "No lists yet", description: "Make one for anything: a weekend marathon, comfort shows, films to watch with friends.")
                        Button("New list", systemImage: "plus") { creating = true }.buttonStyle(.diaryPrimary)
                    }
                } else {
                    LazyVGrid(columns: columns, spacing: Gap.tileRow) {
                        ForEach(model.lists) { list in
                            NavigationLink(value: YourListRoute(id: list.id, name: list.name)) { YourListCard(list: list) }
                                .buttonStyle(.springPress).accessibilityIdentifier("your-list-\(list.id)")
                        }
                    }
                    if let failure = model.failure { Text(failure).font(.footnote).foregroundStyle(.secondary) }
                }
            }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 40)
        }
        .task { await model.loadAllEntries(store: store) }
        .refreshable { model.forget(); await model.loadAllEntries(store: store) }
        .sheet(isPresented: $creating) { YourListEditor(list: nil) }
    }
}

/// A list as a card: a collage of its first posters, its name and how many titles.
struct YourListCard: View {
    let list: YourList
    private var model: YourListsStore { .shared }
    var body: some View {
        let posters = (model.entries[list.id] ?? []).prefix(3).map(\.item.artwork)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    HomeStyle.card
                    if posters.isEmpty {
                        Image(systemName: "list.bullet.rectangle").font(.app(size: 30, weight: .light)).foregroundStyle(HomeStyle.chipText.opacity(0.6))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    ForEach(Array(posters.enumerated().reversed()), id: \.offset) { index, poster in
                        Artwork(path: poster, title: list.name, initialsOnly: false)
                            .frame(width: width * 0.48, height: width * 0.72)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.35), radius: 4, x: 2)
                            .offset(x: 10 + CGFloat(index) * width * 0.22)
                    }
                }
            }
            .aspectRatio(1.15, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
            Text(list.name).font(.app(size: 16, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
            Text([list.itemCount.counted("title", "titles"), list.privacy.capitalized].joined(separator: " · "))
                .font(.app(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
        }.accessibilityElement(children: .combine)
    }
}

// MARK: One list

struct YourListPage: View {
    let route: YourListRoute
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var reordering = false
    @State private var confirmDelete = false
    /// rank (your order), added, name, year or rating; per list.
    @AppStorage("yourLists.sort") private var sortsJSON = "{}"
    private var model: YourListsStore { .shared }
    @PosterSizing private var posterSize
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: posterSize.columns) }

    private var list: YourList? { model.lists.first { $0.id == route.id } }
    private var sort: String {
        get { ((try? JSONDecoder().decode([String: String].self, from: Data(sortsJSON.utf8))) ?? [:])[String(route.id)] ?? "rank" }
    }
    private func setSort(_ value: String) {
        var all = (try? JSONDecoder().decode([String: String].self, from: Data(sortsJSON.utf8))) ?? [:]
        all[String(route.id)] = value
        if let data = try? JSONEncoder().encode(all), let text = String(data: data, encoding: .utf8) { sortsJSON = text }
    }
    private var sorted: [YourListEntry] {
        let entries = model.entries[route.id] ?? []
        switch sort {
        case "added": return entries.sorted { ($0.listedAt ?? "") > ($1.listedAt ?? "") }
        case "name": return entries.sorted { $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending }
        case "year": return entries.sorted { ($0.item.year ?? 0) > ($1.item.year ?? 0) }
        case "rating": return entries.sorted { (PosterScores.score(for: $0.item, store: store) ?? 0) > (PosterScores.score(for: $1.item, store: store) ?? 0) }
        default: return entries
        }
    }

    var body: some View {
        let name = list?.name ?? route.name
        let entries = model.entries[route.id]
        ExploreBrowsePage(title: name, symbol: "list.bullet.rectangle",
                          subtitle: [list.map { $0.itemCount.counted("title", "titles") }, list?.privacy.capitalized, list.flatMap { $0.description.isEmpty ? nil : $0.description }].compactMap { $0 }.joined(separator: " · "),
                          artwork: entries?.first.flatMap { $0.item.backdrop ?? $0.item.artwork },
                          titleIdentifier: "your-list-title", accessory: AnyView(menu)) {
            VStack(alignment: .leading, spacing: 14) {
                if let entries {
                    if entries.isEmpty {
                        DiaryEmptyState(title: "Nothing on this list yet", description: "Add titles from their page: ••• → Add to list.")
                    } else if reordering {
                        reorderList(entries)
                    } else {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(sorted) { entry in
                                tile(entry).contextMenu {
                                    if let list { Button("Remove from list", systemImage: "minus.circle", role: .destructive) { Task { await model.set(entry.item, in: list, on: false, store: store) } } }
                                }
                            }
                        }
                    }
                } else if let failure = model.failure {
                    RetryNotice(message: failure) { Task { await model.loadEntries(route.id, store: store, force: true) } }
                } else {
                    DiaryLoadingPlaceholder(label: "Loading titles", layout: .posterGrid(columns: 3, rows: 2))
                }
            }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 40)
        }
        .task {
            await model.load(store: store)
            await model.loadEntries(route.id, store: store)
        }
        .refreshable { await model.loadEntries(route.id, store: store, force: true) }
        .sheet(isPresented: $editing) { if let list { YourListEditor(list: list) } }
        .confirmationDialog("Delete “\(name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete list", role: .destructive) { Task { if let list, await model.delete(list, store: store) { dismiss() } } }
        } message: { Text("The list comes off Trakt too. The titles stay in your library.") }
    }

    private var menu: some View {
        Menu {
            if reordering {
                Button("Done reordering", systemImage: "checkmark") { reordering = false }
            } else {
                Picker("Sort", selection: Binding(get: { sort }, set: { value in setSort(value) })) {
                    Text("Your order").tag("rank"); Text("Recently added").tag("added"); Text("Name").tag("name"); Text("Year").tag("year"); Text("Rating").tag("rating")
                }
                Button("Reorder", systemImage: "arrow.up.arrow.down") { setSort("rank"); reordering = true }
                    .disabled((model.entries[route.id]?.count ?? 0) < 2)
                Button("Edit list", systemImage: "pencil") { editing = true }
                ShareLink(item: shareText) { Label("Share", systemImage: "square.and.arrow.up") }
                Divider()
                Button("Delete list", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        } label: { HomeRoundIcon(system: reordering ? "checkmark" : "ellipsis") }
            .accessibilityLabel("List options").accessibilityIdentifier("your-list-menu")
    }

    private var shareText: String {
        let lines = sorted.enumerated().map { "\($0.offset + 1). \($0.element.item.name)" + ($0.element.item.year.map { " (\($0))" } ?? "") }
        var text = ([list?.name ?? route.name] + (list?.description.isEmpty == false ? [list!.description] : []) + [""] + lines).joined(separator: "\n")
        if let list, list.privacy != "private" {
            if let link = list.shareLink { text += "\n\n" + link }
            else if let slug = list.slug, let user = model.username { text += "\n\nhttps://trakt.tv/users/\(user)/lists/\(slug)" }
        }
        return text
    }

    private func tile(_ entry: YourListEntry) -> some View {
        Group {
            if let id = entry.item.inLibraryId ?? store.libraryIdentity(entry.item) { NavigationLink(value: id) { CatalogPoster(item: entry.item) } }
            else { NavigationLink(value: entry.item.route) { CatalogPoster(item: entry.item) } }
        }.buttonStyle(.springPress).accessibilityIdentifier("your-list-item-\(entry.item.key)")
    }

    /// Drag titles into your order; it's saved on Trakt as you drop each one.
    private func reorderList(_ entries: [YourListEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drag the handles to reorder.").font(.footnote).foregroundStyle(.secondary)
            List {
                ForEach(entries) { entry in
                    HStack(spacing: 12) {
                        Artwork(path: entry.item.artwork, title: entry.item.name, initialsOnly: false).frame(width: posterSize.small, height: posterSize.smallHeight).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.item.name).font(.app(size: 15, weight: .semibold)).lineLimit(1)
                            if let year = entry.item.year { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.listRowBackground(HomeStyle.card)
                }
                .onMove { from, to in
                    guard let list else { return }
                    var moved = entries; moved.move(fromOffsets: from, toOffset: to)
                    Task { await model.reorder(list, to: moved, store: store) }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).environment(\.editMode, .constant(.active))
            .frame(height: CGFloat(entries.count) * 76 + 10)
            .scrollDisabled(true)
        }
    }
}

// MARK: Make or edit a list

struct YourListEditor: View {
    let list: YourList?
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""
    @State private var privacy = "private"
    @State private var saving = false
    /// Called with the new list (Add to list adds the title to it straight away).
    var onCreated: (YourList) -> Void = { _ in }
    private var model: YourListsStore { .shared }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Weekend marathon", text: $name).accessibilityIdentifier("your-list-name")
                }
                Section("Note") {
                    TextField("What it's for (optional)", text: $note, axis: .vertical).lineLimit(1...4)
                }
                Section {
                    Picker("Who can see it on Trakt", selection: $privacy) {
                        Text("Only me").tag("private"); Text("Friends").tag("friends"); Text("Everyone").tag("public")
                    }
                } footer: { Text("Saved to your Trakt account, so trakt.tv and other Trakt apps show it too.") }
                if let failure = model.failure, !saving { Section { Text(failure).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle(list == nil ? "New list" : "Edit list").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(list == nil ? "Create" : "Save") { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("your-list-save")
                }
            }
            .onAppear {
                model.failure = nil
                if let list { name = list.name; note = list.description; privacy = list.privacy }
            }
        }.presentationDetents([.medium, .large])
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let list {
            await model.update(list, name: trimmed, description: note, privacy: privacy, store: store)
            if model.failure == nil { dismiss() }
        } else if let created = await model.create(name: trimmed, description: note, privacy: privacy, store: store) {
            onCreated(created)
            dismiss()
        }
    }
}

// MARK: Add to list

/// ••• → Add to list: your lists with a tick on each the title is in; tap to add or take it off.
struct AddToListSheet: View {
    let item: CatalogItem
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    private var model: YourListsStore { .shared }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { creating = true } label: { Label("New list", systemImage: "plus") }.accessibilityIdentifier("add-to-list-new")
                }
                Section {
                    if model.lists.isEmpty && !model.loading && !model.loaded && model.failure != nil {
                        Button("Retry") { Task { model.failure = nil; await model.loadAllEntries(store: store) } }
                            .accessibilityIdentifier("add-to-list-retry")
                    } else if model.lists.isEmpty && (model.loading || !model.loaded) {
                        DiaryLoadingPlaceholder(label: "Loading your lists", layout: .list(rows: 3))
                    }
                    ForEach(model.lists) { list in
                        let on = model.contains(list.id, item.key)
                        let waiting = model.busy.contains("\(list.id)|\(item.key)") || model.entries[list.id] == nil
                        Button { Task { await model.set(item, in: list, on: !on, store: store) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(list.name).foregroundStyle(.primary)
                                    Text(list.itemCount.counted("title", "titles")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if waiting { ProgressView() }
                                else { Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(on ? Color.accentColor : .secondary) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(waiting)
                            .accessibilityAddTraits(on ? .isSelected : []).accessibilityIdentifier("add-to-list-\(list.id)")
                    }
                } footer: { if let failure = model.failure { Text(failure).foregroundStyle(.red) } else { Text("Your Trakt lists.") } }
            }
            .navigationTitle("Add “\(item.name)”").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { model.failure = nil; await model.loadAllEntries(store: store) }
            .sheet(isPresented: $creating) {
                YourListEditor(list: nil) { created in Task { await model.set(item, in: created, on: true, store: store) } }
            }
        }.presentationDetents([.medium, .large])
    }
}
