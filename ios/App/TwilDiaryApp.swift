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
            if !ProcessInfo.processInfo.arguments.contains("--ui-keep-library-preferences") {
                UserDefaults.standard.set(false, forKey: "library.list")
                UserDefaults.standard.set(false, forKey: "library.genreRows")
                UserDefaults.standard.set(LibraryQuery.Sort.library.rawValue, forKey: "library.sort")
            }
        }
        #endif
    }
    var body: some Scene {
        WindowGroup { RootView().environment(store).environment(router).preferredColorScheme(.dark).tint(theme.accent).buttonBorderShape(.capsule) }
    }
}

enum AppTab: String, CaseIterable, Hashable {
    case home, library, glance, stats, more
    var label: String { rawValue.capitalized }
    var icon: String {
        switch self { case .home: "house"; case .library: "library-big"; case .glance: "eye"; case .stats: "chart-no-axes-column-increasing"; case .more: "ellipsis" }
    }
}
enum AppDestination: Hashable { case explore, history, files, trash, scanner, appearance, trakt, tmdb, about }
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
    var selectedTab = AppTab.glance
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
    var body: some View {
        @Bindable var router = router
        Group {
            if store.needsSignIn {
                VStack(spacing: 22) {
                    BrandMark().fill(.tint).frame(width: 56, height: 56)
                    Text("TwilDiary").font(.largeTitle.bold())
                    Text("Your diary, now on iOS.").foregroundStyle(.secondary)
                    Button("Sign in to your diary") { showSignIn = true }.buttonStyle(.borderedProminent).controlSize(.large)
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
                        Button("Retry") { Task { await store.refresh() } }.buttonStyle(.borderedProminent).controlSize(.large)
                        Button("Sign out") { store.signOut() }.foregroundStyle(.secondary)
                    }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            } else {
                TabView(selection: $router.selectedTab) {
                    Tab("Home", systemImage: "house", value: AppTab.home) { diaryStack(.home) { HomeView() } }.accessibilityIdentifier("tab-home")
                    Tab("Library", systemImage: "books.vertical", value: AppTab.library) { diaryStack(.library) { LibraryView() } }.accessibilityIdentifier("tab-library")
                    Tab("Glance", systemImage: "eye", value: AppTab.glance) { diaryStack(.glance) { GlanceView() } }.accessibilityIdentifier("tab-glance")
                    Tab("Stats", systemImage: "chart.bar", value: AppTab.stats) { diaryStack(.stats) { StatsView() } }.accessibilityIdentifier("tab-stats")
                    Tab("More", systemImage: "ellipsis", value: AppTab.more) { diaryStack(.more) { SettingsView() } }.accessibilityIdentifier("tab-more")
                }.tabBarMinimizeBehavior(.never)
                    .background(.black)
                    .overlay(alignment: .top) {
                        if let notice = store.mutationRefreshNotice {
                            HStack(alignment: .top, spacing: 12) {
                                Text(notice).font(.caption).accessibilityIdentifier("confirmed-write-notice")
                                Spacer(minLength: 0)
                                Button("Refresh") { Task { await store.refresh() } }
                                    .disabled(store.loading).accessibilityIdentifier("confirmed-write-refresh")
                            }.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)).padding()
                        } else if let error = store.error {
                            HStack { Text(error).font(.caption); Button("Dismiss", systemImage: "xmark") { store.error = nil }.labelStyle(.iconOnly) }
                                .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)).padding()
                        }
                    }
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
    private func diaryStack<Content: View>(_ tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: Binding(get: { router.paths[tab] ?? NavigationPath() }, set: { router.paths[tab] = $0 })) {
            content().background(tab == .library && theme != .glass ? Color(webHex: "#0e0d13") : .clear).background { if tab != .library { DiaryScreenBackground() } }.toolbar(.hidden, for: .navigationBar).diaryPageChrome(detail: false)
                .diaryNavigationAppearance(tab: tab, detail: false, router: router)
                .rootTabSwipes(enabled: router.selectedTab == tab && (router.paths[tab]?.isEmpty ?? true) && router.randomPick == nil) { translation, width in
                    guard let next = RootTabSwipe.destination(from: tab, translation: translation, width: width) else { return }
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    router.selectedTab = next
                }
                .navigationDestination(for: String.self) { TitleDetailView(id: $0).toolbar(.hidden, for: .tabBar).diaryPageChrome(detail: true).diaryNavigationAppearance(tab: tab, detail: true, router: router) }
                .navigationDestination(for: SavedTitleRoute.self) { TitleDetailView(id: $0.id, linkedSeason: $0.season, focusEpisodes: $0.focusEpisodes, focusNotes: $0.focusNotes).toolbar(.hidden, for: .tabBar).diaryPageChrome(detail: true).diaryNavigationAppearance(tab: tab, detail: true, router: router) }
                .navigationDestination(for: CatalogRoute.self) { CatalogDetailView(route: $0).toolbar(.hidden, for: .tabBar).diaryPageChrome(detail: true).diaryNavigationAppearance(tab: tab, detail: true, router: router) }
                .navigationDestination(for: ExploreSectionRoute.self) { ExploreSectionView(route: $0, store: store).toolbar(.visible, for: .tabBar).diaryPageChrome(detail: false).diaryNavigationAppearance(tab: tab, detail: false, router: router) }
                .navigationDestination(for: PersonFilmographyRoute.self) { PersonFilmographyView(route: $0).toolbar(.visible, for: .tabBar).diaryPageChrome(detail: false).diaryNavigationAppearance(tab: tab, detail: false, router: router) }
                .navigationDestination(for: PersonRoute.self) { PersonView(route: $0).toolbar(.hidden, for: .tabBar).diaryPageChrome(detail: true).diaryNavigationAppearance(tab: tab, detail: true, router: router) }
                .navigationDestination(for: HistoryRoute.self) { route in
                    HistoryView(initialDay: route.day, initialUnknown: route.unknown).toolbar(.visible, for: .tabBar).diaryPageChrome(detail: false).diaryNavigationAppearance(tab: tab, detail: false, router: router)
                }
                .navigationDestination(for: AppDestination.self) { destination in
                    Group { switch destination {
                    case .explore: ExploreView()
                    case .history: HistoryView()
                    case .files: FilesView()
                    case .trash: TrashView()
                    case .scanner: ScannerReviewView()
                    case .appearance: AppearanceView()
                    case .trakt: TraktView(store: store)
                    case .tmdb: TMDBConnectionView()
                    case .about: AboutView()
                    } }.toolbar(.visible, for: .tabBar).diaryPageChrome(detail: false).diaryNavigationAppearance(tab: tab, detail: false, router: router)
                }
        }
            .environment(\.diaryBack, DiaryBackAction { router.goBack(tab: tab) })
    }
}
