import SwiftUI
import TwilDiaryCore

/// Trakt-first phase 3: manual backups on your server. "Back up now" saves the whole diary plus
/// the last Trakt read (compressed, the newest 20 kept); Restore puts a backup back through the
/// diary import, which merges, so nothing newer is lost.
struct BackupsView: View {
    struct Summary: Decodable, Identifiable, Hashable {
        let id: String
        let createdAt: String
        let label: String
        let titles: Int
        let watches: Int
        let sizeBytes: Int
    }
    private struct BackupList: Decodable { let backups: [Summary] }
    private struct Snapshot: Decodable { let diary: DiaryExport; let phone: PhoneExtras.Backup? }

    @Environment(DiaryStore.self) private var store
    @State private var backups: [Summary]?
    @State private var working: String?
    @State private var message: String?
    @State private var failure: String?
    @State private var restoring: Summary?
    @State private var deleting: Summary?

    var body: some View {
        EdgeToEdgeScroll {
            // Design (board 5): the Last backup card with its button, then RECENT BACKUPS.
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        SettingsTile(symbol: "externaldrive.badge.timemachine", size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Last backup").font(.system(size: 17, weight: .bold)).foregroundStyle(HomeStyle.primary)
                            Text(backups?.first.map(date) ?? (backups == nil ? "Checking…" : "None yet")).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        Text("Your whole diary, kept on your server").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        SettingsInfoButton(text: "Titles, watches, ratings, notes, tags and file locations, plus your last Trakt read. Restoring merges it back, so nothing newer is lost.")
                    }
                    ServerBackups.SchedulePicker()
                    Button { Task { await backUp() } } label: {
                        HStack(spacing: 8) {
                            if working != nil { ProgressView().controlSize(.small).tint(Color(webHex: "#1a1030")) }
                            Text(working ?? "Back up now")
                        }
                    }.buttonStyle(SettingsPrimaryButtonStyle()).disabled(working != nil || store.isPreview).accessibilityIdentifier("backup-now")
                }.padding(17).modifier(SettingsCard())
                if let message { SettingsFootnote(text: message) }
                if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(Color(webHex: "#ff8a8a")).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4) }
                if let backups {
                    if backups.isEmpty {
                        DiaryEmptyState(title: "No backups yet", description: "Back up before big changes, like switching to Trakt as your diary.")
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            Text("RECENT BACKUPS").font(.system(size: 13, weight: .bold)).foregroundStyle(HomeStyle.secondary)
                            Spacer(minLength: 8)
                            Text("The newest 20 are kept").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                        }.padding(.horizontal, 4).padding(.top, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(backups.enumerated()), id: \.element.id) { index, backup in
                                if index > 0 { SettingsDivider() }
                                row(backup)
                            }
                        }.modifier(SettingsCard())
                    }
                } else if failure == nil {
                    DiaryLoadingPlaceholder(height: 160, label: "Loading backups")
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40).smoothChange(of: backups?.count ?? -1)
        }.diaryScreenBackground().diaryPageNavigation("Backups")
            .task { await load() }
            .refreshable { await load() }
            .alert("Restore this backup?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),  presenting: restoring) { backup in
                Button("Restore \(backup.label)") { Task { await restore(backup) } }
                Button("Cancel", role: .cancel) {}
            } message: { backup in
                Text(store.traktHoldsDiary
                     ? "What Trakt doesn’t have from this backup (\(backup.titles.counted("title", "titles")), \(backup.watches.counted("watch", "watches")) from \(date(backup))) is added to Trakt. Nothing on Trakt is changed or removed."
                     : "\(backup.titles.counted("title", "titles")) and \(backup.watches.counted("watch", "watches")) from \(date(backup)) are merged into your diary. Anything newer stays.")
            }
            .alert("Delete this backup?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),  presenting: deleting) { backup in
                Button("Delete", role: .destructive) { Task { await delete(backup) } }
                Button("Cancel", role: .cancel) {}
            }
    }

    private func row(_ backup: Summary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(date(backup)).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                Text([backup.label, backup.titles.counted("title", "titles"), backup.watches.counted("watch", "watches"),
                      ByteCountFormatter.string(fromByteCount: Int64(backup.sizeBytes), countStyle: .file)].joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Restore", systemImage: "arrow.counterclockwise") { restoring = backup }
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = backup }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.dateChipText)
                    .frame(width: 44, height: 44).background(HomeStyle.round, in: Circle())
            }.disabled(working != nil)
                .accessibilityLabel("Backup actions").accessibilityIdentifier("backup-actions-\(backup.id)")
        }.padding(.horizontal, 15).padding(.vertical, 14).frame(minHeight: 84)
    }
    private func date(_ backup: Summary) -> String {
        DiaryDate.parse(backup.createdAt)?.formatted(date: .abbreviated, time: .shortened) ?? backup.createdAt
    }

    private func load() async {
        #if DEBUG
        if store.isPreview { backups = []; return }
        #endif
        do {
            backups = (try await ServerBackups.read(store, "/api/backups") as BackupList).backups; failure = nil
            ServerBackups.noteLatest(backups?.compactMap { DiaryDate.parse($0.createdAt) }.max())
        }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
    private func backUp() async {
        working = "Backing up…"; message = nil; failure = nil
        defer { working = nil }
        do {
            let saved = try await ServerBackups.save(store: store, label: "Manual backup")
            message = "Backed up \(saved.titles.counted("title", "titles")) and \(saved.watches.counted("watch", "watches"))."
            await load()
        } catch { failure = error.localizedDescription }
    }
    private func restore(_ backup: Summary) async {
        working = "Restoring…"; message = nil; failure = nil
        defer { working = nil }
        do {
            let snapshot: Snapshot = try await ServerBackups.read(store, "/api/backups/" + backup.id, timeout: 60)
            // Restore goes where your diary lives: into Trakt when Trakt holds it (the server's
            // copy is read-only then, and changing it wouldn't change what you see).
            message = try await ServerBackups.restore(snapshot.diary, phone: snapshot.phone, store: store)
        } catch { failure = error.localizedDescription }
    }
    private func delete(_ backup: Summary) async {
        struct Deleted: Decodable { let deleted: Bool }
        do { _ = try await ServerBackups.read(store, "/api/backups/" + backup.id, method: "DELETE") as Deleted; await load() }
        catch { failure = error.localizedDescription }
    }
}

