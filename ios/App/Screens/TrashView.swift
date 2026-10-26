import SwiftUI
import TwilDiaryCore

/// Trash has its own navigation, selection and recovery state. Library's Trash
/// shortcut opens this destination without changing any Library filter/scroll.
struct TrashView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("publicRatingSource") private var ratingSource = PublicRatingSource.tmdb
    @AppStorage("trashGrid") private var grid = true
    @State private var category = LibraryCategory.all
    @State private var sort = "library"
    @State private var showSearch = false
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var review: CollectionReview?
    @State private var confirmEmpty = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                VStack(alignment: .leading, spacing: 10) {
                    Label("Removed titles", systemImage: "trash").font(.headline)
                    Text("Removed titles stay here with their history. Restore them to your Library, or review a permanent deletion. Files on your disks stay untouched.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Empty Trash", systemImage: "trash", role: .destructive) { confirmEmpty = true }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).disabled(store.writesBlocked || archived.isEmpty).accessibilityIdentifier("empty-trash")
                }.diaryPanel()
                CategoryPicker(selection: $category).padding(.horizontal, -14)
                HStack(spacing: 8) {
                    Text("In Trash").font(.headline)
                    Text("\(shown.count)").font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Menu {
                        Picker("Trash order", selection: $sort) {
                            Text("Library order").tag("library")
                            Text("Title A–Z").tag("name")
                            Text("Newest year").tag("year")
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44) }.accessibilityLabel("Sort Trash")
                    CollectionLayoutToggle(grid: $grid, collection: "trash")
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
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 100)
        }.background(theme == .glass ? .clear : Color(webHex: "#0e0d13")).diaryScreenBackground()
            .navigationTitle("Trash").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSearch.toggle() } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Search library and online").accessibilityIdentifier("search-trash")
                    Button(selecting ? "Done selecting" : "Select") { selecting.toggle(); selected = [] }.disabled(archived.isEmpty).accessibilityIdentifier("trash-select")
                }
            }
            .refreshable { await store.refresh(); await store.loadPublicRatings(archived, source: ratingSource) }
            .task(id: archived.map(\.id).sorted().joined(separator: ",") + ratingSource.rawValue) { await store.loadPublicRatings(archived, source: ratingSource) }
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
                card(title).contextMenu { Button("Select") { selecting = true; selected = [title.id] } }
            }
            if !selecting {
                HStack {
                    Button("Restore", systemImage: "arrow.uturn.backward") { review = CollectionReview(titles: [title], change: .restore) }
                        .accessibilityIdentifier("trash-restore-" + title.id)
                    Spacer(minLength: 0)
                    Button("Delete permanently", systemImage: "trash", role: .destructive) { review = CollectionReview(titles: [title], change: .purge) }
                        .labelStyle(.iconOnly).accessibilityIdentifier("trash-delete-" + title.id)
                }.font(.caption.weight(.semibold)).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).disabled(store.writesBlocked)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("archived-title-" + title.id)
    }
    @ViewBuilder private func card(_ title: MediaTitle) -> some View {
        if grid { PosterCard(title: title, archived: true) }
        else { LibraryTitleRow(title: title, archived: true) }
    }
}
