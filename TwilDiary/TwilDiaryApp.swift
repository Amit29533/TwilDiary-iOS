import SwiftUI

@main struct TwilDiaryApp: App {
    @State private var store = DiaryStore()
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some Scene {
        WindowGroup {
            RootView().environment(store).preferredColorScheme(.dark).tint(theme.accent)
        }
    }
}

struct RootView: View {
    @Environment(DiaryStore.self) private var store
    @State private var showSignIn = false
    var body: some View {
        @Bindable var store = store
        Group {
            if store.needsSignIn {
                VStack(spacing: 22) {
                    Image(systemName: "sparkle").font(.system(size: 56)).foregroundStyle(.tint)
                    Text("TwilDiary").font(.largeTitle.bold())
                    Text("Your diary, now on iOS.").foregroundStyle(.secondary)
                    Button("Sign in to your diary") { showSignIn = true }.buttonStyle(.borderedProminent).controlSize(.large)
                    if let error = store.error { Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                    .sheet(isPresented: $showSignIn) {
                        NavigationStack {
                            AccessSignIn { credential in
                                showSignIn = false; Task { await store.connect(credential) }
                            }.navigationTitle("Private sign-in").navigationBarTitleDisplayMode(.inline)
                                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSignIn = false } } }
                        }
                    }
            } else if !store.hasLoadedWorkspace {
                VStack(spacing: 22) {
                    Image(systemName: store.loading ? "sparkle" : "externaldrive.badge.exclamationmark")
                        .font(.system(size: 48)).foregroundStyle(.tint)
                    Text(store.loading ? "Opening your diary" : "Your diary is temporarily unavailable").font(.title2.bold())
                    if store.loading { ProgressView() }
                    else {
                        Text(store.error ?? "You’re signed in. Retry to load your diary.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Retry") { Task { await store.refresh() } }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        Button("Sign out") { store.signOut() }.foregroundStyle(.secondary)
                    }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            } else {
                TabView {
                    Tab("Home", systemImage: "house") { diaryStack { HomeView() } }
                    Tab("Library", systemImage: "books.vertical") { diaryStack { LibraryView() } }
                    Tab("Glance", systemImage: "eye") { diaryStack { GlanceView() } }
                    Tab("Stats", systemImage: "chart.bar.xaxis") { diaryStack { StatsView() } }
                    Tab("More", systemImage: "ellipsis") { diaryStack { SettingsView() } }
                }.safeAreaInset(edge: .bottom) {
                    if let label = store.undoLabel {
                        HStack { Image(systemName: "checkmark").foregroundStyle(.green); Text(label); Spacer(); Button("Undo") { Task { await store.undo() } }.disabled(store.busy) }
                            .font(.subheadline.weight(.semibold)).padding(16).glassEffect(in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 16).padding(.bottom, 4)
                    }
                }.overlay(alignment: .top) {
                    if let error = store.error {
                        HStack { Text(error).font(.caption); Button("Dismiss", systemImage: "xmark") { store.error = nil }.labelStyle(.iconOnly) }
                            .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)).padding()
                    }
                }
            }
        }.task { await store.refresh() }
    }
    private func diaryStack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content().background(.black).toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: String.self) { id in TitleDetailView(id: id) }
        }
    }
}
