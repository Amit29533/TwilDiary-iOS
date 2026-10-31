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
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @State private var character: AniCharacterDetail?
    @State private var failure: String?
    var body: some View {
        Group {
            if let character {
                let biography = ProfileFormattedBiography(description: character.description, hideSpoilers: hideSpoilers)
                PersonProfilePage(name: character.name, nativeName: character.native, role: "Character", image: character.image,
                                  kind: .character, ref: character.id, favouriteSubtitle: character.appearances.first.map { "In " + $0.title },
                                  identifier: "character", source: .aniList(URL(string: "https://anilist.co/character/\(character.id)")!)) {
                    VStack(alignment: .leading, spacing: 18) {
                        if let source = route.sourceTitle {
                            Button("In " + source) { dismiss() }.font(.subheadline).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44, alignment: .leading).buttonStyle(.plain).foregroundStyle(.primary)
                        }
                        details(character, biography: biography)
                        ProfileAbout(content: biography, excludingFacts: ["height", "blood-type"])
                        ProfileWatchedShelf(appearances: character.appearances)
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
    private func details(_ character: AniCharacterDetail, biography: ProfileFormattedBiography) -> some View {
        let height = biography.facts.first { $0.id == "height" }?.markdown
        let blood = character.bloodType ?? biography.facts.first { $0.id == "blood-type" }?.markdown
        let facts = [
            ProfileFact(id: "character-birthday", icon: "calendar", label: "Birthday", value: character.birthday.map(ProfileDate.short)),
            ProfileFact(id: "character-age", icon: "person", label: "Age", value: character.age),
            ProfileFact(id: "character-gender", icon: "person.text.rectangle", label: "Gender", value: character.gender),
            ProfileFact(id: "character-height", icon: "ruler", label: "Height", value: height),
            ProfileFact(id: "character-blood-type", icon: "drop", label: "Blood type", value: blood)
        ].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 12) {
            ProfileFacts(items: facts)
            ProfileAliases(values: character.alternative, excluding: [character.name] + [character.native].compactMap { $0 })
            if let count = ProfileText.favourites(character.favourites) { ProfileSecondaryText(text: count) }
        }
    }
    private func voicedBy(_ actors: [AniPerson]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voiced by").font(.title3.weight(.semibold))
            ProfileShelf {
                ForEach(actors, id: \.id) { actor in
                    NavigationLink(value: VoiceActorRoute(id: actor.id, name: actor.name)) {
                        if typeSize.isAccessibilitySize {
                            ProfileMediaRow(image: actor.image, name: actor.name, detail: "Japanese")
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Artwork(path: actor.image, title: actor.name).frame(width: 96, height: 136).clipShape(RoundedRectangle(cornerRadius: 12))
                                ProfileCardCaption(title: actor.name)
                                Text("Japanese").font(.caption).foregroundStyle(.secondary)
                            }.frame(width: 96, alignment: .leading).accessibilityElement(children: .combine)
                        }
                    }.buttonStyle(.springPress).accessibilityIdentifier("voice-actor-\(actor.id)")
                }
            }
        }
    }
    private func appearsIn(_ items: [AniAppearance]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appears in").font(.title3.weight(.semibold))
            ProfileShelf {
                ForEach(items) { item in
                    AnimeAppearanceButton(appearance: item) {
                        let detail = [item.year.map(String.init), item.role == "MAIN" ? "Main" : item.role == "SUPPORTING" ? "Supporting" : nil].compactMap { $0 }.joined(separator: " · ")
                        if typeSize.isAccessibilitySize {
                            ProfileMediaRow(image: item.cover, name: item.title, detail: detail, score: item.rating, provider: "AniList")
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Artwork(path: item.cover, title: item.title).frame(width: 104, height: 156).clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(alignment: .bottomLeading) {
                                        if let score = item.rating, score > 0 {
                                            HStack(spacing: 3) { RatingBadge(score: score); Text("AniList").font(.system(size: 9)) }
                                                .padding(4).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6)).padding(4)
                                        }
                                    }
                                ProfileCardCaption(title: item.title)
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }.frame(width: 104, alignment: .leading).contentShape(Rectangle())
                        }
                    }.buttonStyle(.springPress).accessibilityIdentifier("anime-appearance-\(item.id)")
                }
            }
        }
    }
    private func load() async {
        failure = nil
        #if DEBUG
        if store.isPreview { character = ProfileFormattingPreview.enabled ? (ProfileFormattingPreview.character(route.id) ?? AniListPreview.detail(route.id)) : AniListPreview.detail(route.id); return }
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
/// (cast/voice actors from the diary; characters from AniList) above the ones
/// you've hearted, as posters. "Favourites" titles the page; the tabs are its first row.
struct FavouritesView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("favouritesTab") private var tab = Favourite.Kind.character
    @AppStorage("favouritesCastGrid") private var castGrid = true
    @AppStorage("favouritesCharactersGrid") private var charactersGrid = true
    @AppStorage("favouritesVoiceGrid") private var voiceGrid = true
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
            HStack(spacing: 9) {
                Image(systemName: "heart.fill").foregroundStyle(theme.accent).accessibilityHidden(true)
                Text("Hearted").font(.system(size: 20, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("favourites-hearted-heading")
                Spacer(minLength: 4)
                CollectionLayoutToggle(grid: grid, collection: "favourites")
            }.padding(.horizontal, 14).padding(.top, 20)
            if items.isEmpty {
                DiaryEmptyState(title: "No favourite " + tab.label.lowercased() + " yet", description: emptyHint)
                    .padding(.horizontal, 14).padding(.top, 12)
            } else {
                LazyVGrid(columns: grid.wrappedValue ? Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3) : [GridItem(.flexible())], spacing: 18) {
                    ForEach(items) { item in FavouriteLink(item: item, poster: grid.wrappedValue, row: !grid.wrappedValue) }
                }.padding(.horizontal, 14).padding(.top, 8)
            }
        }.contentMargins(.bottom, 100, for: .scrollContent).diaryScreenBackground().navigationTitle("Favourites").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .tint(Color(webHex: "#e6e2ec"))
            .task { await favourites.sync(store: store) }
            .refreshable { await favourites.sync(store: store) }
    }
    private var grid: Binding<Bool> {
        switch tab {
        case .cast: $castGrid
        case .character: $charactersGrid
        case .voice: $voiceGrid
        }
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
    var row = false
    /// Home uses portraits while retaining these same provider-specific navigation links.
    var homeCard = false
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
        if homeCard {
            HomeFavouriteCard(item: item)
        } else if row {
            HStack(spacing: 12) {
                Artwork(path: item.image, title: item.name).frame(width: 56, height: 84).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                    Text(item.subtitle ?? item.kind.singular).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(10).background(Color(webHex: "#121116"), in: RoundedRectangle(cornerRadius: 14))
                .multilineTextAlignment(.leading).contentShape(Rectangle()).accessibilityElement(children: .combine)
        } else if poster {
            VStack(alignment: .leading, spacing: 6) {
                Artwork(path: item.image, title: item.name).aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)))
                Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).foregroundStyle(.primary)
                Text(item.subtitle ?? item.kind.singular).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.multilineTextAlignment(.leading).accessibilityElement(children: .combine)
        } else {
            HomeFavouriteCard(item: item).frame(width: size + 18)
        }
    }
}
