import SwiftUI
import TwilDiaryCore

/// Opens an anime character's page (AniList).
struct CharacterRoute: Hashable {
    let id: Int
    var sourceTitle: String? = nil
}

/// Anime pages: the characters first (AniList), each with their Japanese voice actor under them;
/// the voice-actor Cast row from TMDB follows as before.
struct AnimeCharactersRow: View {
    let title: String
    let year: Int?
    let movie: Bool
    var tmdbID: Int? = nil
    @Environment(DiaryStore.self) private var store
    @State private var characters: [AniCharacter] = []
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !characters.isEmpty {
                Text("Characters").font(.system(size: 20, weight: .semibold))
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(characters) { character in
                            NavigationLink(value: CharacterRoute(id: character.id, sourceTitle: title)) { card(character) }
                                .buttonStyle(.springPress).accessibilityIdentifier("anime-character-\(character.id)")
                        }
                    }
                }.scrollIndicators(.hidden).scrollClipDisabled()
            } else if failed {
                Button("Characters didn’t load · Retry") { Task { await load() } }.font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }.task(id: title) { await load() }
    }
    private func card(_ character: AniCharacter) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(path: character.image, title: character.name).frame(width: 96, height: 136).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if character.role == "MAIN" {
                        Text("Main").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).frame(height: 18).background(.black.opacity(0.55), in: Capsule()).padding(6)
                    }
                }
            Text(character.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).foregroundStyle(.primary)
            if let actor = character.voiceActor {
                Text(actor.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(width: 96, alignment: .leading).multilineTextAlignment(.leading)
            .accessibilityElement(children: .combine)
    }
    private func load() async {
        failed = false
        #if DEBUG
        if store.isPreview { characters = AniListPreview.characters; return }
        #endif
        do { characters = try await AniListClient.shared.characters(title: title, year: year, movie: movie, tmdbID: tmdbID) }
        catch { if !Task.isCancelled { failed = true } }
    }
}

