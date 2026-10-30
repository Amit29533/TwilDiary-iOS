import SwiftUI
import TwilDiaryCore

/// Opens a voice actor's page (AniList staff).
struct VoiceActorRoute: Hashable {
    let id: Int
    /// From your AniList stats: how many of your anime they voice in.
    var watchedCount: Int? = nil
}

/// A voice actor, laid out like a character's page: large art, names, a heart, the bio (spoilers
/// left out while Hide spoilers is on), facts and the characters they voice, each opening its page.
struct VoiceActorView: View {
    let route: VoiceActorRoute
    @Environment(DiaryStore.self) private var store
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var actor: AniVoiceActorDetail?
    @State private var failure: String?
    @State private var expanded = false
    @State private var hearts = 0
    private var favourites: FavouritesStore { .shared }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if let actor {
                    VStack(alignment: .leading, spacing: 28) {
                        header(actor)
                        VStack(alignment: .leading, spacing: 28) {
                            if let count = route.watchedCount {
                                Text("In " + count.counted("anime", "anime") + " you’ve watched").font(.system(size: 15)).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("voice-actor-watched")
                            }
                            let text = actor.readableDescription(hideSpoilers: hideSpoilers)
                            if !text.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(text).font(.system(size: 16)).lineSpacing(6).foregroundStyle(.secondary).lineLimit(expanded ? nil : 5)
                                    Button(expanded ? "Less" : "More") { expanded.toggle() }.font(.system(size: 14)).frame(minHeight: 36)
                                }
                            }
                            facts(actor)
                            if !actor.roles.isEmpty { roles(actor.roles) }
                            Link("Voice actor details: AniList", destination: URL(string: "https://anilist.co/staff/\(actor.id)")!).font(.system(size: 13)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 14)
                    }.padding(.bottom, 28)
                        .background(alignment: .top) {
                            Artwork(path: actor.image, title: actor.name).frame(height: 310 + geometry.safeAreaInsets.top)
                                .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.2), location: 0), .init(color: .black.opacity(0.55), location: 0.55), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
                                .offset(y: -geometry.safeAreaInsets.top).allowsHitTesting(false).accessibilityHidden(true)
                        }
                } else if let failure { RetryNotice(message: failure) { Task { await load() } }.padding(14) }
                else { DiaryLoadingPlaceholder(height: 310, label: "Loading voice actor").padding(14) }
            }.scrollClipDisabled().diaryScreenBackground().navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
                .task(id: route.id) { if actor == nil { await load() } }
        }
    }
    private func header(_ actor: AniVoiceActorDetail) -> some View {
        let saved = favourites.contains(.voice, actor.id)
        return HStack(spacing: 14) {
            Artwork(path: actor.image, title: actor.name).frame(width: 80, height: 80).clipShape(Circle()).overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 2))
            VStack(alignment: .leading, spacing: 4) {
                Text(actor.name).font(.system(size: 26.4, weight: .semibold)).tracking(-1.1).lineLimit(2).minimumScaleFactor(0.8)
                if let native = actor.native { Text(native).font(.system(size: 14)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Button {
                favourites.toggle(.voice, ref: actor.id, name: actor.name, image: actor.image,
                                  subtitle: actor.roles.first.map { "Voice of " + $0.character.name }, store: store)
                if !saved { hearts += 1 }
            } label: { RoundTool(icon: "heart", tint: saved ? theme.accent : Color(webHex: "#c5c0cf")) }
                .buttonStyle(.springPress).starBurst(trigger: hearts).sensoryFeedback(.impact(weight: .light), trigger: saved)
                .accessibilityLabel(saved ? "Remove from favourites" : "Add to favourites").accessibilityIdentifier("voice-actor-favourite")
        }.padding(.horizontal, 14).padding(.top, 145).padding(.bottom, 10)
    }
    private func facts(_ actor: AniVoiceActorDetail) -> some View {
        var rows: [(label: String, value: String)] = []
        if let age = actor.age { rows.append(("Age", String(age))) }
        if let birthday = actor.birthday { rows.append(("Birthday", birthday)) }
        if let home = actor.homeTown, !home.isEmpty { rows.append(("Hometown", home)) }
        if let since = actor.yearsActive.first { rows.append(("Active since", String(since))) }
        if let count = actor.favourites { rows.append(("Favourited by", count.formatted() + " on AniList")) }
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
    private func roles(_ items: [AniRole]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Characters").font(.system(size: 20, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 16) {
                ForEach(items.prefix(30)) { role in
                    NavigationLink(value: CharacterRoute(id: role.character.id, sourceTitle: nil)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Artwork(path: role.character.image, title: role.character.name).aspectRatio(96.0 / 136.0, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            Text(role.character.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).foregroundStyle(.primary)
                            Text(role.anime).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.multilineTextAlignment(.leading).accessibilityElement(children: .combine)
                    }.buttonStyle(.springPress).accessibilityIdentifier("voice-actor-role-\(role.character.id)")
                }
            }
        }
    }
    private func load() async {
        failure = nil
        #if DEBUG
        if store.isPreview { actor = AniListPreview.voiceActor(route.id); return }
        #endif
        do { actor = try await AniListClient.shared.voiceActor(route.id) }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

/// The AniList stats page "Voice actors" for your public profile: the voice actors in the most
/// anime you've watched. Asks for the AniList username (or profile link) once.
struct MostWatchedVoiceActors: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage(MostWatchedVoiceActors.userKey) private var user = ""
    static let userKey = "anilistUser"
    @State private var rows: [AniVoiceActorStat] = []
    @State private var failure: String?
    @State private var loading = false
    @State private var draft = ""
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Most watched").font(.system(size: 20, weight: .semibold))
                Spacer(minLength: 8)
                if !user.isEmpty && !editing {
                    Button("@" + user) { draft = user; editing = true }.font(.system(size: 13)).foregroundStyle(.secondary)
                        .accessibilityLabel("AniList profile " + user + ", change").accessibilityIdentifier("anilist-user")
                }
            }
            if user.isEmpty || editing { connect }
            else if let failure { RetryNotice(message: failure) { Task { await load(force: true) } } }
            else if loading && rows.isEmpty { DiaryLoadingPlaceholder(height: 120, label: "Loading your AniList stats") }
            else if rows.isEmpty { Text("No voice actors in your AniList stats yet.").font(.system(size: 13)).foregroundStyle(.secondary) }
            else { list }
            Text("From your AniList stats: the voice actors in the most anime you’ve watched there.").font(.caption).foregroundStyle(.secondary)
        }.task(id: user) { await load(force: false) }
    }
    private var connect: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your AniList profile").font(.system(size: 15, weight: .semibold))
            Text("Enter your AniList username or paste your profile link. The ranking comes from your public AniList stats.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                TextField("Username or profile link", text: $draft).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done).onSubmit(save).padding(.horizontal, 12).frame(minHeight: 44)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("anilist-user-field")
                Button("Show", action: save).buttonStyle(.glassProminent).disabled(AniListError.username(draft) == nil).accessibilityIdentifier("anilist-user-save")
            }
            if editing && !user.isEmpty { Button("Cancel") { editing = false }.font(.system(size: 13)) }
        }.diaryPanel(padding: 14, radius: 16)
    }
    private func save() {
        guard let name = AniListError.username(draft) else { return }
        editing = false; user = name
    }
    private var list: some View {
        VStack(spacing: 4) {
            ForEach(Array(rows.prefix(30).enumerated()), id: \.element.id) { index, row in
                NavigationLink(value: VoiceActorRoute(id: row.id, watchedCount: row.count)) {
                    HStack(spacing: 12) {
                        Text(String(index + 1)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary).frame(width: 24)
                        Artwork(path: row.person.image, title: row.person.name).frame(width: 48, height: 48).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.person.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                            if let native = row.native { Text(native).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(row.count.counted("anime", "anime")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                            Text(Self.duration(row.minutesWatched)).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        DiaryIcon(name: "chevron-right", size: 14).foregroundStyle(.secondary)
                    }.padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("top-voice-actor-\(row.id)")
            }
        }.diaryPanel(padding: 4, radius: 16)
    }
    static func duration(_ minutes: Int) -> String { minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min" }
    private func load(force: Bool) async {
        guard !user.isEmpty else { rows = []; return }
        #if DEBUG
        if store.isPreview { rows = AniListPreview.topVoiceActors; return }
        #endif
        if force { await AniListClient.shared.forgetStats() }
        loading = true; failure = nil
        defer { loading = false }
        do { rows = try await AniListClient.shared.topVoiceActors(user: user) }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}
