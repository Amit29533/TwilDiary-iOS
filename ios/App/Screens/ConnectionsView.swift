import SwiftUI
import TwilDiaryCore

/// Profile → Connections: everything TwilDiary talks to, in two groups by how you connect it.
/// Services you sign in to on their own page (web sign-in), and services that use a key.
/// The main tracker sits on top because it decides where the diary lives.
struct ConnectionsView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(MainTrackerView.key) private var mainTracker = MainTracker.trakt.rawValue
    @AppStorage(AniListMostWatched.userKey) private var anilistUser = ""
    @State private var showDiaryAccess = false
    /// Trakt's real state (Not connected, Reconnect, scanning…), as Profile showed it before.
    @State private var trakt: TraktController?
    private var traktBadge: String {
        TraktOverview(status: trakt?.status, sync: trakt?.sync, checked: trakt?.status != nil || trakt?.error != nil, unavailable: trakt?.error != nil).badge
    }

    var body: some View {
        let tracker = MainTracker(rawValue: mainTracker) ?? .trakt
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 22) {
                group(nil) {
                    row(BrandLogo(service: tracker.brand), "Main tracker", "The service that holds your diary", value: tracker.name,
                        destination: .mainTracker, id: "settings-main-tracker")
                }
                group("Sign in on the web", note: "Sign in on the service’s own page and come straight back. Simkl and MDBList also take your own key on their page.") {
                    row(BrandLogo(service: .trakt), "Trakt", "History, ratings and watchlist",
                        value: traktBadge, destination: .trakt, id: "settings-trakt")
                    divider
                    row(BrandLogo(service: .simkl), "Simkl", "Anime, shows and movie tracking",
                        value: store.providerSettings.simkl.statusBadge, destination: .simkl, id: "settings-simkl")
                    divider
                    row(BrandLogo(service: .mdblist), "MDBList", "Multi-source ratings and watchlist",
                        value: store.providerSettings.mdblist.statusBadge, destination: .mdblist, id: "settings-mdblist")
                    divider
                    Button { showDiaryAccess = true } label: {
                        rowLabel(tile("lock.shield.fill", Color(webHex: "#3B82F6")), "Your diary", "How this iPhone signs in to your TwilDiary server", value: nil)
                    }.buttonStyle(.plain).accessibilityIdentifier("settings-signin-methods")
                }
                group("API keys", note: "Services TwilDiary reaches with a key or a public profile. Keys are kept on your server, not on this iPhone.") {
                    row(BrandLogo(service: .tmdb), "TMDB", "Posters, details, seasons and episodes", value: nil, destination: .tmdb, id: "settings-tmdb")
                    divider
                    row(BrandLogo(service: .anilist), "AniList", "Characters and voice actors, by public profile",
                        value: anilistUser.isEmpty ? "Not set" : "@" + anilistUser, destination: .anilist, id: "settings-anilist")
                    divider
                    row(BrandLogo(service: .cloudflare), "Cloudflare", "Usage against the free plan", value: nil, destination: .cloudflare, id: "settings-cloudflare")
                    divider
                    row(tile("key.fill", Color(webHex: "#F5B400")), "All keys", "TMDB, Trakt, Cloudflare, Jellyfin and sign-in app IDs",
                        value: nil, destination: .apis, id: "settings-apis")
                }
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 40)
        }.diaryScreenBackground().navigationTitle("Connections").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .task(id: store.sessionRevision) {
                trakt = TraktController(service: makeTraktService(store: store))
                await trakt?.refresh()
            }
            .sheet(isPresented: $showDiaryAccess) {
                NavigationStack {
                    AccessSignIn { credential in
                        showDiaryAccess = false
                        Task { await store.connect(credential) }
                    }
                    .navigationTitle("Your diary").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showDiaryAccess = false } } }
                }
            }
    }

    @ViewBuilder private func group<Content: View>(_ name: String?, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name { Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 4) }
            VStack(spacing: 0, content: content).background(theme.field, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4) }
        }
    }
    private var divider: some View { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 60) }
    private func tile(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 34, height: 34).background(color.gradient, in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
    }
    private func row<Leading: View>(_ leading: Leading, _ title: String, _ subtitle: String, value: String?, destination: AppDestination, id: String) -> some View {
        NavigationLink(value: destination) { rowLabel(leading, title, subtitle, value: value) }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
    private func rowLabel<Leading: View>(_ leading: Leading, _ title: String, _ subtitle: String, value: String?) -> some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7"))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let value { Text(value).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            DiaryIcon(name: "chevron-right", size: 14).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).frame(minHeight: 58).contentShape(Rectangle())
    }
}
