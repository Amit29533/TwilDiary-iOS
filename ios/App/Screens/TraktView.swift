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
        SettingsServiceHeader(logo: .trakt, title: "Trakt", subtitle: synced ?? (connected ? "Connected" : "Your watches, together"),
                              badge: connected ? (saved.username.map { "@" + $0 } ?? "Connected", .good) : nil) {
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
            SettingsFootnote(text: "Sign out of Trakt in Profile → Connections.")
        }
    }
    private var traktDirect: TraktDirectStore { .shared }
    private func optionLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
