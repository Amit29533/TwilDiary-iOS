import SwiftUI
import TwilDiaryCore

struct LibraryView: View {
    @Environment(DiaryStore.self) private var store
    @State private var category = LibraryCategory.all
    @State private var status = "all"
    @State private var genre = ""
    @State private var drive = ""
    @State private var search = ""
    @State private var showSearch = false
    @State private var list = false
    @State private var sort = "library"
    var body: some View {
        VStack(spacing: 0) {
            HStack { PageHeader(name: "Library", count: String(store.workspace.activeTitles.count)); Button { showSearch.toggle() } label: { Image(systemName: "magnifyingglass").font(.title3).padding(.trailing, 20) }.accessibilityLabel("Search library") }
            if showSearch { TextField("Search your library…", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12).accessibilityIdentifier("library-search") }
            CategoryPicker(selection: $category)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    Picker("Status", selection: $status) { Text("All statuses").tag("all"); ForEach(["planned", "watching", "completed", "dropped"], id: \.self) { Text($0.capitalized).tag($0) } }.pickerStyle(.menu)
                    Picker("Genre", selection: $genre) { Text("All genres").tag(""); ForEach(genres, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                    Picker("Disk", selection: $drive) { Text("All disks").tag(""); ForEach(drives, id: \.self) { Text("Drive " + $0).tag($0) } }.pickerStyle(.menu)
                    NavigationLink { TrashView() } label: { Label("Trash", systemImage: "trash") }.buttonStyle(.bordered)
                }.buttonStyle(.bordered).padding(.horizontal, 16).padding(.vertical, 10)
            }.scrollIndicators(.hidden)
            HStack {
                Text(filtered.count == store.workspace.activeTitles.count ? "All titles" : "\(filtered.count) titles").foregroundStyle(.secondary)
                Spacer()
                Picker("Order", selection: $sort) { Text("Library order").tag("library"); Text("Title A–Z").tag("name"); Text("Rating").tag("rating") }.pickerStyle(.menu)
                Button { list.toggle() } label: { Image(systemName: list ? "square.grid.2x2" : "rectangle.grid.1x2") }.accessibilityLabel("Change library layout")
            }.font(.subheadline).padding(.horizontal, 16).padding(.bottom, 10)
            ScrollView {
                if list {
                    LazyVStack(spacing: 10) { ForEach(filtered) { title in NavigationLink(value: title.id) { titleRow(title) }.buttonStyle(.plain) } }.padding(.horizontal, 16)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), alignment: .leading, spacing: 20) {
                        ForEach(filtered) { title in NavigationLink(value: title.id) { PosterCard(title: title) }.buttonStyle(.plain).accessibilityIdentifier("title-" + title.id) }
                    }.padding(.horizontal, 16)
                }
                if filtered.isEmpty { ContentUnavailableView("No matching titles", systemImage: "books.vertical", description: Text("Change your filters or search.")) }
            }.refreshable { await store.refresh() }
        }
    }
    private var genres: [String] { Set(store.workspace.activeTitles.flatMap(\.genres)).sorted() }
    private var drives: [String] { Set(store.workspace.locations.map(\.driveLetter)).sorted() }
    private var filtered: [MediaTitle] {
        let selected = store.workspace.activeTitles.filter { title in
            category.includes(title) && (status == "all" || title.status == status) && (genre.isEmpty || title.genres.contains(genre)) && (search.isEmpty || title.name.localizedCaseInsensitiveContains(search)) && (drive.isEmpty || store.workspace.locations.contains { $0.titleId == title.id && $0.driveLetter == drive })
        }
        if sort == "name" { return selected.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        if sort == "rating" { return selected.sorted { ($0.communityScore ?? 0) > ($1.communityScore ?? 0) } }
        return selected
    }
}

func titleRow(_ title: MediaTitle) -> some View {
    HStack(spacing: 12) {
        Artwork(path: title.poster, title: title.name).frame(width: 48, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 5) { Text(title.name).font(.subheadline.bold()); Text(title.categoryName).font(.caption).foregroundStyle(.secondary) }
        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
    }.foregroundStyle(.white).diaryPanel()
}

struct GlanceView: View {
    @Environment(DiaryStore.self) private var store
    @State private var category = LibraryCategory.all
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(name: "Glance", count: "\(titles.count) watching")
            CategoryPicker(selection: $category)
            ScrollView {
                LazyVStack(spacing: 12) { ForEach(titles) { ProgressCard(title: $0) } }.padding(16)
                if titles.isEmpty { ContentUnavailableView("Nothing in progress", systemImage: "eye", description: Text("Set a title to Watching to see it here.")) }
            }.refreshable { await store.refresh() }
        }
    }
    private var titles: [MediaTitle] { store.workspace.activeTitles.filter { $0.status == "watching" && category.includes($0) } }
}

struct TrashView: View {
    @Environment(DiaryStore.self) private var store
    var body: some View {
        List(store.workspace.titles.filter { $0.deletedAt != nil }) { title in Text(title.name) }
            .overlay { if !store.workspace.titles.contains(where: { $0.deletedAt != nil }) { ContentUnavailableView("Trash is empty", systemImage: "trash") } }
            .navigationTitle("Trash").toolbar(.visible, for: .navigationBar)
    }
}
