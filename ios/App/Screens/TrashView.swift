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
                    Text("Removed titles").font(.system(size: 17, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
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
                CategoryPicker(selection: $category, pills: true).padding(.horizontal, -14)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("In Trash").foregroundStyle(HomeStyle.secondary)
                        Text("(\(shown.count))").foregroundStyle(HomeStyle.primary)
                    }.font(.system(size: 18, weight: .bold))
                    Spacer(minLength: 0)
                    if selecting {
                        Button(allSelected ? "Select none" : "Select all") { toggleAll() }.buttonStyle(SettingsPillButtonStyle(outlined: true)).disabled(shown.isEmpty)
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
                CollectionLayout(grid: grid) { ForEach(shown) { title in trashCard(title) } }
                if shown.isEmpty {
                    DiaryEmptyState(title: archived.isEmpty ? "Trash is clear" : "No removed titles in this category", description: archived.isEmpty ? "Removed titles and their history will appear here." : "Choose another category to see your removed titles.")
                        .padding(.top, 16)
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 100)
                .categorySwipe($category, enabled: !selecting)
        }.diaryScreenBackground().diaryPageNavigation("Trash")
            // Design (board 14): while selecting, one bar above the tab bar: the count, Restore, Delete forever.
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    let titles = shown.filter { selected.contains($0.id) }
                    HStack(spacing: 10) {
                        Text(titles.isEmpty ? "Select titles" : "\(titles.count) selected").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(HomeStyle.primary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Restore") { review = CollectionReview(titles: titles, change: .restore) }
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(HomeStyle.chipText)
                            .padding(.horizontal, 18).frame(height: 40)
                            .background(HomeStyle.chip, in: Capsule())
                            .accessibilityIdentifier("trash-restore-selected")
                        Button("Delete forever", role: .destructive) { review = CollectionReview(titles: titles, change: .purge) }
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(Color(themed: "#ffb3c0"))
                            .padding(.horizontal, 16).frame(height: 40).background(Color(themed: "#3a1d26"), in: Capsule())
                            .accessibilityIdentifier("trash-delete-selected")
                    }.buttonStyle(.plain).disabled(titles.isEmpty || store.writesBlocked)
                        .padding(.leading, 18).padding(.trailing, 8).frame(height: 56)
                        .background(Color(themed: "#1a1a20"), in: Capsule())
                        .overlay(Capsule().strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                        .padding(.horizontal, 16).padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.25), value: selecting)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Design: "Select" (dimmed when empty), "Done" in the accent pill while selecting.
                    Button(selecting ? "Done" : "Select") { selecting.toggle(); selected = [] }
                        .font(.system(size: 15, weight: selecting ? .bold : .semibold))
                        .foregroundStyle(selecting ? HomeStyle.chipText : archived.isEmpty ? Color(themed: "#7a7a88") : HomeStyle.primary)
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
    private var archived: [MediaTitle] {
        // No server: the phone's own Trash.
        store.phoneOnly ? PhoneTrash.shared.titles : store.workspace.titles.filter { $0.deletedAt != nil }
    }
    /// Every title that can be picked at once (up to the limit) is picked.
    private var allSelected: Bool { selected.count == min(shown.count, CollectionRequest.limit) }
    private func toggleAll() {
        let ids: Set<String> = allSelected ? [] : Set(shown.prefix(CollectionRequest.limit).map(\.id))
        selected = ids
    }
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
                    card(title).overlay(alignment: grid ? .topTrailing : .leading) {
                        ZStack {
                            Circle().fill(selected.contains(title.id) ? theme.accent : HomeStyle.card.opacity(0.85))
                            Circle().strokeBorder(selected.contains(title.id) ? .clear : Color(themed: "#4a4a56"), lineWidth: 1.5)
                            if selected.contains(title.id) { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(ThemeStore.current.accentInk) }
                        }.frame(width: 26, height: 26).padding(grid ? 8 : 0).offset(x: grid ? 0 : -6)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selected.contains(title.id) ? theme.accent : .clear, lineWidth: 1.5))
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
                    Button(role: .destructive) { review = CollectionReview(titles: [title], change: .purge) } label: { RoundTool(icon: "trash-2", tint: Color(themed: "#ff8a80")) }
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
