import SwiftUI
import TwilDiaryCore

/// Trakt: your sign-in, the Trakt diary's options and its limits. (The old server scan, review,
/// incoming watches and watch-logging page are gone: Trakt holds the diary, edits go to it directly.)
@MainActor struct TraktView: View {
    let store: DiaryStore
    @State private var controller: TraktController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ServiceRemovals.key) private var applyRemovals = true
    init(store: DiaryStore) {
        self.store = store
        _controller = State(initialValue: store.traktController)
    }
    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 16) {
                page
                if !onPhone, let error = controller.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Retry") { Task { await controller.refresh() } }
                            .buttonStyle(.diaryRowPrimary).disabled(controller.busy).accessibilityIdentifier("trakt-retry")
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsCard()).accessibilityIdentifier("trakt-error")
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 100)
        }.diaryScreenBackground().navigationTitle("Trakt").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .task { if !onPhone && controller.status == nil { await controller.refresh() } }
            .refreshable { if !onPhone { await controller.refresh() } }
            .onChange(of: scenePhase) { _, phase in if phase == .active && !controller.busy && !onPhone { Task { await controller.refresh() } } }
    }
    @ViewBuilder private var page: some View {
        // Signed in on this iPhone: the state is read here, never from the server.
        let saved = store.providerSettings.trakt
        let connected = onPhone ? store.traktSignedInOnPhone : controller.status?.connected == true
        let reconnect = !onPhone && controller.status?.needsReconnect == true
        let username = onPhone ? saved.username : controller.status?.username
        let synced = DiaryDate.parse(onPhone ? saved.lastSyncedAt : controller.status?.lastSyncAt).map { "Last synced " + $0.formatted(date: .abbreviated, time: .shortened) }
        SettingsServiceHeader(logo: .trakt, title: reconnect ? "Reconnect Trakt" : "Trakt",
                              subtitle: synced ?? (!onPhone && controller.loading ? "Checking connection…" : connected ? "Connected" : "Your watches, together"),
                              badge: reconnect ? ("Reconnect", .missing) : connected ? (username.map { "@" + $0 } ?? "Connected", .good) : nil) {
            Text(connected ? (store.traktHoldsDiary ? "Trakt holds your diary. Your edits go straight to Trakt." : "Signed in on this iPhone.")
                 : "Sign in to Trakt in Profile → Connections.")
                .font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if connected {
            TrackerPreviewPanel(tracker: .trakt)
            SettingsGroup(label: "Options") {
                Toggle(isOn: Binding(get: { traktDirect.instantSync }, set: { on in
                    traktDirect.instantSync = on
                    // Back on: send whatever waited.
                    if on && !traktDirect.pending.isEmpty { Task { await traktDirect.check(store: store) } }
                })) {
                    optionLabel("Instant sync", traktDirect.instantSync ? "Send edits as you make them" : "Edits wait for the next sync")
                }.padding(.horizontal, 15).frame(minHeight: 64).accessibilityIdentifier("trakt-instant-sync")
                SettingsDivider()
                Toggle(isOn: $applyRemovals) {
                    optionLabel("Removals on Trakt", applyRemovals ? "Something removed on Trakt leaves your diary too" : "Your diary puts back what Trakt no longer has")
                }.padding(.horizontal, 15).frame(minHeight: 64).accessibilityIdentifier("sync-apply-removals")
                SettingsDivider()
                SettingsRow(title: "Pending requests", subtitle: "Waiting to be sent") {
                    SettingsBadge(text: traktDirect.pending.isEmpty ? "None" : traktDirect.pending.count.formatted(), tone: traktDirect.pending.isEmpty ? .good : .missing)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("trakt-pending-requests")
                SettingsDivider()
                SettingsRow(title: "Force sync", subtitle: "Re-check everything") {
                    Button(traktDirect.running ? "Running…" : "Run") { Task { await traktDirect.forceCheck(store: store) } }
                        .buttonStyle(SettingsPillButtonStyle()).disabled(traktDirect.running || traktDirect.writing)
                        .accessibilityIdentifier("trakt-force-sync")
                }
                SettingsDivider()
                NavigationLink { ServiceLimitsView(tracker: .trakt) } label: {
                    SettingsRow(title: "Account limits", subtitle: "What your plan allows and what you use") { SettingsChevron() }
                }.buttonStyle(.plain).accessibilityIdentifier("trakt-account-limits")
            }
            if onPhone {
                SettingsFootnote(text: "Sign out of Trakt in Profile → Connections.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsLabel(text: "Account") { EmptyView() }
                    Button("Disconnect Trakt", role: .destructive) { Task { await controller.disconnect() } }
                        .buttonStyle(SettingsDestructiveButtonStyle()).disabled(controller.busy).accessibilityIdentifier("trakt-disconnect")
                    SettingsFootnote(text: "Your diary stays on Trakt. You can connect again any time.")
                }
            }
        }
    }
    private var traktDirect: TraktDirectStore { .shared }
    private func optionLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    /// Trakt signed in on this iPhone, or no server at all: read here, never asked of the server.
    private var onPhone: Bool { store.phoneOnly || store.traktSignedInOnPhone }
}
