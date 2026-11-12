import Foundation
import Observation
import TwilDiaryCore

/// With no TwilDiary server (Trakt-only, On this phone, or a phone-only Simkl/MDBList/WeTrakr
/// diary): what the service can't keep, kept on this iPhone instead of the server's record of
/// each title. Tags, Queue, a note's full text (Trakt keeps 500 characters), the statuses the
/// service has no place for (Completed, Paused, a dropped movie), a favourite where the service has
/// no favourites, and the folders Jellyfin holds. They're in the Drive and Files backups too, and
/// with Google Drive connected they sync through a small file in its app folder (with favourite
/// people and the phone's Trash): each change is saved there, and what another iPhone (or a
/// reinstall) saved comes back when the app opens, the newer change winning. Every save reads
/// Drive's copy first, so a freshly installed, empty app never overwrites it.
@MainActor @Observable final class PhoneExtras {
    static let shared = PhoneExtras()

    struct Entry: Codable, Equatable, Sendable {
        var tags: [String]?
        var queued: Bool?
        var notes: String?
        var status: String?
        var favorite: Bool?
        /// When it last changed (a cleared entry stays, empty, so the clearing syncs too).
        var at: Date?
        var isEmpty: Bool { (tags ?? []).isEmpty && queued != true && (notes ?? "").isEmpty && status == nil && favorite == nil }
    }
    /// What a backup carries for the phone: these, favourite people and the phone's Trash.
    struct Backup: Codable, Sendable {
        var entries: [String: Entry]
        var locations: [FileLocation]
        var favourites: [Favourite]?
        var trash: [MediaTitle]?
    }
    private struct Saved: Codable {
        var entries: [String: Entry]
        var locations: [FileLocation]
        /// When each whole list last changed here (for Drive sync).
        var changed: [String: Date]?
    }
    /// The file on Google Drive: these plus favourite people and the phone's Trash.
    struct DriveCopy: Codable, Sendable {
        var entries: [String: Entry]
        var locations: [FileLocation]
        var favourites: [Favourite]
        var trash: [MediaTitle]
        var changed: [String: Date]
    }
    static let driveName = "twildiary_phone_v1.json"
    enum Part: String { case locations, favourites, trash }

    /// By title key ("tv:1399", "movie:603").
    private(set) var entries: [String: Entry]
    private(set) var locations: [FileLocation]
    private var changed: [String: Date]
    nonisolated private static let file = URL.applicationSupportDirectory.appending(path: "Local/extras.json")

    private init() {
        let saved = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        entries = saved?.entries ?? [:]; locations = saved?.locations ?? []; changed = saved?.changed ?? [:]
    }
    private func save(push: Bool = true) {
        BackgroundFiles.save(Saved(entries: entries, locations: locations, changed: changed), to: Self.file)
        if push { PhoneDriveSync.soon(); PhoneServerSync.shared.soon() }
    }
    /// Favourite people or the phone's Trash changed (sent to Drive in a moment).
    func touch(_ part: Part) { changed[part.rawValue] = .now; save() }

    nonisolated static func key(_ title: MediaTitle) -> String {
        title.tmdbId.map { (title.isSeries ? "tv:" : "movie:") + String($0) } ?? title.id
    }

