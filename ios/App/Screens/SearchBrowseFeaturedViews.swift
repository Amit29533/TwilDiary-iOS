import SwiftUI
import TwilDiaryCore

struct SearchTagsShelf: View {
    let shows: [CatalogItem]
    @Environment(DiaryStore.self) private var store
    @ScaledMetric(relativeTo: .subheadline) private var tagRowHeight: CGFloat = 44
    @State private var popular: [SearchBrowseTag] = []
    @State private var loadedKeys: [String] = []

    private var tags: [SearchBrowseTag] {
        let names = Set(popular.map(\.id))
        return popular + SearchBrowseTag.suggestions.filter { !names.contains($0.id) }
    }

    var body: some View {
        let keys = shows.prefix(5).map(\.key)
        VStack(alignment: .leading, spacing: 8) {
            SearchBrowseHeading(shelf: .tags, destination: .tags(tags))
            Text(popular.isEmpty ? "Suggested tags" : "Top show tags and suggestions")
                .font(.subheadline).foregroundStyle(HomeStyle.secondary)
            ScrollView(.horizontal) {
                let rows = Array(repeating: GridItem(.fixed(tagRowHeight), spacing: 4, alignment: .leading), count: 2)
                LazyHGrid(rows: rows, alignment: .top, spacing: 8) {
                    ForEach(tags.prefix(12)) { SearchTagLink(tag: $0) }
                }.padding(.horizontal, 14)
            }.padding(.horizontal, -14).scrollIndicators(.hidden)
        }.task(id: keys) {
            guard !keys.isEmpty, keys != loadedKeys else { return }
            let found = await SearchBrowseTag.popular(from: shows, store: store)
            guard !Task.isCancelled else { return }
            popular = found
            loadedKeys = keys
        }
    }
}

struct SearchTagsPage: View {
    let tags: [SearchBrowseTag]
    @Environment(DiaryStore.self) private var store
    @State private var text = ""
    @State private var matches: [SearchBrowseTag] = []
    @State private var completed: String?
    @State private var failure: String?
    private var query: String { String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 12) {
                SearchField(placeholder: "Find tags", text: $text, label: "Find tags")
                if query.count < 2 {
                    InlineFlowLayout { ForEach(tags) { SearchTagLink(tag: $0) } }
                } else if completed != query {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 44).accessibilityLabel("Finding tags")
                } else if let failure {
                    RetryNotice(message: failure) { Task { await find(query) } }
                } else if matches.isEmpty {
                    Text("No tags match “\(query)”.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    InlineFlowLayout { ForEach(matches) { SearchTagLink(tag: $0) } }
                }
            }.padding(14)
        }.scrollDismissesKeyboard(.interactively)
            .diaryScreenBackground().navigationTitle("Find tags").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task(id: query) {
                guard query.count >= 2, completed != query else { return }
                let requested = query
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                await find(requested)
            }
    }

    private func find(_ requested: String) async {
        guard requested == query else { return }
        completed = nil; failure = nil
        do {
            let found = try await SearchBrowseTag.find(requested, store: store)
            guard !Task.isCancelled, requested == query else { return }
            matches = found; completed = requested
        } catch {
            guard !Task.isCancelled, requested == query else { return }
            failure = error.localizedDescription; completed = requested
        }
    }
}

private struct SearchTagLink: View {
    let tag: SearchBrowseTag

    var body: some View {
        NavigationLink(value: SearchBrowseRoute.tag(tag)) {
            HStack(spacing: 6) {
                Text(tag.emoji).accessibilityHidden(true)
                Text(tag.name.prefix(1).uppercased() + tag.name.dropFirst()).lineLimit(1)
            }.font(.subheadline.weight(.medium)).foregroundStyle(HomeStyle.primary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(HomeStyle.round, in: Capsule())
                .frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.springPress).accessibilityIdentifier("search-tag-" + tag.id)
    }
}

struct SearchTagTitlesPage: View {
    let tag: SearchBrowseTag
    var title: String? = nil
    var types: [MediaKind] = [.movie, .tv]
    @Environment(DiaryStore.self) private var store
    @State private var category: SearchBrowseCategory?
    @State private var failure: String?

    var body: some View {
        if let category {
            SearchBrowseTitlesPage(category: category, store: store)
        } else {
            EdgeToEdgeScroll(frosted: true) {
                if let failure {
                    RetryNotice(message: failure) { Task { await load() } }.padding(14)
                } else {
                    DiaryLoadingPlaceholder(label: "Finding tag", layout: .posterGrid(columns: 3, rows: 2)).padding(14)
                }
            }.diaryScreenBackground().navigationTitle(title ?? tag.name.capitalized).navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .task { await load() }
        }
    }

    private func load() async {
        failure = nil
        do { category = try await tag.resolve(store: store, title: title, types: types) }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

struct SearchThemesShelf: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let largeType = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 8) {
            SearchBrowseHeading(shelf: .themes, icon: "square.grid.2x2")
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(SearchBrowseTheme.allCases) { theme in
                        SearchThemeCard(theme: theme)
                            .containerRelativeFrame(.horizontal) { width, _ in
                                largeType ? min(280, width * 0.8) : min(194, width * 0.39)
                            }
                    }
                }.padding(.horizontal, 14)
            }.scrollIndicators(.hidden).padding(.horizontal, -14)
        }
    }
}

struct SearchThemesGrid: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2),
                      spacing: 12) {
                ForEach(SearchBrowseTheme.allCases) { SearchThemeCard(theme: $0) }
            }.padding(14).padding(.bottom, 32)
        }.diaryScreenBackground().navigationTitle(SearchBrowseShelf.themes.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }
}