/// Backups on your server: "Back up now", and the automatic ones (Off, Daily, Weekly, Monthly;
/// weekly unless you change it), saved when the app opens or refreshes in the background once one
/// is due. An empty diary isn't backed up; a failed attempt waits six hours before the next.
@MainActor enum ServerBackups {
    static let scheduleKey = "serverBackup.schedule"
    private static let lastKey = "serverBackup.last", attemptKey = "serverBackup.attempt"
    static var schedule: BackupSchedule {
        BackupSchedule(rawValue: UserDefaults.standard.string(forKey: scheduleKey) ?? "") ?? .weekly
    }
    static var last: Date? {
        let stamp = UserDefaults.standard.double(forKey: lastKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }
    /// The newest backup the server lists (manual ones count too).
    static func noteLatest(_ date: Date?) {
        guard let date, date > (last ?? .distantPast) else { return }
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastKey)
    }

    /// The whole diary plus the last Trakt read, compressed and kept on your server (newest 20).
    /// The backup itself: the whole diary plus the last Trakt read (server and Google Drive alike).
    static func snapshot(store: DiaryStore, label: String) async throws -> [String: Any] {
        let snapshot = store.workspace
        let diaryData = try await Task.detached(priority: .utility) { try DiaryExport(workspace: snapshot).encoded() }.value
        guard let diary = try JSONSerialization.jsonObject(with: diaryData) as? [String: Any] else { throw APIError.message("The diary couldn’t be packed.") }
        var body: [String: Any] = ["label": label, "diary": diary]
        if let library = TraktDirectStore.shared.library, let data = try? JSONEncoder().encode(library),
           let trakt = try? JSONSerialization.jsonObject(with: data) { body["trakt"] = trakt }
        if store.phoneOnly, let phone = phoneExtras() { body["phone"] = phone }
        return body
    }
    /// With no server: the phone's tags, Queue, full notes, statuses, file folders, favourite
    /// people and Trash, as a backup carries them.
    static func phoneExtras() -> Any? {
        (try? JSONEncoder().encode(PhoneExtras.shared.backup)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }
    /// Puts a backup back where your diary lives (Trakt, the diary on this phone, or the server's),
    /// merging, so nothing newer is lost. Returns what to tell you.
    static func restore(_ archive: DiaryExport, phone: PhoneExtras.Backup? = nil, store: DiaryStore) async throws -> String {
        // No server: what the service can't hold comes back onto the phone (merged, before the
        // service's part, so the rebuilt diary shows it).
        if store.phoneOnly { PhoneExtras.shared.restore(phone, archive: archive) }
        if store.traktHoldsDiary {
            return try await TraktDirectStore.shared.restore(try archive.merged(into: Workspace()), store: store)
        }
        if let tracker = store.diaryFromTracker {
            return try await TrackerPreviewStore.shared.restore(tracker, try archive.merged(into: Workspace()), store: store)
        }
        if let service = store.diaryService ?? store.serverRecord {
            throw APIError.message("Restoring a backup isn’t available yet while \(service.name) holds your diary.")
        }
        let result = try await store.importDiaryArchive(try archive.encoded())
        return "Restored to your server diary: \(result.titles.counted("title", "titles")) and \(result.events.counted("watch", "watches")) merged. What was already there was kept."
    }
    @discardableResult static func save(store: DiaryStore, label: String) async throws -> BackupsView.Summary {
        let body = try await snapshot(store: store, label: label)
        let saved: BackupsView.Summary = try await read(store, "/api/backups", method: "POST", body: body, timeout: 60)
        noteLatest(DiaryDate.parse(saved.createdAt) ?? .now)
        return saved
    }

    /// With no server diary (Trakt only), backups still go to your server when "Your server" is on
    /// under Where extras live, with that same sign-in (owner's choice: the server is optional, for
    /// signing in, backups and extras).
    static func usesPhoneSession(_ store: DiaryStore) -> Bool { store.phoneOnly && !store.onThisPhone && ExtrasStorage.server }
    /// Whether server backups can be made now.
    static func available(_ store: DiaryStore) -> Bool { !store.phoneOnly || usesPhoneSession(store) }
    /// A backups call: with the diary's server sign-in, or the extras one with no server diary.
    static func read<T: Decodable>(_ store: DiaryStore, _ path: String, method: String = "GET", body: [String: Any]? = nil,
                                   timeout: TimeInterval? = nil) async throws -> T {
        guard usesPhoneSession(store) else { return try await store.read(path, method: method, body: body, timeout: timeout) }
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try JSONDecoder().decode(T.self, from: try await PhoneServerSync.shared.send(path, method: method, body: data, store: store))
    }

    /// Saves an automatic backup when one is due.
    static func runIfDue(store: DiaryStore, now: Date = .now) async {
        guard !store.isPreview, !store.needsSignIn, store.hasLoadedWorkspace, !store.workspace.titles.isEmpty, available(store),
              schedule.isDue(last: last, now: now) else { return }
        let attempted = UserDefaults.standard.double(forKey: attemptKey)
        guard now.timeIntervalSince1970 - attempted > 6 * 3_600 else { return }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: attemptKey)
        _ = try? await save(store: store, label: "Automatic backup")
    }

    /// "Automatic backups: Weekly" with the next one's date.
    struct SchedulePicker: View {
        @AppStorage(ServerBackups.scheduleKey) private var choice = BackupSchedule.weekly.rawValue
        var body: some View {
            let current = BackupSchedule(rawValue: choice) ?? .weekly
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic backups").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                    Text(current.next(after: ServerBackups.last).map { "Next: " + ($0 <= .now ? "when you next open the app" : $0.formatted(date: .abbreviated, time: .omitted)) } ?? "Only when you tap Back up now")
                        .font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Menu {
                    Picker("Automatic backups", selection: $choice) {
                        ForEach(BackupSchedule.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                } label: {
                    HStack(spacing: 6) { Text(current.label); Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)) }
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(HomeStyle.chipText)
                        .padding(.horizontal, 12).frame(height: 32).background(HomeStyle.chip, in: Capsule())
                }.accessibilityLabel("Automatic backups").accessibilityValue(current.label).accessibilityIdentifier("backup-schedule")
            }
        }
    }
}
