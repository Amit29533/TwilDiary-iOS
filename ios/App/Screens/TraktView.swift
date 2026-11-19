import SwiftUI
import TwilDiaryCore

/// Trakt: your sign-in on this iPhone, the Trakt diary's options and its limits.
@MainActor struct TraktView: View {
    let store: DiaryStore
    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 16) { page }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 100)
        }.diaryScreenBackground().navigationTitle("Trakt").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
    @ViewBuilder private var page: some View {
        let saved = store.providerSettings.trakt
        let connected = store.traktSignedInOnPhone
        let synced = DiaryDate.parse(saved.lastSyncedAt).map { "Last synced " + $0.formatted(date: .abbreviated, time: .shortened) }
        SettingsServiceHeader(logo: .trakt, title: "Trakt", subtitle: synced ?? (connected ? "Connected" : ""),
                              badge: connected ? (saved.username.map { "@" + $0 } ?? "Connected", .good) : nil) {
            if !connected {
                Text("Sign in to Trakt in Profile → Connections.")
                    .font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if connected {
            if ThemeStore.current.native && !store.traktHoldsDiary {
                TrackerPreviewPanel(tracker: .trakt, trailingOptions: AnyView(traktOptions))
            } else {
                TrackerPreviewPanel(tracker: .trakt)
                SettingsGroup(label: "Options") { traktOptions }
            }
        }
    }
    @ViewBuilder private var traktOptions: some View {
                Toggle(isOn: Binding(get: { traktDirect.instantSync }, set: { on in
                    traktDirect.instantSync = on
                    // Back on: send whatever waited.
                    if on && !traktDirect.pending.isEmpty { Task { await traktDirect.check(store: store) } }
                })) {
                    optionLabel("Instant sync")
                }.settingsRowFrame().accessibilityIdentifier("trakt-instant-sync")
                SettingsDivider()
                SettingsRow(title: "Pending requests") {
                    SettingsBadge(text: traktDirect.pending.isEmpty ? "None" : traktDirect.pending.count.formatted(), tone: traktDirect.pending.isEmpty ? .good : .missing)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("trakt-pending-requests")
                SettingsDivider()
                SettingsRow(title: "Force sync") {
                    Button(traktDirect.running ? "Running…" : "Run") { Task { await traktDirect.forceCheck(store: store) } }
                        .buttonStyle(SettingsPillButtonStyle()).disabled(traktDirect.running || traktDirect.writing)
                        .accessibilityIdentifier("trakt-force-sync")
                }
                SettingsDivider()
                NavigationLink { ServiceLimitsView(tracker: .trakt) } label: {
                    SettingsRow(title: "Account limits") { SettingsChevron() }
                }.buttonStyle(.plain).accessibilityIdentifier("trakt-account-limits")
    }
    private var traktDirect: TraktDirectStore { .shared }
    private func optionLabel(_ title: String) -> some View {
        let native = ThemeStore.current.native
        return VStack(alignment: .leading, spacing: native ? 1 : 2) {
            Text(title).font(.system(size: native ? 17 : 15, weight: native ? .regular : .semibold)).foregroundStyle(HomeStyle.primary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
