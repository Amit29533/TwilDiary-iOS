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
            VStack(alignment: .leading, spacing: 16) {
                Text("A copy of your whole diary (titles, watches, ratings, notes, tags and file mappings) plus your last Trakt read, kept on your server. Restoring merges it back, so nothing newer is lost.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { Task { await backUp() } } label: {
                    HStack(spacing: 8) {
                        if working != nil { ProgressView().controlSize(.small) } else { Image(systemName: "externaldrive.badge.icloud") }
                        Text(working ?? "Back up now").font(.system(size: 16, weight: .semibold))
                    }.frame(maxWidth: .infinity).frame(minHeight: 30)
                }.buttonStyle(.glassProminent).controlSize(.large).disabled(working != nil || store.isPreview).accessibilityIdentifier("backup-now")
                if let message { Label(message, systemImage: "checkmark").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let failure { Text(failure).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if let backups {
                    if backups.isEmpty {
                        DiaryEmptyState(title: "No backups yet", description: "Back up before big changes, like switching to Trakt as your diary.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(backups.enumerated()), id: \.element.id) { index, backup in
                                if index > 0 { Divider().padding(.leading, 14) }
                                row(backup)
                            }
                        }.background(theme.field, in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
                        Text("The newest 20 are kept.").font(.caption).foregroundStyle(.secondary)
                    }
                } else if failure == nil {
                    DiaryLoadingPlaceholder(height: 160, label: "Loading backups")
                }
            }.padding(14).padding(.bottom, 40).smoothChange(of: backups?.count ?? -1)
        }.diaryScreenBackground().navigationTitle("Backups").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .task { await load() }
            .refreshable { await load() }
            .confirmationDialog("Restore this backup?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible, presenting: restoring) { backup in
                Button("Restore \(backup.label)") { Task { await restore(backup) } }
                Button("Cancel", role: .cancel) {}
            } message: { backup in
                Text("\(backup.titles.counted("title", "titles")) and \(backup.watches.counted("watch", "watches")) from \(date(backup)) are merged into your diary. Anything newer stays.")
            }
            .confirmationDialog("Delete this backup?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { backup in
                Button("Delete", role: .destructive) { Task { await delete(backup) } }
                Button("Cancel", role: .cancel) {}
            }
    }

    private func row(_ backup: Summary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(date(backup)).font(.system(size: 15, weight: .semibold))
                Text([backup.label, backup.titles.counted("title", "titles"), backup.watches.counted("watch", "watches"),
                      ByteCountFormatter.string(fromByteCount: Int64(backup.sizeBytes), countStyle: .file)].joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Restore", systemImage: "arrow.counterclockwise") { restoring = backup }
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = backup }
            } label: { RoundTool(icon: "ellipsis", size: 36) }.disabled(working != nil)
                .accessibilityLabel("Backup actions").accessibilityIdentifier("backup-actions-\(backup.id)")
        }.padding(.horizontal, 14).frame(minHeight: 64)
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
            let data = try snapshot.diary.encoded()
            let result = try await store.importDiaryArchive(data)
            message = "Restored: \(result.titles.counted("title", "titles")) and \(result.events.counted("watch", "watches")) merged."
        } catch { failure = error.localizedDescription }
    }
    private func delete(_ backup: Summary) async {
        struct Deleted: Decodable { let deleted: Bool }
        do { _ = try await store.read("/api/backups/" + backup.id, method: "DELETE") as Deleted; await load() }
        catch { failure = error.localizedDescription }
    }
}
