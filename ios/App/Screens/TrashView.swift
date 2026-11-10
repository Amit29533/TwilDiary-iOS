import SwiftUI
import TwilDiaryCore

/// Trash has its own navigation, selection and recovery state. Library's Trash
/// shortcut opens this destination without changing any Library filter/scroll.
struct TrashView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("publicRatingSource") private var ratingSource = PublicRatingSource.tmdb
    @AppStorage("trashGrid") private var grid = true
    @AppStorage("trashCategory") private var category = LibraryCategory.all
    @AppStorage("trashSort") private var sort = "library"
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var review: CollectionReview?
    @State private var confirmEmpty = false
    var body: some View {
        // Filter and sort once per render; every use below shares these.
        let archived = self.archived
        let shown = self.shown
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 16) {

                // Design (boards 11 and 14): a 44 pt tile, "Removed titles", and the count or Empty on the right.
                HStack(spacing: 14) {
                    SettingsTile(symbol: "trash", size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Removed titles").font(.system(size: 17, weight: .bold)).foregroundStyle(HomeStyle.primary)
                        Text("Kept with their history; disk files stay untouched.").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if archived.isEmpty {
                        Text("Empty").font(.system(size: 12, weight: .bold)).foregroundStyle(HomeStyle.secondary)
                            .padding(.horizontal, 12).frame(height: 25).background(HomeStyle.round, in: Capsule())
                            .overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                    } else {
                        Menu {
                            Button("Empty Trash", systemImage: "trash", role: .destructive) { confirmEmpty = true }.disabled(store.writesBlocked)
                        } label: {
                            Text(archived.count.counted("title", "titles")).font(.system(size: 12, weight: .bold)).foregroundStyle(HomeStyle.chipText)
                                .padding(.horizontal, 12).frame(height: 24).background(HomeStyle.chip, in: Capsule())
                        }.accessibilityLabel("Empty Trash").accessibilityIdentifier("empty-trash")
                    }
                }.padding(17).frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsCard())
                CategoryPicker(selection: $category).padding(.horizontal, -14)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("In Trash").foregroundStyle(HomeStyle.secondary)
                        Text("(\(shown.count))").foregroundStyle(HomeStyle.primary)
                    }.font(.system(size: 18, weight: .bold))
                    Spacer(minLength: 0)
                    if selecting {
                        Button(selected.count == min(shown.count, CollectionRequest.limit) ? "Select none" : "Select all") {
                            selected = selected.count == min(shown.count, CollectionRequest.limit) ? [] : Set(shown.prefix(CollectionRequest.limit).map(\.id))
                        }.buttonStyle(SettingsPillButtonStyle(outlined: true)).disabled(shown.isEmpty)
                    } else {
                        Menu {
                            Picker("Trash order", selection: $sort) {
                                Text("Library order").tag("library")
                                Text("Title A–Z").tag("name")
                                Text("Newest year").tag("year")
                            }
                        } label: {
                            DiaryIcon(name: "arrow-down-up", size: 17).foregroundStyle(HomeStyle.dateChipText)
                                .frame(width: 44, height: 44).background(HomeStyle.round, in: Circle())
                                .overlay(Circle().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                        }.accessibilityLabel("Sort Trash")
                        CollectionLayoutToggle(grid: $grid, collection: "trash")
                    }
                }
                if selecting {
                    CollectionSelectionPanel(titles: shown, selected: $selected, archived: true) { change in
                        let titles = shown.filter { selected.contains($0.id) }
                        if !titles.isEmpty { review = CollectionReview(titles: titles, change: change) }
                    }
                }
                CollectionLayout(grid: grid) { ForEach(shown) { title in trashCard(title) } }
                if shown.isEmpty {
                    DiaryEmptyState(title: archived.isEmpty ? "Trash is clear" : "No removed titles in this category", description: archived.isEmpty ? "Removed titles and their history will appear here." : "Choose another category to see your removed titles.")
                        .padding(.top, 16)
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 100)
                .categorySwipe($category, enabled: !selecting)
        }.diaryScreenBackground().diaryPageNavigation("Trash")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Design: "Select" (dimmed when empty), "Done" in the accent pill while selecting.
                    Button(selecting ? "Done" : "Select") { selecting.toggle(); selected = [] }
                        .font(.system(size: 15, weight: selecting ? .bold : .semibold))
                        .foregroundStyle(selecting ? HomeStyle.chipText : archived.isEmpty ? Color(webHex: "#7a7a88") : HomeStyle.primary)
                        .disabled(archived.isEmpty).accessibilityIdentifier("trash-select")
                }
            }
            .refreshable { await store.refresh(); await store.loadPublicRatings(archived, source: ratingSource) }
            .task(id: archived.map(\.id).sorted().joined(separator: ",") + ratingSource.rawValue + String(store.communityRatings.retryRound)) { await store.loadPublicRatings(archived, source: ratingSource) }
            .onChange(of: category) { _, _ in selected = []; selecting = false }
            .onChange(of: archived.map(\.id)) { _, ids in selected.formIntersection(ids); if ids.isEmpty { selecting = false } }
            .sheet(item: $review) { value in CollectionReviewView(review: value) { selected = []; selecting = false } }
            .alert("Empty Trash?", isPresented: $confirmEmpty) {
                Button("Empty Trash", role: .destructive) { Task { await store.emptyTrash() } }
                Button("Cancel", role: .cancel) { }
            } message: { Text("This permanently removes every title in Trash and its diary history. Files on your disks stay untouched.") }
    }
    private var archived: [MediaTitle] { store.workspace.titles.filter { $0.deletedAt != nil } }
    private var shown: [MediaTitle] {
        var query = LibraryQuery()
        query.archived = true
        query.category = category == .movies ? "movie" : category == .shows ? "show" : category == .anime ? "anime" : "all"
        query.sort = sort == "name" ? .title : sort == "year" ? .year : .library
        return query.titles(in: store.workspace)
    }
    private func trashCard(_ title: MediaTitle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if selecting {
                Button {
                    if selected.contains(title.id) { selected.remove(title.id) }
                    else if selected.count < CollectionRequest.limit { selected.insert(title.id) }
                } label: {
                    card(title).overlay(alignment: .topTrailing) {
                        Image(systemName: selected.contains(title.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(theme.accent).padding(8)
                    }
                }.buttonStyle(.plain).disabled(store.writesBlocked || (!selected.contains(title.id) && selected.count >= CollectionRequest.limit))
                    .accessibilityIdentifier("trash-title-" + title.id).accessibilityAddTraits(selected.contains(title.id) ? .isSelected : [])
            } else {
                card(title).contextMenu { Button("Select", systemImage: "checkmark.circle") { selecting = true; selected = [title.id] } }
            }
            if !selecting {
                HStack {
                    Button("Restore", systemImage: "arrow.uturn.backward") { review = CollectionReview(titles: [title], change: .restore) }
                        .buttonStyle(.diarySecondary).accessibilityIdentifier("trash-restore-" + title.id)
                    Spacer(minLength: 0)
                    Button(role: .destructive) { review = CollectionReview(titles: [title], change: .purge) } label: { RoundTool(icon: "trash-2", tint: Color(webHex: "#ff8a80")) }
                        .buttonStyle(.plain).accessibilityLabel("Delete permanently").accessibilityIdentifier("trash-delete-" + title.id)
                }.disabled(store.writesBlocked)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("archived-title-" + title.id)
    }
    @ViewBuilder private func card(_ title: MediaTitle) -> some View {
        if grid { PosterCard(title: title, archived: true) }
        else { LibraryTitleRow(title: title, archived: true) }
    }
}
