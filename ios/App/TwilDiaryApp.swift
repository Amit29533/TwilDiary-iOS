import SwiftUI
import UIKit
import TwilDiaryCore

@main struct TwilDiaryApp: App {
    @State private var store = DiaryStore()
    @State private var router = AppRouter()
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            UserDefaults.standard.set(DiaryTheme.twilight.rawValue, forKey: "theme")
            UserDefaults.standard.set(PublicRatingSource.tmdb.rawValue, forKey: "publicRatingSource")
            UserDefaults.standard.set(true, forKey: "hideSpoilers")
            for key in ["historyGrid", "homeHistoryGrid", "upcomingGrid", "glanceGrid", "filesGrid", "scannerGrid", "episodesGrid", "traktGrid", "searchGrid", "backlogGrid"] { UserDefaults.standard.set(false, forKey: key) }
            UserDefaults.standard.set(true, forKey: "catalogGrid")
            UserDefaults.standard.set(true, forKey: "trashGrid")
            FavouritesStore.shared.reset()
            if !ProcessInfo.processInfo.arguments.contains("--ui-keep-launch-tab") { UserDefaults.standard.removeObject(forKey: AppTab.launchKey) }
            for key in ["favouritesTab", AniListMostWatched.userKey, "canvasTab", "glanceSort", "glanceCategory", "trashCategory", "trashSort", "canvasSort", "canvasListSort", "canvasListKind", "traktConflictDefault", "traktConflictPrefer", "jellyfinAddress", "jellyfinExcludedLibraries", "jellyfinLastSync"] { UserDefaults.standard.removeObject(forKey: key) }
            if !ProcessInfo.processInfo.arguments.contains("--ui-keep-library-preferences") {
                UserDefaults.standard.set(false, forKey: "library.list")
                UserDefaults.standard.set(false, forKey: "library.genreRows")
                UserDefaults.standard.set(LibraryQuery.Sort.library.rawValue, forKey: "library.sort")
            }
        }
        #endif
    }
    var body: some Scene {
        // No app-wide glass button style: it turned every text link, toolbar item and
        // card link into a glass capsule (glass on the system bars' own glass).
        // Actions choose .glass / .glassProminent explicitly; toolbars get system glass.
        WindowGroup { RootView().environment(store).environment(router).preferredColorScheme(.dark).tint(theme.accent).buttonBorderShape(.capsule) }
    }
}

enum AppTab: String, CaseIterable, Hashable {
    case home, library, glance, stats, more
    var label: String { rawValue.capitalized }
    /// Settings → Appearance → Opens on: the tab a fresh launch starts on (Glance until chosen).
    static let launchKey = "launchTab"
    static var launch: AppTab {
        #if DEBUG
        // UI tests start on Glance unless a test is checking this setting across a relaunch.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") && !arguments.contains("--ui-keep-launch-tab") { return .glance }
        #endif
        return UserDefaults.standard.string(forKey: launchKey).flatMap(AppTab.init(rawValue:)) ?? .glance
    }
    var systemIcon: String { switch self { case .home: "house"; case .library: "books.vertical"; case .glance: "eye"; case .stats: "chart.bar"; case .more: "ellipsis" } }
    var icon: String {
        switch self { case .home: "house"; case .library: "library-big"; case .glance: "eye"; case .stats: "chart-no-axes-column-increasing"; case .more: "ellipsis" }
    }
}
enum AppDestination: Hashable { case explore, canvas, history, files, trash, scanner, appearance, trakt, tmdb, cloudflare, apis, favourites, about }
struct HistoryRoute: Hashable {
    var day: Date? = nil
    var unknown = false
}
struct SavedTitleRoute: Hashable {
    let id: String
    let season: Int
    var focusEpisodes = true
    var focusNotes = false
}

