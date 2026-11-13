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
    /// The show page's "See all" (its Cast and characters page).
    var seeAll: ShowPageRoute? = nil
    @Environment(DiaryStore.self) private var store
    @State private var characters: [AniCharacter] = []
    @State private var failed = false
    @Environment(AppRouter.self) private var router
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !characters.isEmpty {
                HStack {
                    Text("Characters").font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
                    Spacer(minLength: 8)
                    if let seeAll { SeeAllLink(value: seeAll, identifier: "title-characters-all") }
                }.frame(minHeight: 44)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
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
        // Design: 111 x 148 (radius 18); "Main" 11 pt bold #cdbbff on a dark 22 pt pill, 8 pt in.
        VStack(alignment: .leading, spacing: 0) {
            Artwork(path: character.image, title: character.name).frame(width: 111, height: 148).clipShape(RoundedRectangle(cornerRadius: 18))
                // Press and hold to peek at the picture; a tap still opens the character.
                .fullScreenArtwork(character.image, title: character.name) {
                    router.paths[router.selectedTab, default: NavigationPath()].append(CharacterRoute(id: character.id, sourceTitle: title))
                }
                .overlay(alignment: .topLeading) {
                    if character.role == "MAIN" {
                        Text("Main").font(.system(size: 11, weight: .bold)).foregroundStyle(HomeStyle.chipText).padding(.horizontal, 8).frame(height: 22)
                            .background(HomeStyle.card.opacity(0.82), in: Capsule()).padding(8)
                    }
                }
            Text(character.name).font(.system(size: 14, weight: .semibold)).lineLimit(2).foregroundStyle(HomeStyle.primary).padding(.top, 11)
            if let actor = character.voiceActor {
                Text(actor.name).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1).padding(.top, 3)
            }
        }.frame(width: 111, alignment: .leading).multilineTextAlignment(.leading)
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
    /// MyAnimeList's pictures of this character, after AniList's own.
    @State private var morePhotos: [PersonPhoto] = []
    var body: some View {
        Group {
            if let character {
                let biography = ProfileFormattedBiography(description: character.description, hideSpoilers: hideSpoilers)
                PersonProfilePage(name: character.name, nativeName: character.native, role: "Character", image: character.image,
                                  kind: .character, ref: character.id, favouriteSubtitle: character.appearances.first.map { "In " + $0.title },
                                  identifier: "character", heroFacts: characterFacts(character, biography: biography),
                                  photos: ProfilePhotoSources.merge(character.image.map { [PersonPhoto(path: $0, kind: "portrait", aspectRatio: 2.0 / 3.0, title: nil)] } ?? [], morePhotos),
                                  backdrop: character.appearances.lazy.compactMap { $0.banner }.first ?? character.appearances.first(where: { $0.cover != nil })?.cover) {
                    VStack(alignment: .leading, spacing: 18) {
                        if let source = ProfileText.line(route.sourceTitle) {
                            ProfileSourceRow(title: source) { dismiss() }.accessibilityIdentifier("character-source")
                        }
                        Text("About").font(.system(size: 24, weight: .bold)).tracking(-0.5).foregroundStyle(HomeStyle.primary).accessibilityAddTraits(.isHeader)
                        details(character, biography: biography)
                        ProfileAbout(content: biography, excludingFacts: ["height", "blood-type"],
                                     additionalLinks: [ProfileWebsiteLink(url: URL(string: "https://anilist.co/character/\(character.id)")!, title: "AniList")].compactMap { $0 })
                        ProfileWatchedShelf(appearances: character.appearances)
                        if !character.voiceActors.isEmpty { voicedBy(character.voiceActors) }
                        if !character.appearances.isEmpty { appearsIn(character.appearances) }
                    }
                }
            } else {
                EdgeToEdgeScroll {
                    if let failure { RetryNotice(message: failure) { Task { await load() } }.padding(14) }
                    else { DiaryLoadingPlaceholder(height: 310, label: "Loading character").padding(14) }
                }.diaryScreenBackground().navigationTitle("").toolbar(.visible, for: .navigationBar)
            }
        }.task(id: route.id) { if character == nil { await load() } }
            .task(id: character?.id ?? 0) {
                #if DEBUG
                if store.isPreview { return }
                #endif
                guard let character else { return }
                let found = await ProfilePhotoSources.shared.character(name: character.name, native: character.native,
                                                                       anime: character.appearances.prefix(6).flatMap(\.names))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth) { morePhotos = found }
            }
    }
    /// Every fact AniList has (some characters have many, some none); the first three sit beside the picture.
    private func characterFacts(_ character: AniCharacterDetail, biography: ProfileFormattedBiography) -> [ProfileFact] {
        let height = biography.facts.first { $0.id == "height" }?.markdown
        let blood = character.bloodType ?? biography.facts.first { $0.id == "blood-type" }?.markdown
        return [
            ProfileFact(id: "character-birthday", icon: "calendar", label: "Birthday", value: character.birthday.map(ProfileDate.short)),
            ProfileFact(id: "character-age", icon: "person", label: "Age", value: character.age),
            ProfileFact(id: "character-gender", icon: "person.text.rectangle", label: "Gender", value: character.gender),
            ProfileFact(id: "character-favourites", icon: "heart", label: "Favourites", value: ProfileText.favouritesValue(character.favourites)),
            ProfileFact(id: "character-height", icon: "ruler", label: "Height", value: height),
            ProfileFact(id: "character-blood-type", icon: "drop", label: "Blood type", value: blood)
        ].compactMap { $0 }
    }
    private func details(_ character: AniCharacterDetail, biography: ProfileFormattedBiography) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProfileAliases(values: character.alternative, excluding: [character.name] + [character.native].compactMap { $0 })
        }
    }
    private func voicedBy(_ actors: [AniPerson]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voiced by").font(.system(size: 24, weight: .bold)).tracking(-0.5).foregroundStyle(HomeStyle.primary)
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
            Text("Appears in").font(.system(size: 24, weight: .bold)).tracking(-0.5).foregroundStyle(HomeStyle.primary)
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
                                            RatingBadge(score: score, source: "AniList").padding(5)
                                                .accessibilityIdentifier("character-appearance-rating-\(item.id)")
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
            // One Wikidata request links every anime below to TMDB, so a tap usually opens at once.
            Task { await WikidataAnime.shared.routes(result.appearances.map { WikidataAnime.Anime(id: $0.id, format: $0.format) }) }
        }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

