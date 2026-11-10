import SwiftUI
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
    @State private var matching: MainTracker?
    @State private var note: String?

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
                        rowLabel(SettingsTile(symbol: "lock.shield"), "Server sign-in", "How this iPhone signs in to your TwilDiary server", value: nil)
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
                        row(BrandLogo(service: .cloudflare, size: 38), "Cloudflare", "Usage against the free plan", value: nil, destination: .cloudflare, id: "settings-cloudflare")
                        divider
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
            .confirmationDialog(matching.map { "Make \($0.name) match the diary?" } ?? "", isPresented: Binding(get: { matching != nil }, set: { if !$0 { matching = nil } }), titleVisibility: .visible) {
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

    private func connected(_ tracker: MainTracker) -> Bool {
        switch tracker {
        case .trakt: trakt?.status?.connected == true
        case .simkl: store.providerSettings.simkl.enabled && store.providerSettings.simkl.isAuthenticated
        case .mdblist: store.providerSettings.mdblist.enabled && store.providerSettings.mdblist.isAuthenticated
        }
    }
    /// "Connected", "Not connected", "Reconnect"… (Trakt's from your server).
    private func badge(_ tracker: MainTracker) -> String {
        switch tracker {
        case .trakt:
            TraktOverview(status: trakt?.status, sync: trakt?.sync, checked: trakt?.status != nil || trakt?.error != nil, unavailable: trakt?.error != nil).badge
        case .simkl: connected(.simkl) ? "Connected" : "Not connected"
        case .mdblist: connected(.mdblist) ? "Connected" : "Not connected"
        }
    }
    private func account(_ tracker: MainTracker) -> String? {
        switch tracker {
        case .trakt: trakt?.status?.username
        case .simkl: store.providerSettings.simkl.username
        case .mdblist: store.providerSettings.mdblist.username
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
        for tracker in [MainTracker.simkl, .mdblist] { if let error = others.errors[tracker] { return "\(tracker.name): " + error } }
        return traktDirect.writeResult ?? others.writeResults.values.first
    }

    private func trackerRow(_ tracker: MainTracker) -> some View {
        let isMain = tracker == main, on = connected(tracker)
        let destination: AppDestination = tracker == .trakt ? .trakt : tracker == .simkl ? .simkl : .mdblist
        let checked = checkedAt(tracker).map { "checked " + $0.formatted(.relative(presentation: .named)) }
        let detail = on ? [account(tracker).map { "@" + $0 }, checked].compactMap { $0 }.joined(separator: " · ") : ""
        return HStack(spacing: 4) {
            NavigationLink(value: destination) {
                HStack(spacing: 14) {
                    BrandLogo(service: tracker.brand, size: 44)
                        .overlay(alignment: .bottomTrailing) {
                            if isMain {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, theme.accent).background(Circle().fill(Color(webHex: "#111115")).padding(1)).offset(x: 5, y: 5)
                            }
                        }.opacity(on || isMain ? 1 : 0.55)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(tracker.name).font(.system(size: isMain ? 16 : 15, weight: isMain ? .bold : .semibold)).foregroundStyle(HomeStyle.primary)
                            if isMain {
                                Text("Main").font(.system(size: 11, weight: .bold)).foregroundStyle(HomeStyle.chipText)
                                    .padding(.horizontal, 8).frame(height: 17).background(HomeStyle.chip, in: RoundedRectangle(cornerRadius: 9))
                            }
                        }
                        HStack(spacing: 6) {
                            if on { Circle().fill(Color(webHex: "#7fe0b5")).frame(width: 6, height: 6) }
                            Text(on && !detail.isEmpty ? detail : badge(tracker)).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, 15).padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("settings-" + tracker.rawValue)
            Menu {
                if !isMain { Button("Make main tracker", systemImage: "checkmark.circle") { makeMain(tracker) }.disabled(!on) }
                Button("Check now", systemImage: "arrow.clockwise") { Task { await check(tracker) } }.disabled(!on)
                if let plan = writePlan(tracker), !plan.isEmpty {
                    Button("Make \(tracker.name) match the diary", systemImage: "arrow.triangle.2.circlepath") { matching = tracker }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("\(tracker.name) actions").accessibilityIdentifier(tracker.rawValue + "-actions").padding(.trailing, 6)
        }.background(isMain ? Color(webHex: "#1a1730") : .clear)
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