@MainActor @Observable final class AppRouter {
    var selectedTab = AppTab.launch
    var randomPick: RandomPickScope?
    var paths: [AppTab: NavigationPath] = [:]
    var libraryShortcut: String?
    var libraryGenreShortcut = ""
    var libraryDiskShortcut = ""
    var libraryRevision = 0
    var statsRevision = 0
    var detailTabs = Set<AppTab>()
    func setDetailVisibility(_ visible: Bool, tab: AppTab) {
        guard detailTabs.contains(tab) != visible else { return }
        if visible { detailTabs.insert(tab) } else { detailTabs.remove(tab) }
    }
    @discardableResult func goBack(tab: AppTab? = nil) -> Bool {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let owner = tab ?? selectedTab
        guard var path = paths[owner], !path.isEmpty else { return false }
        path.removeLast(); paths[owner] = path
        return true
    }
    func select(_ tab: AppTab) {
        if selectedTab == tab { paths[tab] = NavigationPath(); detailTabs.remove(tab) }
        selectedTab = tab
    }
    func presentRandomPick(_ titleIDs: [String]? = nil) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        randomPick = RandomPickScope(titleIDs: titleIDs)
    }
    func library(_ shortcut: String) { libraryGenreShortcut = ""; libraryDiskShortcut = ""; libraryShortcut = shortcut; libraryRevision += 1; paths[.library] = NavigationPath(); selectedTab = .library }
    func libraryGenre(_ genre: String) { library("all"); libraryGenreShortcut = genre }
    func libraryDisk(_ key: String) { library("all"); libraryDiskShortcut = key == "all" ? "" : key }
    func statsToday() { statsRevision += 1; paths[.stats] = NavigationPath(); selectedTab = .stats }
    func files() { selectedTab = .more; paths[.more] = NavigationPath(); paths[.more, default: NavigationPath()].append(AppDestination.files) }
    func openTitle(_ id: String, tab: AppTab) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        selectedTab = tab; paths[tab, default: NavigationPath()].append(id)
    }
    func replaceTitle(_ id: String, tab: AppTab) {
        selectedTab = tab
        if paths[tab, default: NavigationPath()].count > 0 { paths[tab, default: NavigationPath()].removeLast() }
        paths[tab, default: NavigationPath()].append(id)
    }
}