/// Favourites: cast, characters and voice actors, each tab laid out the same way: "Most watched"
/// (cast/voice actors from the diary; characters from AniList) above the ones
/// you've hearted, as posters. "Favourites" titles the page; the tabs are its first row.
struct FavouritesView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("favouritesTab") private var tab = Favourite.Kind.character
    @AppStorage("favouritesCastGrid") private var castGrid = true
    @AppStorage("favouritesCharactersGrid") private var charactersGrid = true
    @AppStorage("favouritesVoiceGrid") private var voiceGrid = true
    /// recent, oldest or name.
    @AppStorage("favouritesSort") private var sort = "recent"
    @State private var query = ""
    private var favourites: FavouritesStore { .shared }
    var body: some View {
        let all = favourites.items(tab)
        let needle = query.trimmingCharacters(in: .whitespaces)
        let matching = needle.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        let items: [Favourite] = switch sort {
        case "name": matching.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case "oldest": matching.sorted { $0.savedAt < $1.savedAt }
        default: matching.sorted { $0.savedAt > $1.savedAt }
        }
        EdgeToEdgeScroll(frosted: true) {
            tabs.padding(.horizontal, 16).padding(.top, 4)
            Group {
                switch tab {
                case .cast: MostWatchedCast(kind: .cast)
                case .character: AniListMostWatched(kind: .characters)
                case .voice: MostWatchedCast(kind: .voice)
                }
            }.id(tab).padding(.horizontal, 16).padding(.top, 14)
            HStack(spacing: 10) {
                Image(systemName: "heart.fill").font(.system(size: 20)).foregroundStyle(HomeStyle.chipText).accessibilityHidden(true)
                Text("Hearted").font(.system(size: 26, weight: .bold)).tracking(-0.4).foregroundStyle(HomeStyle.primary).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("favourites-hearted-heading")
                if !all.isEmpty {
                    Text(all.count.formatted()).font(.system(size: 13, weight: .bold)).foregroundStyle(HomeStyle.chipText).monospacedDigit()
                        .frame(minWidth: 26).padding(.horizontal, 4).frame(height: 26).background(HomeStyle.chip, in: Capsule())
                }
                Spacer(minLength: 4)
                layoutSwitch
            }.padding(.horizontal, 16).padding(.top, 26)
            if !all.isEmpty {
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(HomeStyle.secondary)
                        TextField("Search hearted", text: $query).font(.system(size: 16)).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("favourites-search")
                    }.padding(.horizontal, 16).frame(height: 46).background(HomeStyle.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: 1))
                    Menu {
                        Picker("Order", selection: $sort) {
                            Text("Recently hearted").tag("recent"); Text("Oldest first").tag("oldest"); Text("A–Z").tag("name")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.arrow.down").font(.system(size: 13, weight: .bold))
                            Text(sort == "name" ? "A–Z" : sort == "oldest" ? "Oldest" : "Recent").lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).opacity(0.8)
                        }.font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.chipText).fixedSize()
                            .padding(.horizontal, 14).frame(height: 46).background(HomeStyle.chip, in: Capsule()).contentShape(Capsule())
                    }.accessibilityLabel("Order").accessibilityIdentifier("favourites-sort")
                }.padding(.horizontal, 16).padding(.top, 12)
            }
            if items.isEmpty {
                DiaryEmptyState(title: all.isEmpty ? "No favourite " + tab.label.lowercased() + " yet" : "No hearted " + tab.label.lowercased() + " match", description: all.isEmpty ? emptyHint : "Try another name.")
                    .padding(.horizontal, 16).padding(.top, 12)
            } else {
                LazyVGrid(columns: grid.wrappedValue ? Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3) : [GridItem(.flexible())], spacing: grid.wrappedValue ? 18 : 12) {
                    ForEach(items) { item in FavouriteLink(item: item, poster: grid.wrappedValue, row: !grid.wrappedValue, hearts: true) }
                }.padding(.horizontal, 16).padding(.top, 12)
            }
        }.contentMargins(.bottom, 100, for: .scrollContent).diaryScreenBackground().navigationTitle("Favourites").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .tint(Color(webHex: "#e6e2ec"))
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
    /// Cast · Characters · Voice actors in one dark track; the chosen one is a sliding lilac pill.
    private var tabs: some View {
        let kinds = Favourite.Kind.allCases
        let index = CGFloat(kinds.firstIndex(of: tab) ?? 0)
        return HStack(spacing: 4) {
            ForEach(kinds, id: \.self) { kind in
                let on = tab == kind
                // The page swaps at once (no cross-fade through a half-blank page); only the pill slides.
                Button { tab = kind } label: {
                    Text(kind.label).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(on ? Color(webHex: "#1a1030") : Color(webHex: "#c5c0cf"))
                        .animation(.snappy(duration: 0.28), value: on)
                        .frame(maxWidth: .infinity).frame(height: 40).contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : []).accessibilityIdentifier("favourites-tab-" + kind.rawValue)
            }
        }.background(alignment: .leading) {
            // One pill that moves between the tabs, so it's never missing mid-switch.
            GeometryReader { proxy in
                let width = (proxy.size.width - 4 * CGFloat(kinds.count - 1)) / CGFloat(kinds.count)
                Capsule().fill(LinearGradient(colors: [Color(webHex: "#cdbbff"), Color(webHex: "#a98bff")], startPoint: .top, endPoint: .bottom))
                    .frame(width: width, height: 40).offset(x: (width + 4) * index)
                    .animation(.snappy(duration: 0.28), value: index)
            }
        }.padding(4).background(HomeStyle.card, in: Capsule()).overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: 1))
    }
    /// Grid · list as two icons in one small track.
    private var layoutSwitch: some View {
        HStack(spacing: 2) {
            ForEach([true, false], id: \.self) { isGrid in
                let on = grid.wrappedValue == isGrid
                Button { withAnimation(.smooth(duration: 0.28)) { grid.wrappedValue = isGrid } } label: {
                    Image(systemName: isGrid ? "square.grid.2x2" : "list.bullet").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(on ? HomeStyle.chipText : HomeStyle.secondary)
                        .frame(width: 40, height: 34).background { if on { Capsule().fill(HomeStyle.chip) } }.contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityLabel(isGrid ? "Show favourites as grid" : "Show favourites as list")
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
        }.padding(3).background(HomeStyle.card, in: Capsule()).overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: 1))
            .frame(minHeight: 44)
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
    /// Favourites page: a filled heart on each card (tap to remove).
    var hearts = false
    var body: some View {
        Group {
            switch item.kind {
            case .cast: NavigationLink(value: PersonRoute(id: item.ref)) { label }
            case .character: NavigationLink(value: CharacterRoute(id: item.ref)) { label }
            case .voice: NavigationLink(value: VoiceActorRoute(id: item.ref, name: item.name)) { label }
            }
        }.buttonStyle(.springPress).accessibilityIdentifier("favourite-" + item.id)
            .overlay(alignment: row ? .trailing : .topTrailing) {
                if hearts && (row || poster) {
                    FavouriteHeartButton(kind: item.kind, ref: item.ref, name: item.name, image: item.image, subtitle: item.subtitle,
                                         size: row ? 42 : 34, tinted: row)
                        .padding(row ? 12 : -2)
                }
            }
    }
    @ViewBuilder private var label: some View {
        if homeCard {
            HomeFavouriteCard(item: item)
        } else if row {
            HStack(spacing: 14) {
                Artwork(path: item.image, title: item.name, alignment: .top).frame(width: 56, height: 64).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.system(size: 17, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1).truncationMode(.tail)
                    Text(item.subtitle ?? item.kind.singular).font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).lineLimit(1).truncationMode(.tail)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if hearts { Color.clear.frame(width: 42, height: 1) }
                else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 14).padding(.vertical, 12)
                .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                .multilineTextAlignment(.leading).contentShape(Rectangle()).accessibilityElement(children: .combine)
        } else if poster {
            VStack(alignment: .leading, spacing: 4) {
                Color.clear.aspectRatio(0.83, contentMode: .fit)
                    .overlay { Artwork(path: item.image, title: item.name, alignment: .top) }
                    .clipShape(RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
                    .padding(.bottom, 6)
                Text(item.name).font(.system(size: 15, weight: .bold)).lineLimit(2).foregroundStyle(HomeStyle.primary)
                Text(item.subtitle ?? item.kind.singular).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1).truncationMode(.tail)
            }.multilineTextAlignment(.leading).accessibilityElement(children: .combine)
        } else {
            HomeFavouriteCard(item: item).frame(width: size + 18)
        }
    }
}
