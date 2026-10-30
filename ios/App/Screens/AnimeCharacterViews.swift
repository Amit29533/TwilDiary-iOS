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
        do { characters = try await AniListClient.shared.characters(title: title, year: year, movie: movie) }
        catch { if !Task.isCancelled { failed = true } }
    }
}

/// An anime character, laid out like a cast member's page: large art, names, a heart, the
/// description (spoilers left out while Hide spoilers is on), facts, voice actor and other anime.
struct CharacterView: View {
    let route: CharacterRoute
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var character: AniCharacterDetail?
    @State private var failure: String?
    @State private var expanded = false
    @State private var hearts = 0
    private var favourites: FavouritesStore { .shared }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if let character {
                    VStack(alignment: .leading, spacing: 28) {
                        header(character)
                        VStack(alignment: .leading, spacing: 28) {
                            if let source = route.sourceTitle { Button("In " + source) { dismiss() }.font(.system(size: 15)).buttonStyle(.plain) }
                            let text = character.readableDescription(hideSpoilers: hideSpoilers)
                            if !text.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(text).font(.system(size: 16)).lineSpacing(6).foregroundStyle(.secondary).lineLimit(expanded ? nil : 5)
                                    Button(expanded ? "Less" : "More") { expanded.toggle() }.font(.system(size: 14)).frame(minHeight: 36)
                                }
                            }
                            facts(character)
                            if !character.voiceActors.isEmpty { voicedBy(character.voiceActors) }
                            if !character.appearances.isEmpty { appearsIn(character.appearances) }
                            Link("Character details: AniList", destination: URL(string: "https://anilist.co/character/\(character.id)")!).font(.system(size: 13)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 14)
                    }.padding(.bottom, 28)
                        .background(alignment: .top) {
                            Artwork(path: character.image, title: character.name).frame(height: 310 + geometry.safeAreaInsets.top)
                                .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.2), location: 0), .init(color: .black.opacity(0.55), location: 0.55), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
                                .offset(y: -geometry.safeAreaInsets.top).allowsHitTesting(false).accessibilityHidden(true)
                        }
                } else if let failure { RetryNotice(message: failure) { Task { await load() } }.padding(14) }
                else { DiaryLoadingPlaceholder(height: 310, label: "Loading character").padding(14) }
            }.scrollClipDisabled().diaryScreenBackground().navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
                .task(id: route.id) { if character == nil { await load() } }
        }
    }
    private func header(_ character: AniCharacterDetail) -> some View {
        let saved = favourites.contains(.character, character.id)
        return HStack(spacing: 14) {
            Artwork(path: character.image, title: character.name).frame(width: 80, height: 80).clipShape(Circle()).overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 2))
            VStack(alignment: .leading, spacing: 4) {
                Text(character.name).font(.system(size: 26.4, weight: .semibold)).tracking(-1.1).lineLimit(2).minimumScaleFactor(0.8)
                if let native = character.native { Text(native).font(.system(size: 14)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Button {
                favourites.toggle(.character, ref: character.id, name: character.name, image: character.image,
                                  subtitle: character.appearances.first.map { "In " + $0.title }, store: store)
                if !saved { hearts += 1 }
            } label: { RoundTool(icon: "heart", tint: saved ? theme.accent : Color(webHex: "#c5c0cf")) }
                .buttonStyle(.springPress).starBurst(trigger: hearts).sensoryFeedback(.impact(weight: .light), trigger: saved)
                .accessibilityLabel(saved ? "Remove from favourites" : "Add to favourites").accessibilityIdentifier("character-favourite")
        }.padding(.horizontal, 14).padding(.top, 145).padding(.bottom, 10)
    }
    private func facts(_ character: AniCharacterDetail) -> some View {
        var rows: [(label: String, value: String)] = []
        if let gender = character.gender { rows.append(("Gender", gender)) }
        if let age = character.age { rows.append(("Age", age)) }
        if let birthday = character.birthday { rows.append(("Birthday", birthday)) }
        if let blood = character.bloodType { rows.append(("Blood type", blood)) }
        if !character.alternative.isEmpty { rows.append(("Also known as", character.alternative.joined(separator: " · "))) }
        if let count = character.favourites { rows.append(("Favourited by", count.formatted() + " on AniList")) }
        return VStack(alignment: .leading, spacing: 14) {
            if !rows.isEmpty {
                Text("Facts").font(.system(size: 20, weight: .semibold))
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        let row = rows[index]
                        HStack(alignment: .top, spacing: 16) {
                            Text(row.label).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
                            Text(row.value).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }.font(.system(size: 13)).padding(.vertical, 12)
                        Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 4).background(.white.opacity(0.016), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
            }
        }
    }
    private func voicedBy(_ actors: [AniPerson]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voiced by").font(.system(size: 20, weight: .semibold))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(actors, id: \.id) { actor in
                        VStack(spacing: 8) {
                            Artwork(path: actor.image, title: actor.name).frame(width: 82, height: 82).clipShape(Circle())
                            Text(actor.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            Text("Japanese").font(.caption).foregroundStyle(.secondary)
                        }.frame(width: 100).multilineTextAlignment(.center)
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
                        VStack(alignment: .leading, spacing: 6) {
                            Artwork(path: item.cover, title: item.title).frame(width: 104, height: 152).clipShape(RoundedRectangle(cornerRadius: 12))
                            Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            Text([item.year.map(String.init), item.role == "MAIN" ? "Main" : item.role == "SUPPORTING" ? "Supporting" : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(width: 104, alignment: .leading)
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
        do { character = try await AniListClient.shared.character(route.id) }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

/// Favourites: the cast and characters you've hearted. "Favourites" titles the page; the Cast and
/// Characters tabs sit under it as the first row.
struct FavouritesView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("favouritesTab") private var tab = Favourite.Kind.character
    private var favourites: FavouritesStore { .shared }
    var body: some View {
        let items = favourites.items(tab)
        ScrollView {
            tabs.padding(.horizontal, 14).padding(.top, 4)
            if items.isEmpty {
                DiaryEmptyState(title: tab == .cast ? "No favourite cast yet" : "No favourite characters yet",
                                description: tab == .cast ? "Tap the heart on someone’s cast page to keep them here." : "Tap the heart on an anime character’s page to keep them here.")
                    .padding(.horizontal, 14).padding(.top, 24)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 18) {
                    ForEach(items) { item in FavouriteLink(item: item, size: 96) }
                }.padding(.horizontal, 14).padding(.top, 8)
            }
        }.padding(.bottom, 100).diaryScreenBackground().navigationTitle("Favourites").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .task { await favourites.sync(store: store) }
            .refreshable { await favourites.sync(store: store) }
    }
    private var tabs: some View {
        HStack(spacing: 18) {
            ForEach([Favourite.Kind.cast, .character], id: \.self) { kind in
                Button { tab = kind } label: {
                    Text(kind == .cast ? "Cast" : "Characters").font(.system(size: 24, weight: .bold)).tracking(-0.6)
                        .foregroundStyle(tab == kind ? Color(webHex: "#f3f0f7") : .white.opacity(0.4))
                }.buttonStyle(.plain).accessibilityAddTraits(tab == kind ? .isSelected : []).accessibilityIdentifier("favourites-tab-" + kind.rawValue)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One favourite: round portrait and name, opening their cast or character page.
struct FavouriteLink: View {
    let item: Favourite
    var size: CGFloat = 82
    var body: some View {
        Group {
            if item.kind == .cast { NavigationLink(value: PersonRoute(id: item.ref)) { label } }
            else { NavigationLink(value: CharacterRoute(id: item.ref)) { label } }
        }.buttonStyle(.springPress).accessibilityIdentifier("favourite-" + item.id)
    }
    private var label: some View {
        VStack(spacing: 8) {
            Artwork(path: item.image, title: item.name).frame(width: size, height: size).clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12)))
            Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).foregroundStyle(.primary)
            Text(item.kind == .cast ? "Cast" : "Character").font(.caption).foregroundStyle(.secondary)
        }.frame(width: size + 18).multilineTextAlignment(.center).accessibilityElement(children: .combine)
    }
}