struct RootView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSignIn = false
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    /// Posters zoom into the title pages they open (and back), as in the Photos and App Store apps.
    @Namespace private var zoom
    var body: some View {
        @Bindable var router = router
        Group {
            if store.needsSignIn {
                VStack(spacing: 22) {
                    BrandMark().fill(.tint).frame(width: 56, height: 56)
                    Text("TwilDiary").font(.largeTitle.bold())
                    Text("Your diary, now on iOS.").foregroundStyle(.secondary)
                    Button("Sign in to your diary") { showSignIn = true }.buttonStyle(.glassProminent).controlSize(.large)
                    if let error = store.error { Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                    .sheet(isPresented: $showSignIn) {
                        NavigationStack {
                            AccessSignIn { credential in showSignIn = false; Task { await store.connect(credential) } }
                                .navigationTitle("Private sign-in").navigationBarTitleDisplayMode(.inline)
                                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSignIn = false } } }
                        }
                    }
            } else if !store.hasLoadedWorkspace {
                VStack(spacing: 22) {
                    BrandMark().fill(.tint).frame(width: 48, height: 48)
                    Text(store.loading || store.restoringCache ? "Opening your diary" : "Your diary is temporarily unavailable").font(.title2.bold())
                    if store.loading || store.restoringCache { ProgressView() }
                    else {
                        Text(store.error ?? "You’re signed in. Retry to load your diary.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Retry") { Task { await store.refresh() } }.buttonStyle(.glassProminent).controlSize(.large)
                        Button("Sign out") { store.signOut() }.foregroundStyle(.secondary)
                    }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            } else {
                NativeTabShell(selection: $router.selectedTab, accent: UIColor(theme.accent),
                               pageKey: theme.rawValue + ":" + String(describing: scenePhase), canPage: { tab in
                    (router.paths[tab]?.isEmpty ?? true) && router.randomPick == nil
                }, onReselect: { router.select($0) }) { tab in
                    AnyView(tabPage(tab).environment(store).environment(router).preferredColorScheme(.dark)
                        .tint(theme.accent).buttonBorderShape(.capsule).environment(\.scenePhase, scenePhase))
                }
                    // The tab controller fills the screen and hands pages the real insets: heroes
                    // reach under the status bar, and lists scroll under the floating tab bar to
                    // the bottom edge instead of stopping at a black home-indicator band.
                    // Container only: ignoring the keyboard region let the keyboard cover the tab bar.
                    .ignoresSafeArea(.container)
                    .background(.black)
                    .overlay(alignment: .bottom) { RootNoticeBanner() }
                    // Milestones (a season or show finished, round watch counts) get a starfall over everything.
                    .overlay { CelebrationOverlay() }
            }
        }.accessibilityHidden(router.randomPick != nil).allowsHitTesting(router.randomPick == nil)
            .overlay {
                if let scope = router.randomPick {
                    RandomPickDialog(titles: scope.candidates(in: store.workspace),
                        onClose: { router.randomPick = nil },
                        onOpen: { id in router.randomPick = nil; router.openTitle(id, tab: router.selectedTab) },
                        onAdd: { router.randomPick = nil; router.library("add") }).id(scope.id)
                }
            }.onChange(of: store.sessionRevision) { _, _ in router.randomPick = nil }
            .task(id: scenePhase) {
                if scenePhase == .active { await store.refreshOnForeground(); await store.resumeTraktOnForeground() }
                else { store.suspendTraktForBackground() }
            }
    }
    @ViewBuilder private func tabPage(_ tab: AppTab) -> some View {
        switch tab {
        case .home: diaryStack(tab) { HomeView() }
        case .library: diaryStack(tab) { LibraryView() }
        case .glance: diaryStack(tab) { GlanceView() }
        case .stats: diaryStack(tab) { StatsView() }
        case .more: diaryStack(tab) { SettingsView() }
        }
    }
    private func diaryStack<Content: View>(_ tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: Binding(get: { router.paths[tab] ?? NavigationPath() }, set: { router.paths[tab] = $0 })) {
            // Tab pages draw their own pinned header and status-bar shade. Without this, the bar of a page
            // sliding away dimmed the header (iOS 26's scroll-edge effect) until the slide finished.
            content().scrollEdgeEffectHidden(true, for: .top).background(tab == .library && theme != .glass ? Color(webHex: "#0e0d13") : .clear).background { if tab != .library { DiaryScreenBackground() } }.toolbar(.hidden, for: .navigationBar).diaryPageChrome(detail: false)
                .diaryNavigationAppearance(tab: tab, detail: false, router: router)
                .navigationDestination(for: String.self) { TitleDetailView(id: $0).navigationTransition(.zoom(sourceID: ZoomID.scoped(tab.rawValue, ZoomID.title($0)), in: zoom)).diaryPageChrome(detail: true).diaryNavigationAppearance(tab: tab, detail: true, router: router) }
                .navigationDestination(for: SavedTitleRoute.self) { TitleDetailView(id: $0.id, linkedSeason: $0.season, focusEpisodes: $0.focusEpisodes, focusNotes: $0.focusNotes).navigationTransition(.zoom(sourceID: ZoomID.scoped(tab.rawValue, ZoomID.title($0.id)), in: zoom)).diaryPageChrome(detail: true).diaryNavigationAppearance(tab: tab, detail: true, router: router) }
                .navigationDestination(for: CatalogRoute.self) { CatalogDetailView(route: $0).navigationTransition(.zoom(sourceID: ZoomID.scoped(tab.rawValue, ZoomID.catalog($0)), in: zoom)).diaryPageChrome(detail: true).diaryNavigationAppearance(tab: tab, detail: true, router: router) }
                .navigationDestination(for: ExploreSectionRoute.self) { ExploreSectionView(route: $0, store: store).diaryPageChrome(detail: false).diaryNavigationAppearance(tab: tab, detail: false, router: router) }
                .navigationDestination(for: PersonFilmographyRoute.self) { PersonFilmographyView(route: $0).diaryPageChrome(detail: false).diaryNavigationAppearance(tab: tab, detail: false, router: router) }
                .navigationDestination(for: PersonRoute.self) { PersonView(route: $0).diaryPageChrome(detail: true).diaryNavigationAppearance(tab: tab, detail: true, router: router) }
                .navigationDestination(for: CharacterRoute.self) { CharacterView(route: $0).diaryPageChrome(detail: true).diaryNavigationAppearance(tab: tab, detail: true, router: router) }
                .navigationDestination(for: VoiceActorRoute.self) { VoiceActorView(route: $0).diaryPageChrome(detail: true).diaryNavigationAppearance(tab: tab, detail: true, router: router) }
                .navigationDestination(for: HistoryRoute.self) { route in
                    HistoryView(initialDay: route.day, initialUnknown: route.unknown).diaryPageChrome(detail: false).diaryNavigationAppearance(tab: tab, detail: false, router: router)
                }
                .navigationDestination(for: CanvasListRoute.self) { CanvasListView(route: $0).diaryPageChrome(detail: false).diaryNavigationAppearance(tab: tab, detail: false, router: router) }
                .navigationDestination(for: AppDestination.self) { destination in
                    Group { switch destination {
                    case .explore: ExploreView()
                    case .canvas: CanvasView()
                    case .history: HistoryView()
                    case .files: FilesView()
                    case .trash: TrashView()
                    case .scanner: ScannerReviewView()
                    case .appearance: AppearanceView()
                    case .trakt: TraktView(store: store)
                    case .tmdb: TMDBConnectionView()
                    case .cloudflare: CloudflareUsageView()
                    case .apis: APIsView()
                    case .favourites: FavouritesView()
                    case .about: AboutView()
                    } }.diaryPageChrome(detail: false).diaryNavigationAppearance(tab: tab, detail: false, router: router)
                }
        }
            .environment(\.diaryBack, DiaryBackAction { router.goBack(tab: tab) })
            .environment(\.zoomNamespace, zoom).environment(\.zoomScope, tab.rawValue)
    }
}