    /// Saves an edit's extras: "tags", "queued", "notes", "status" (nil: the service keeps it now)
    /// and "favorite". Only the keys given change.
    func update(_ title: MediaTitle, _ values: [String: Any]) {
        let key = Self.key(title)
        var entry = entries[key] ?? Entry()
        if let tags = values["tags"] as? [String] { entry.tags = tags.isEmpty ? nil : tags }
        if let queued = values["queued"] as? Bool { entry.queued = queued ? true : nil }
        if values.keys.contains("notes") {
            let text = (values["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            entry.notes = text.isEmpty ? nil : text
        }
        if values.keys.contains("status") { entry.status = values["status"] as? String }
        if let favourite = values["favorite"] as? Bool { entry.favorite = favourite }
        entry.at = .now
        entries[key] = entry
        save()
    }
    /// The folders a Jellyfin "Sync now" found replace the previous ones.
    func setJellyfin(_ found: [FileLocation]) {
        locations = locations.filter { $0.deviceId != "jellyfin" } + found
        changed[Part.locations.rawValue] = .now
        save()
    }
    func forget() { entries = [:]; locations = []; changed = [:]; BackgroundFiles.cancel(Self.file); try? FileManager.default.removeItem(at: Self.file) }

    var backup: Backup {
        Backup(entries: entries, locations: locations, favourites: FavouritesStore.shared.items, trash: PhoneTrash.shared.titles)
    }
    /// A backup's phone extras come back, merging (what's on the phone now wins). An older backup
    /// (or your server's) carries them on its titles instead: tags, Queue, long notes and statuses.
    func restore(_ backup: Backup?, archive: DiaryExport) {
        var merged = entries
        for (key, entry) in backup?.entries ?? [:] where merged[key] == nil { merged[key] = entry }
        var keyForID: [String: String] = [:]
        for title in archive.titles where title.deletedAt == nil {
            let key = Self.key(title)
            keyForID[title.id] = key
            guard merged[key] == nil else { continue }
            var entry = Entry()
            if let tags = title.tags, !tags.isEmpty { entry.tags = tags }
            if title.queued == true { entry.queued = true }
            if title.notes.count > 500 { entry.notes = title.notes }
            if ["completed", "paused", "on_hold"].contains(title.status) || (!title.isSeries && title.status == "dropped") { entry.status = title.status }
            if !entry.isEmpty { entry.at = .now; merged[key] = entry }
        }
        entries = merged
        let known = Set(locations.map(\.id))
        let fromArchive = archive.locations.compactMap { location in keyForID[location.titleId].map { location.moved(to: $0) } }
        let added = ((backup?.locations ?? []) + fromArchive).filter { !known.contains($0.id) }
        if !added.isEmpty { locations += added; changed[Part.locations.rawValue] = .now }
        save()
        if let favourites = backup?.favourites { FavouritesStore.shared.merge(favourites) }
        if let trash = backup?.trash { PhoneTrash.shared.merge(trash) }
    }

    /// The extras as the record TraktDiary.build lays the service's diary over (in place of the
    /// server's): one title per key the service has, with its tags, Queue, note, status and
    /// favourite, and the Jellyfin folders.
    nonisolated static func workspace(_ entries: [String: Entry], locations: [FileLocation], library: TraktLibrary, catalog: [String: MediaTitle]) -> Workspace {
        guard !entries.isEmpty || !locations.isEmpty else { return Workspace() }
        var refs: [String: TraktTitleRef] = [:]
        for ref in library.plays.map(\.title) + library.ratings.map(\.title) + library.watchlist.map(\.title)
            + library.favorites.map(\.title) + library.dropped.map(\.title) {
            if let key = ref.diaryKey, refs[key] == nil { refs[key] = ref }
        }
        var titles: [MediaTitle] = []
        for (key, entry) in entries.sorted(by: { $0.key < $1.key }) where !entry.isEmpty {
            guard let ref = refs[key], let tmdb = ref.tmdbId else { continue }
            var title = catalog[key] ?? MediaTitle.imported(id: key, name: ref.name, series: ref.kind != .movie, year: ref.year, tmdbId: tmdb,
                                                             status: "planned", score: nil, createdAt: "")
            title.tags = entry.tags ?? []
            title.queued = entry.queued ?? false
            title.notes = entry.notes ?? ""
            title.status = entry.status ?? "planned"
            title.favorite = entry.favorite ?? false
            titles.append(title)
        }
        return Workspace(titles: titles, locations: locations)
    }
}

// MARK: Google Drive sync

extension PhoneExtras {
    var driveCopy: DriveCopy {
        DriveCopy(entries: entries, locations: locations, favourites: FavouritesStore.shared.items, trash: PhoneTrash.shared.titles, changed: changed)
    }
    /// Merges Drive's copy into the phone's: each title's extras by the newer change, and each
    /// whole list (Jellyfin folders, favourite people, Trash) by when it last changed. Returns
    /// whether the phone's copy changed, and whether Drive's is missing the phone's newer changes.
    func merge(_ remote: DriveCopy) -> (local: Bool, remote: Bool) {
        var localChanged = false, remoteBehind = false
        var merged = entries
        for key in Set(entries.keys).union(remote.entries.keys) {
            let mine = entries[key], theirs = remote.entries[key]
            guard mine != theirs else { continue }
            let mineAt = mine?.at ?? .distantPast, theirsAt = theirs?.at ?? .distantPast
            if let theirs, theirsAt >= mineAt { merged[key] = theirs; localChanged = true } else { remoteBehind = true }
        }
        func newer(_ part: Part) -> Bool? {
            let mine = changed[part.rawValue] ?? .distantPast, theirs = remote.changed[part.rawValue] ?? .distantPast
            return theirs > mine ? true : mine > theirs ? false : nil
        }
        switch newer(.locations) { case true?: locations = remote.locations; localChanged = true; case false?: remoteBehind = true; case nil: break }
        switch newer(.favourites) { case true?: FavouritesStore.shared.replace(remote.favourites); localChanged = true; case false?: remoteBehind = true; case nil: break }
        switch newer(.trash) { case true?: PhoneTrash.shared.replace(remote.trash); localChanged = true; case false?: remoteBehind = true; case nil: break }
        for (part, date) in remote.changed where date > (changed[part] ?? .distantPast) { changed[part] = date }
        if localChanged { entries = merged; save(push: false) }
        return (localChanged, remoteBehind)
    }
}

/// Keeps the phone's extras in step with the copy on Google Drive.
@MainActor enum PhoneDriveSync {
    private static var pending: Task<Void, Never>?
    private static var lastPull: Date?
    private static var running = false
    /// Drive's copy was read and merged since the app opened.
    private(set) static var synced = false
    /// Saves to Drive a few seconds after the last change (a run of edits goes once).
    static func soon() {
        guard GoogleDrive.connected, ExtrasStorage.drive else { return }
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            _ = try? await run()
        }
    }
    /// Reads Drive's copy, merges it into the phone's, and saves the result back when Drive's was
    /// missing something. Reading first means a new, empty install never overwrites Drive's copy.
    /// Returns whether the phone's copy changed. Quietly does nothing without Drive.
    @discardableResult static func run() async throws -> Bool {
        guard GoogleDrive.connected, ExtrasStorage.drive, !running else { return false }
        running = true; defer { running = false }
        let extras = PhoneExtras.shared
        let file = try await GoogleDrive.latest(PhoneExtras.driveName)
        lastPull = .now
        var result: (local: Bool, remote: Bool) = (false, true)
        if let file {
            let data = try await GoogleDrive.get(file)
            // A copy this app can't read (a newer version's) is left alone, not overwritten.
            guard let remote = try? JSONDecoder().decode(PhoneExtras.DriveCopy.self, from: data) else { return false }
            result = extras.merge(remote)
        } else if extras.driveCopy.entries.isEmpty, extras.driveCopy.locations.isEmpty,
                  FavouritesStore.shared.items.isEmpty, PhoneTrash.shared.titles.isEmpty {
            synced = true
            return false
        }
        if result.remote {
            try await GoogleDrive.put(try JSONEncoder().encode(extras.driveCopy), name: PhoneExtras.driveName, file: file)
        }
        synced = true
        return result.local
    }
    /// When the app opens (at most once a minute) and right after Drive connects: Drive's newer
    /// changes come in, the phone's go out, and the diary shows them.
    static func pullIfDue(store: DiaryStore, force: Bool = false) async {
        guard store.phoneOnly else { return }
        GoogleDrive.reconnectAfterReinstall()
        guard GoogleDrive.connected, force || Date.now.timeIntervalSince(lastPull ?? .distantPast) > 60 else { return }
        if (try? await run()) == true { store.applyDiarySource() }
    }
}

extension FavouritesStore {
    /// A backup's favourites join the phone's (the phone's own stay as they are).
    func merge(_ restored: [Favourite]) {
        let have = Set(items.map(\.id))
        replace((items + restored.filter { !have.contains($0.id) }).sorted { $0.savedAt > $1.savedAt })
        PhoneExtras.shared.touch(.favourites)
    }
}

extension PhoneTrash {
    /// A backup's Trash joins the phone's.
    func merge(_ restored: [MediaTitle]) {
        let have = Set(titles.map(\.id))
        replace(titles + restored.filter { !have.contains($0.id) })
        PhoneExtras.shared.touch(.trash)
    }
}
