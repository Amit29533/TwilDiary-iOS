import SwiftUI
import AuthenticationServices
import TwilDiaryCore

/// Profile → Connections. On top, where your diary lives: Trakt, Simkl and MDBList in one list.
/// The ticked one is your main tracker (the diary comes from it; edits go to it, and also to the
/// others you're signed in to). Each row opens that service's page; ⋯ has the quick actions.
/// Below: how this iPhone reaches your server, and the services that use a key.
struct ConnectionsView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(MainTrackerView.key) private var mainTracker = MainTracker.trakt.rawValue
    @AppStorage(AniListMostWatched.userKey) private var anilistUser = ""
    @State private var showDiaryAccess = false
    /// Trakt's real state (Not connected, Reconnect…), from your server.
    @State private var trakt: TraktController?
    @State private var traktDirect = TraktDirectStore.shared
    @State private var others = TrackerPreviewStore.shared
    @State private var profiles = AccountProfiles.shared
    @State private var matching: MainTracker?
    @State private var note: String?
    @State private var signingIn: MainTracker?
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    private var main: MainTracker { MainTracker(rawValue: mainTracker) ?? .trakt }

    var body: some View {
        EdgeToEdgeScroll {
            // Design (board 3): WHERE YOUR DIARY LIVES, YOUR DIARY and KEYS, each a card of rows.
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsGroup(label: "Where your diary lives") {
                        ForEach(Array(MainTracker.allCases.enumerated()), id: \.element) { index, tracker in
                            if index > 0 { divider }
                            trackerRow(tracker)
                        }
                    }
                    if let progress = activity {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(progress).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary) }.padding(.horizontal, 4)
                    } else if let note = note ?? lastResult {
                        SettingsFootnote(text: note).accessibilityIdentifier("trackers-note")
                    }
                    SettingsFootnote(text: "The Main one holds your diary. Your edits go to it, and to the others you’re signed in to.")
                }
                SettingsGroup(label: "Your diary") {
                    Button { showDiaryAccess = true } label: {
                        rowLabel(SettingsTile(symbol: "lock.shield"), "Server sign-in",
                                 store.phoneOnly ? "Not connected. Optional: tags, notes, files and Trash stay on this phone and Google Drive" : "How this iPhone signs in to your TwilDiary server",
                                 value: store.phoneOnly ? "Connect" : nil)
                    }.buttonStyle(.plain).accessibilityIdentifier("settings-signin-methods")
                    divider
                    row(SettingsTile(symbol: "externaldrive.badge.timemachine"), "Backups", "Copies of your diary kept on your server",
                        value: nil, destination: .backups, id: "connections-backups")
                }
                VStack(alignment: .leading, spacing: 12) {
                    SettingsGroup(label: "Keys") {
                        row(BrandLogo(service: .tmdb, size: 38), "TMDB", "Posters, details, seasons and episodes", value: nil, destination: .tmdb, id: "settings-tmdb")
                        divider
                        row(BrandLogo(service: .anilist, size: 38), "AniList", "Characters and voice actors",
                            value: anilistUser.isEmpty ? "Not set" : "@" + anilistUser, destination: .anilist, id: "settings-anilist")
                        divider
                        if !store.phoneOnly {
                            row(BrandLogo(service: .cloudflare, size: 38), "Cloudflare", "Usage against the free plan", value: nil, destination: .cloudflare, id: "settings-cloudflare")
                            divider
                        }
                        NavigationLink(value: AppDestination.apis) {
                            Text("All keys").font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).padding(.horizontal, 15).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("settings-apis")
                    }
                    SettingsFootnote(text: "Keys are kept encrypted on this iPhone, and TwilDiary reads each service with them directly.")
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }.diaryScreenBackground().diaryPageNavigation("Connections")
            .task(id: store.sessionRevision) {
                trakt = TraktController(service: makeTraktService(store: store))
                await trakt?.refresh()
            }
            .alert(matching.map { "Make \($0.name) match the diary?" } ?? "", isPresented: Binding(get: { matching != nil }, set: { if !$0 { matching = nil } })) {
                if let tracker = matching {
                    Button("Send to \(tracker.name)") { Task { await match(tracker) } }
                    Button("Cancel", role: .cancel) { matching = nil }
                }
            } message: {
                if let tracker = matching, let plan = writePlan(tracker) {
                    Text(plan.summary.map { "• " + $0 }.joined(separator: "\n") + "\n\nNothing is removed from your \(tracker.name) history.")
                }
            }
            .sheet(isPresented: $showDiaryAccess) {
                NavigationStack {
                    AccessSignIn { credential in
                        showDiaryAccess = false
                        Task { await store.connect(credential) }
                    }
                    .navigationTitle("Server sign-in").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showDiaryAccess = false } } }
                }
            }
    }

    // MARK: Trackers

    /// Signed in (whether or not sync is on).
    private func connected(_ tracker: MainTracker) -> Bool {
        switch tracker {
        case .trakt: store.traktSignedInOnPhone || trakt?.status?.connected == true
        case .simkl: store.providerSettings.simkl.isAuthenticated
        case .mdblist: store.providerSettings.mdblist.isAuthenticated
        case .wetrakr: store.providerSettings.wetrakr.isAuthenticated
        }
    }
    /// Signed in and syncing (Trakt always syncs once signed in).
    private func syncing(_ tracker: MainTracker) -> Bool {
        tracker == .trakt ? connected(.trakt) : connected(tracker) && store.providerSettings.config(for: tracker.provider).enabled
    }
    /// "Connected", "Not connected", "Reconnect"… (Trakt's from your server).
    private func badge(_ tracker: MainTracker) -> String {
        switch tracker {
        case .trakt:
            store.traktSignedInOnPhone ? "Connected"
            : TraktOverview(status: trakt?.status, sync: trakt?.sync, checked: trakt?.status != nil || trakt?.error != nil, unavailable: trakt?.error != nil).badge
        case .simkl: connected(.simkl) ? "Connected" : "Not connected"
        case .mdblist: connected(.mdblist) ? "Connected" : "Not connected"
        case .wetrakr: connected(.wetrakr) ? "Connected" : "Not connected"
        }
    }
    private func account(_ tracker: MainTracker) -> String? {
        switch tracker {
        case .trakt: store.traktSignedInOnPhone ? store.providerSettings.trakt.username : trakt?.status?.username
        case .simkl: store.providerSettings.simkl.username
        case .mdblist: store.providerSettings.mdblist.username
        case .wetrakr: store.providerSettings.wetrakr.username
        }
    }
    private func checkedAt(_ tracker: MainTracker) -> Date? {
        let stamp = tracker == .trakt ? traktDirect.library?.fetchedAt : others.libraries[tracker]?.fetchedAt
        return stamp.flatMap { try? Date($0, strategy: .iso8601) }
    }
    private func writePlan(_ tracker: MainTracker) -> TraktWritePlan? {
        tracker == .trakt ? traktDirect.plan : others.plans[tracker]
    }
    private var activity: String? {
        if traktDirect.running { return "Reading Trakt…" }
        if let running = others.running { return "Reading \(running.name)…" }
        return traktDirect.writeProgress ?? others.writeProgress
    }
    private var lastResult: String? {
        if let error = traktDirect.error { return error }
        for tracker in [MainTracker.simkl, .mdblist, .wetrakr] { if let error = others.errors[tracker] { return "\(tracker.name): " + error } }
        return traktDirect.writeResult ?? others.writeResults.values.first
    }

    private func trackerRow(_ tracker: MainTracker) -> some View {
        let isMain = tracker == main, on = connected(tracker)
        let destination: AppDestination = switch tracker { case .trakt: .trakt; case .simkl: .simkl; case .mdblist: .mdblist; case .wetrakr: .wetrakr }
        let profile = on ? profiles.account(tracker) : nil
        let checked = checkedAt(tracker).map { $0.formatted(.relative(presentation: .named)) }
        let sync = syncing(tracker)
        let detail = on ? [profile?.name ?? account(tracker), sync ? checked : "Sync off"].compactMap { $0 }.joined(separator: " · ") : ""
        // A connection that needs attention says so (in amber), instead of looking healthy.
        let status = badge(tracker), problem = ["Reconnect", "Unavailable"].contains(status)
        return HStack(spacing: 4) {
            NavigationLink(value: destination) {
                HStack(spacing: 14) {
                    // As Cinopsys: your picture on the service, its logo on the corner.
                    avatar(profile?.avatar, on: on)
                        .overlay(alignment: .bottomTrailing) {
                            BrandLogo(service: tracker.brand, size: 20)
                                .overlay(RoundedRectangle(cornerRadius: 20 * 0.225).strokeBorder(Color(webHex: "#111115"), lineWidth: 2))
                                .offset(x: 4, y: 4)
                        }.opacity(on || isMain ? 1 : 0.6)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(tracker.name).font(.system(size: 16, weight: .bold)).foregroundStyle(HomeStyle.primary)
                            if let plan = profile?.plan { Text("· " + plan).font(.system(size: 15)).foregroundStyle(HomeStyle.secondary) }
                            if isMain {
                                Image(systemName: "checkmark.seal.fill").font(.system(size: 15)).symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, theme.accent).accessibilityHidden(true)
                            }
                        }.lineLimit(1)
                        HStack(spacing: 6) {
                            if on && !problem { Circle().fill(sync ? Color(webHex: "#7fe0b5") : Color(webHex: "#8e8e9c")).frame(width: 6, height: 6) }
                            Text(on && !detail.isEmpty && !problem ? detail : status).font(.system(size: 12))
                                .foregroundStyle(problem ? Color(webHex: "#f5c26b") : HomeStyle.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, 15).padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .task(id: on) { if on { await profiles.refresh(tracker, store: store) } }
                // VoiceOver hears the status even when the row shows the account instead.
                .accessibilityLabel([tracker.name, isMain ? "Main" : nil, status, detail.isEmpty ? nil : detail].compactMap { $0 }.joined(separator: ", "))
                .accessibilityIdentifier("settings-" + tracker.rawValue)
            // Not signed in: one tap opens the service's own sign-in page right here.
            if !on || problem, ServiceSignIn.supportsSheet(tracker.provider) {
                Button { Task { await signIn(tracker) } } label: {
                    Group {
                        if signingIn == tracker { ProgressView().controlSize(.small) }
                        else { Text(problem ? "Reconnect" : "Sign in").font(.system(size: 13, weight: .semibold)).lineLimit(1) }
                    }.padding(.horizontal, 14).frame(height: 32).foregroundStyle(HomeStyle.chipText).background(HomeStyle.chip, in: Capsule())
                }.buttonStyle(.plain).disabled(signingIn != nil).accessibilityIdentifier(tracker.rawValue + "-quick-sign-in")
            }
            Menu {
                if !isMain { Button("Make main tracker", systemImage: "checkmark.circle") { makeMain(tracker) }.disabled(!on) }
                Button("Check now", systemImage: "arrow.clockwise") { Task { await check(tracker) } }.disabled(!on)
                // Connected through your server: move the Trakt sign-in onto this iPhone in one tap.
                if tracker == .trakt, on, !store.traktSignedInOnPhone {
                    Button("Sign in on this iPhone", systemImage: "iphone") { Task { await signIn(.trakt) } }
                }
                if tracker == .trakt, store.traktSignedInOnPhone {
                    Button("Sign out of Trakt", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task { await store.signOutTraktOnPhone(); note = "Signed out of Trakt on this iPhone." }
                    }
                }
                if let plan = writePlan(tracker), !plan.isEmpty {
                    Button("Make \(tracker.name) match the diary", systemImage: "arrow.triangle.2.circlepath") { matching = tracker }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("\(tracker.name) actions").accessibilityIdentifier(tracker.rawValue + "-actions").padding(.trailing, 6)
        }.background(isMain ? Color(webHex: "#1d1934") : .clear)
    }

    /// Your picture on the service, or a plain person while it's unknown or you're not signed in.
    private func avatar(_ path: String?, on: Bool) -> some View {
        ZStack {
            Circle().fill(Color(webHex: "#2a2a31"))
            Image(systemName: "person.fill").font(.system(size: 20)).foregroundStyle(Color(webHex: "#8e8e9c"))
            // Account pictures live on each service's own host (not TMDB's), so they load directly.
            if let path, let url = URL(string: path), url.scheme == "https" {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { Color.clear }
                }.clipShape(Circle())
            }
        }.frame(width: 46, height: 46)
    }
    private func signIn(_ tracker: MainTracker) async {
        signingIn = tracker; note = nil
        defer { signingIn = nil }
        do {
            if case .signedIn = try await ServiceSignIn.run(tracker.provider, store: store, using: webAuthenticationSession) {
                await profiles.refresh(tracker, store: store, force: true)
                note = "Signed in to \(tracker.name)" + (profiles.account(tracker)?.name.map { " as " + $0 } ?? "") + "."
            }
        } catch { note = error.localizedDescription }
    }
    /// The main tracker holds the diary: the diary is shown from it, and edits go to it.
    private func makeMain(_ tracker: MainTracker) {
        mainTracker = tracker.rawValue
        note = "\(tracker.name) holds your diary now."
        guard !store.isPreview else { return }
        store.diarySource = tracker.rawValue
    }
    private func check(_ tracker: MainTracker) async {
        note = nil
        if tracker == .trakt { await traktDirect.check(store: store) } else { await others.check(tracker, store: store) }
    }
    private func match(_ tracker: MainTracker) async {
        matching = nil; note = nil
        if tracker == .trakt { await traktDirect.makeTraktMatch(store: store) } else { await others.makeMatch(tracker, store: store) }
    }

    // MARK: Rows

    @ViewBuilder private func group<Content: View>(_ name: String?, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name { Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 4) }
            VStack(spacing: 0, content: content).background(theme.field, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4) }
        }
    }
    private var divider: some View { SettingsDivider() }
    private func tile(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 34, height: 34).background(color.gradient, in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
    }
    private func row<Leading: View>(_ leading: Leading, _ title: String, _ subtitle: String, value: String?, destination: AppDestination, id: String) -> some View {
        NavigationLink(value: destination) { rowLabel(leading, title, subtitle, value: value) }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
    private func rowLabel<Leading: View>(_ leading: Leading, _ title: String, _ subtitle: String, value: String?) -> some View {
        HStack(spacing: 14) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if let value { Text(value).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
            SettingsChevron()
        }.padding(.horizontal, 15).frame(minHeight: 64).contentShape(Rectangle())
    }
}