private struct SearchThemeCard: View {
    let theme: SearchBrowseTheme
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 92

    var body: some View {
        let style = theme.style
        NavigationLink(value: SearchBrowseRoute.theme(theme)) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: style.icon).font(.title3.weight(.semibold))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Text(style.title).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(.white).padding(12).frame(height: height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    LinearGradient(colors: [Color(webHex: style.start), Color(webHex: style.end)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }.clipShape(RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.springPress).accessibilityIdentifier("search-theme-" + theme.rawValue)
    }
}

struct SearchPeopleShelf: View {
    let shelf: SearchBrowseShelf
    @Environment(DiaryStore.self) private var store
    @State private var popular: [SearchBrowsePerson] = []
    @State private var loadedRevision: UUID?

    private var people: [SearchBrowsePerson] {
        let ids = Set(popular.map(\.id))
        let selections = SearchBrowsePerson.selections(for: shelf)
        return popular + selections.filter { !ids.contains($0.id) }.prefix(max(0, 8 - popular.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchBrowseHeading(shelf: shelf, destination: .people(shelf, people))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(people.prefix(8)) { person in
                        SearchBrowsePersonLink(person: person)
                            .containerRelativeFrame(.horizontal) { width, _ in min(130, width * 0.27) }
                    }
                }.padding(.horizontal, 14)
            }.padding(.horizontal, -14).scrollIndicators(.hidden)
        }.task(id: store.sessionRevision) {
            let revision = store.sessionRevision
            guard revision != loadedRevision else { return }
            let result = await SearchBrowsePerson.popular(for: shelf, store: store)
            guard !Task.isCancelled, revision == store.sessionRevision else { return }
            popular = result
            loadedRevision = revision
        }
    }
}

struct SearchPeopleGrid: View {
    let shelf: SearchBrowseShelf
    let people: [SearchBrowsePerson]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                     count: typeSize.isAccessibilitySize ? 2 : 3), spacing: 18) {
                ForEach(people) { SearchBrowsePersonLink(person: $0) }
            }.padding(14).padding(.bottom, 32)
        }.diaryScreenBackground().navigationTitle(shelf.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }
}

private struct SearchBrowsePersonLink: View {
    let person: SearchBrowsePerson
    @Environment(DiaryStore.self) private var store
    @State private var image: String?

    var body: some View {
        NavigationLink(value: PersonRoute(id: person.id)) {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear.aspectRatio(2 / 3, contentMode: .fit)
                    .overlay { Artwork(path: person.image ?? image, title: person.name, alignment: .top) }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                ProfileCardCaption(title: person.name)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.springPress)
            .task {
                guard person.image == nil, image == nil, !store.isPreview, let token = TMDBDirect.token(store) else { return }
                if let reply = try? await TMDBDirect.object("person/\(person.id)", query: [:], token: token), !Task.isCancelled {
                    image = CatalogTools.image(reply["profile_path"] as? String, size: "w185")
                }
            }
    }
}

struct SearchFranchisesShelf: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchBrowseHeading(shelf: .franchises)
            Text("Curated collections").font(.subheadline).foregroundStyle(HomeStyle.secondary)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(SearchBrowseFranchise.collections.prefix(6)) { franchise in
                        SearchFranchiseLink(franchise: franchise)
                            .containerRelativeFrame(.horizontal) { width, _ in min(215, width * 0.44) }
                    }
                }.padding(.horizontal, 14)
            }.padding(.horizontal, -14).scrollIndicators(.hidden)
        }
    }
}

struct SearchFranchiseGrid: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                ForEach(SearchBrowseFranchise.collections) { SearchFranchiseLink(franchise: $0) }
            }.padding(14).padding(.bottom, 32)
        }.diaryScreenBackground().navigationTitle(SearchBrowseShelf.franchises.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }
}

private struct SearchFranchiseLink: View {
    let franchise: SearchBrowseFranchise
    @Environment(DiaryStore.self) private var store
    @State private var posters: [String] = []

    var body: some View {
        NavigationLink(value: SearchBrowseRoute.franchise(franchise)) {
            CanvasListCard(title: franchise.title, posters: posters)
        }.buttonStyle(.springPress)
            .accessibilityIdentifier("search-franchise-\(franchise.id)")
            .task {
                guard posters.isEmpty, let collection = try? await franchise.load(store: store), !Task.isCancelled else { return }
                posters = Array(collection.parts.compactMap(\.posterPath).prefix(3))
            }
    }
}

struct SearchFranchisePage: View {
    let franchise: SearchBrowseFranchise
    @Environment(DiaryStore.self) private var store
    @State private var collection: TitleCollection?
    @State private var failure: String?

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            Group {
                if let collection {
                    if collection.parts.isEmpty {
                        ContentUnavailableView("No titles in this collection", systemImage: "film")
                    } else {
                        CatalogGrid(items: collection.parts, showsLayoutToggle: false, forceGrid: true)
                    }
                } else if let failure {
                    RetryNotice(message: failure) { Task { await load() } }
                } else {
                    DiaryLoadingPlaceholder(label: "Loading collection", layout: .posterGrid(columns: 3, rows: 2))
                }
            }.padding(14).padding(.bottom, 32)
        }.diaryScreenBackground().navigationTitle(franchise.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task { if collection == nil { await load() } }
    }

    private func load() async {
        failure = nil
        do { collection = try await franchise.load(store: store) }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}
