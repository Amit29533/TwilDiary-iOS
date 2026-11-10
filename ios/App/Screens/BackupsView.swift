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
    private struct Snapshot: Decodable { let diary: DiaryExport }

    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
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
                    Text("A copy of your whole diary (titles, watches, ratings, notes, tags and file mappings) plus your last Trakt read, kept on your server. Restoring merges it back, so nothing newer is lost.")
                        .font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
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
            .confirmationDialog("Restore this backup?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible, presenting: restoring) { backup in
                Button("Restore \(backup.label)") { Task { await restore(backup) } }
                Button("Cancel", role: .cancel) {}
            } message: { backup in
                Text(store.traktHoldsDiary
                     ? "What Trakt doesn’t have from this backup (\(backup.titles.counted("title", "titles")), \(backup.watches.counted("watch", "watches")) from \(date(backup))) is added to Trakt. Nothing on Trakt is changed or removed."
                     : "\(backup.titles.counted("title", "titles")) and \(backup.watches.counted("watch", "watches")) from \(date(backup)) are merged into your diary. Anything newer stays.")
            }
            .confirmationDialog("Delete this backup?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { backup in
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
        do { backups = (try await store.read("/api/backups") as BackupList).backups; failure = nil }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
    private func backUp() async {
        working = "Backing up…"; message = nil; failure = nil
        defer { working = nil }
        do {
            let snapshot = store.workspace
            let diaryData = try await Task.detached(priority: .userInitiated) { try DiaryExport(workspace: snapshot).encoded() }.value
            guard let diary = try JSONSerialization.jsonObject(with: diaryData) as? [String: Any] else { throw APIError.message("The diary couldn’t be packed.") }
            var body: [String: Any] = ["label": "Manual backup", "diary": diary]
            if let library = TraktDirectStore.shared.library, let data = try? JSONEncoder().encode(library),
               let trakt = try? JSONSerialization.jsonObject(with: data) { body["trakt"] = trakt }
            let saved: Summary = try await store.read("/api/backups", method: "POST", body: body, timeout: 60)
            message = "Backed up \(saved.titles.counted("title", "titles")) and \(saved.watches.counted("watch", "watches"))."
            await load()
        } catch { failure = error.localizedDescription }
    }
    private func restore(_ backup: Summary) async {
        working = "Restoring…"; message = nil; failure = nil
        defer { working = nil }
        do {
            let snapshot: Snapshot = try await store.read("/api/backups/" + backup.id, timeout: 60)
            // Restore goes where your diary lives: into Trakt when Trakt holds it (the server's
            // copy is read-only then, and changing it wouldn't change what you see).
            if store.traktHoldsDiary {
                let diary = try snapshot.diary.merged(into: Workspace())
                message = try await TraktDirectStore.shared.restore(diary, store: store)
                return
            }
            if let service = store.diaryService ?? store.serverRecord {
                failure = "Restoring a backup isn’t available yet while \(service.name) holds your diary."
                return
            }
            let data = try snapshot.diary.encoded()
            let result = try await store.importDiaryArchive(data)
            message = "Restored to your server diary: \(result.titles.counted("title", "titles")) and \(result.events.counted("watch", "watches")) merged. What was already there was kept."
        } catch { failure = error.localizedDescription }
    }
    private func delete(_ backup: Summary) async {
        struct Deleted: Decodable { let deleted: Bool }
        do { _ = try await store.read("/api/backups/" + backup.id, method: "DELETE") as Deleted; await load() }
        catch { failure = error.localizedDescription }
    }
}