/// Reads the write notice and error itself. A banner change now re-renders only
/// the banner, not the root view, which reassigned all five tab pages each time.
private struct RootNoticeBanner: View {
    @Environment(DiaryStore.self) private var store
    var body: some View {
        if let notice = store.mutationRefreshNotice {
            // A small pill above the tab bar, not a banner over the page header.
            HStack(spacing: 10) {
                Text("Saved · refresh failed").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .accessibilityLabel(notice).accessibilityIdentifier("confirmed-write-notice")
                Button("Refresh") { Task { await store.refresh() } }.font(.system(size: 12, weight: .semibold)).frame(minHeight: 40)
                    .disabled(store.loading).accessibilityIdentifier("confirmed-write-refresh")
            }.padding(.horizontal, 14).frame(height: 40).glassEffect(.regular, in: Capsule()).fixedSize().padding(.bottom, 140)
        } else if let error = store.error {
            HStack(spacing: 8) { Text(error).font(.system(size: 12)).lineLimit(2); Button("Dismiss", systemImage: "xmark") { store.error = nil }.labelStyle(.iconOnly).frame(minWidth: 36, minHeight: 40) }
                .padding(.leading, 14).padding(.trailing, 4).glassEffect(.regular, in: Capsule()).padding(.horizontal, 24).padding(.bottom, 140)
        }
    }
}