/// The same profile shell as cast and voice actors, retaining character-only facts and routes.
struct CharacterView: View {
    let route: CharacterRoute
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @State private var character: AniCharacterDetail?
    @State private var failure: String?
    @State private var expanded = false
    var body: some View {
        Group {
            if let character {
                PersonProfilePage(name: character.name, nativeName: character.native, role: "Character", image: character.image,
                                  kind: .character, ref: character.id, favouriteSubtitle: character.appearances.first.map { "In " + $0.title },
                                  identifier: "character") {
                    VStack(alignment: .leading, spacing: 22) {
                        details(character)
                        if let source = route.sourceTitle {
                            Button("In " + source) { dismiss() }.font(.system(size: 15)).buttonStyle(.plain).foregroundStyle(.primary)
                        }
                        let biography = ProfileBiographyContent(description: character.description, hideSpoilers: hideSpoilers)
                        let source = ProfileWebsiteLink(url: URL(string: "https://anilist.co/character/\(character.id)")!, title: "AniList")!
                        ProfileWebsiteButtons(links: biography.links.contains(where: { $0.id == source.id }) ? biography.links : biography.links + [source])
                        ProfileBiography(text: AniListText.formatted(biography.markdown, hideSpoilers: hideSpoilers), expanded: $expanded)
                        if !character.voiceActors.isEmpty { voicedBy(character.voiceActors) }
                        if !character.appearances.isEmpty { appearsIn(character.appearances) }
                    }
                }
            } else {
                ScrollView {
                    if let failure { RetryNotice(message: failure) { Task { await load() } }.padding(14) }
                    else { DiaryLoadingPlaceholder(height: 310, label: "Loading character").padding(14) }
                }.diaryScreenBackground().navigationTitle("").toolbar(.visible, for: .navigationBar)
            }
        }.task(id: route.id) { if character == nil { await load() } }
    }
    private func details(_ character: AniCharacterDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                if let birthday = character.birthday { ProfileDetailChip(icon: "calendar", label: "Birthday", value: ProfileDate.short(birthday)) }
                if let age = character.age { ProfileDetailChip(icon: "person", label: "Age", value: age) }
                if let gender = character.gender { ProfileDetailChip(icon: "person.text.rectangle", label: "Gender", value: gender) }
            }
            if let blood = character.bloodType { ProfileDetailLine(label: "Blood type", value: blood) }
            if !character.alternative.isEmpty { ProfileDetailLine(label: "Also known as", value: character.alternative.joined(separator: " · ")) }
            if let count = character.favourites { Text(count.formatted() + " favourites on AniList").font(.subheadline).foregroundStyle(.secondary) }
        }
    }
    private func voicedBy(_ actors: [AniPerson]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voiced by").font(.system(size: 20, weight: .semibold))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(actors, id: \.id) { actor in
                        // Opens the voice actor's page: their other characters and a heart.
                        NavigationLink(value: VoiceActorRoute(id: actor.id, name: actor.name)) {
                            VStack(spacing: 8) {
                                Artwork(path: actor.image, title: actor.name).frame(width: 82, height: 82).clipShape(Circle())
                                Text(actor.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).foregroundStyle(.primary)
                                Text("Japanese").font(.caption).foregroundStyle(.secondary)
                            }.frame(width: 100).multilineTextAlignment(.center).accessibilityElement(children: .combine)
                        }.buttonStyle(.springPress).accessibilityIdentifier("voice-actor-\(actor.id)")
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }
    private func appearsIn(_ items: [AniAppearance]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appears in").font(.system(size: 20, weight: .semibold))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        AnimeAppearanceButton(appearance: item) {
                            VStack(alignment: .leading, spacing: 6) {
                                Artwork(path: item.cover, title: item.title).frame(width: 104, height: 152).clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).foregroundStyle(.primary)
                                Text([item.year.map(String.init), item.role == "MAIN" ? "Main" : item.role == "SUPPORTING" ? "Supporting" : nil].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(width: 104, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.springPress).accessibilityIdentifier("anime-appearance-\(item.id)")
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }
    private func load() async {
        failure = nil
        #if DEBUG
        if store.isPreview { character = AniListPreview.detail(route.id); return }
        #endif
        do {
            let result = try await AniListClient.shared.character(route.id)
            try Task.checkCancellation()
            character = result
        }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

/// Favourites: cast, characters and voice actors, each tab laid out the same way: "Most watched"
/// (cast from your diary; characters and voice actors from your AniList profile) above the ones
/// you've hearted, as posters. "Favourites" titles the page; the tabs are its first row.
struct FavouritesView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("favouritesTab") private var tab = Favourite.Kind.character
    private var favourites: FavouritesStore { .shared }
    var body: some View {
        let items = favourites.items(tab)
        ScrollView {
            tabs.padding(.top, 4)
            Group {
                switch tab {
                case .cast: MostWatchedCast(kind: .cast)
                case .character: AniListMostWatched(kind: .characters)
                case .voice: MostWatchedCast(kind: .voice)
                }
            }.id(tab).padding(.horizontal, 14).padding(.top, 8)
            if !items.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "heart.fill").foregroundStyle(theme.accent).accessibilityHidden(true)
                    Text("Hearted")
                }.font(.system(size: 20, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.top, 20)
                    .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            }
            if items.isEmpty {
                DiaryEmptyState(title: "No favourite " + tab.label.lowercased() + " yet", description: emptyHint)
                    .padding(.horizontal, 14).padding(.top, 24)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 18) {
                    ForEach(items) { item in FavouriteLink(item: item, poster: true) }
                }.padding(.horizontal, 14).padding(.top, 8)
            }
        }.contentMargins(.bottom, 100, for: .scrollContent).diaryScreenBackground().navigationTitle("Favourites").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .task { await favourites.sync(store: store) }
            .refreshable { await favourites.sync(store: store) }
    }
    private var emptyHint: String {
        switch tab {
        case .cast: "Tap the heart on someone’s cast page to keep them here."
        case .character: "Tap the heart on an anime character’s page to keep them here."
        case .voice: "Tap the heart on a voice actor’s page to keep them here."
        }
    }
    /// Three tabs scroll sideways on narrow phones rather than squeezing.
    private var tabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 18) {
                ForEach(Favourite.Kind.allCases, id: \.self) { kind in
                    Button { tab = kind } label: {
                        Text(kind.label).font(.system(size: 24, weight: .bold)).tracking(-0.6)
                            .foregroundStyle(tab == kind ? Color(webHex: "#f3f0f7") : .white.opacity(0.4))
                    }.buttonStyle(.plain).accessibilityAddTraits(tab == kind ? .isSelected : []).accessibilityIdentifier("favourites-tab-" + kind.rawValue)
                }
            }.padding(.horizontal, 14)
        }.scrollIndicators(.hidden)
    }
}

/// One favourite, opening their cast, character or voice actor page: a poster on the Favourites
/// page, a round portrait in Home's compact row.
struct FavouriteLink: View {
    let item: Favourite
    var size: CGFloat = 82
    var poster = false
    var body: some View {
        Group {
            switch item.kind {
            case .cast: NavigationLink(value: PersonRoute(id: item.ref)) { label }
            case .character: NavigationLink(value: CharacterRoute(id: item.ref)) { label }
            case .voice: NavigationLink(value: VoiceActorRoute(id: item.ref, name: item.name)) { label }
            }
        }.buttonStyle(.springPress).accessibilityIdentifier("favourite-" + item.id)
    }
    @ViewBuilder private var label: some View {
        if poster {
            VStack(alignment: .leading, spacing: 6) {
                Artwork(path: item.image, title: item.name).aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)))
                Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).foregroundStyle(.primary)
                Text(item.subtitle ?? item.kind.singular).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.multilineTextAlignment(.leading).accessibilityElement(children: .combine)
        } else {
            VStack(spacing: 8) {
                Artwork(path: item.image, title: item.name).frame(width: size, height: size).clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).foregroundStyle(.primary)
                Text(item.kind.singular).font(.caption).foregroundStyle(.secondary)
            }.frame(width: size + 18).multilineTextAlignment(.center).accessibilityElement(children: .combine)
        }
    }
}
