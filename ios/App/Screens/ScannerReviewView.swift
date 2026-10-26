import SwiftUI
import TwilDiaryCore

struct ScannerReviewView: View {
    @Environment(DiaryStore.self) private var store
    @State private var showSearch = false
    @State private var items: [UnmatchedScan] = []
    @AppStorage("scannerGrid") private var grid = false
    @State private var next: String?
    @State private var seen = Set<String>()
    @State private var loading = false
    @State private var failure: String?
    @State private var selected: UnmatchedScan?
    @State private var message: String?
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                    HStack { Text("Unmatched scans").font(.system(size: 19, weight: .semibold)); Spacer(); CollectionLayoutToggle(grid: $grid, collection: "scans"); Button("Refresh unmatched scans", systemImage: "arrow.clockwise") { Task { await load() } }.labelStyle(.iconOnly).disabled(loading) }
                    Text("Scanned folders that need a title match.").font(.subheadline).foregroundStyle(.secondary)
                    if let failure { RetryNotice(message: failure) { Task { await load() } } }
                    if let message { Label(message, systemImage: "checkmark").font(.subheadline).diaryPanel() }
                    CollectionLayout(grid: grid) { ForEach(items) { scan in scanRow(scan) } }
                    if loading && items.isEmpty { DiaryLoadingPlaceholder(label: "Loading unmatched scans") }
                    else if !loading && items.isEmpty && failure == nil { ContentUnavailableView("No unmatched scans", systemImage: "folder.badge.questionmark", description: Text("New unresolved folders will appear here.")) }
                    if next != nil { Button("Show more") { Task { await load(more: true) } }.buttonStyle(.bordered).disabled(loading) }
                }.padding(14)
            }.refreshable { await load() }
        }.diaryScreenBackground().diaryPageNavigation("Fix mismatches", searchIdentifier: "search-scanner") { showSearch.toggle() }

            .task { await load() }
            .task(id: message) { guard message != nil else { return }; do { try await Task.sleep(for: .seconds(2)); message = nil } catch { } }
            .sheet(item: $selected) { scan in ScannerMatchView(scan: scan) { id in items.removeAll { $0.id == id }; message = "Folder matched" } }
    }
    private func scanRow(_ scan: UnmatchedScan) -> some View {
        let layout = grid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            DiaryIcon(name: "folder-search", size: 24).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 7) {
                Text(scan.name).font(.system(size: 15, weight: .semibold))
                Text("\(scan.deviceName) · \(scan.driveLetter) · \(scan.fileCount) files" + (scan.seasonNumber.map { " · Season \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                Text(scan.root + "\\" + scan.relativePath).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Text("No confident TMDb / IMDb match").font(.caption).foregroundStyle(.secondary)
                Button("Match") { selected = scan }.buttonStyle(.bordered).disabled(store.busy).accessibilityIdentifier("match-scan-" + scan.id)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.diaryPanel()
    }
    private func load(more: Bool = false) async {
        guard !loading else { return }; loading = true; failure = nil
        defer { loading = false }
        do {
            let result = try await store.unmatchedScans(after: more ? next : nil)
            guard !Task.isCancelled else { return }
            if !more { seen = []; items = [] }
            let existing = Set(items.map(\.id)); items += result.items.filter { !existing.contains($0.id) }
            if let cursor = result.nextCursor, !seen.insert(cursor).inserted { next = nil; throw APIError.message("The review returned a repeated page. Refresh before continuing.") }
            next = result.nextCursor
        } catch is CancellationError { }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

private struct ScannerMatchView: View {
    let scan: UnmatchedScan
    let onResolved: (String) -> Void
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var path = NavigationPath()
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Match “\(scan.name)”").font(.title3.bold()).padding(.horizontal, 14)
                    if let failure { Text(failure).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 14) }
                    CatalogSearchView(onLibraryChoose: choose, onCatalogChoose: { path.append($0) }).disabled(store.busy)
                }
            }.navigationTitle("Match folder").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.busy) } }
                .navigationDestination(for: CatalogRoute.self) { CatalogDetailView(route: $0, onImported: choose) }
                .navigationDestination(for: PersonFilmographyRoute.self) { PersonFilmographyView(route: $0) }
                .navigationDestination(for: PersonRoute.self) { PersonView(route: $0) }
        }.environment(\.diaryBack, DiaryBackAction {
            guard !path.isEmpty else { return false }; path.removeLast(); return true
        }).interactiveDismissDisabled(store.busy)
    }
    private func choose(_ id: String) {
        Task { if await store.resolveScan(scan, titleID: id) { onResolved(scan.id); dismiss() } else { failure = store.error ?? "The folder match was not confirmed. Try again." } }
    }
}
