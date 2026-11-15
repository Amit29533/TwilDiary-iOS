import SwiftUI
import TwilDiaryCore

/// AniList's page → Sync (phase 1): the one-time app setup, sign-in, "Also save my activity to
/// AniList", what's waiting, Send everything, and what AniList couldn't take.
struct AniListSyncSection: View {
    @State private var account = AniListSyncAccount.shared
    @State private var sync = AniListSync.shared
    @Environment(DiaryStore.self) private var store
    @Environment(\.webAuthenticationSession) private var webSession
    @State private var clientDraft = ""
    @State private var working = false
    @State private var message: String?
    @State private var confirmEverything = false
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(label: "Sync", info: "Copies your anime activity to AniList as you log it: each season’s progress, status, score and dates. Your diary keeps every watch; AniList keeps no watch history. Nothing is sent until you turn it on.") {
                if account.signedIn {
                    SettingsRow(title: account.username.map { "@" + $0 } ?? "Signed in",
                                subtitle: account.expiresAt.map { "Signed in until " + $0.formatted(date: .abbreviated, time: .omitted) }) {
                        Button("Sign out") { account.signOut() }.buttonStyle(SettingsPillButtonStyle(outlined: true)).lineLimit(1)
                    }.accessibilityIdentifier("anilist-sync-account")
                    SettingsDivider()
                    Toggle(isOn: $account.saving) { SettingsRowTitle("Also save my activity to AniList", "") }
                        .settingsRowFrame().accessibilityIdentifier("anilist-sync-saving")
                    SettingsDivider()
                    SettingsRow(title: "Send everything", subtitle: "Your anime diary, once; about two seconds a title") {
                        Button("Send") { confirmEverything = true }.buttonStyle(SettingsPillButtonStyle()).lineLimit(1)
                            .disabled(!account.saving || sync.sending)
                    }.accessibilityIdentifier("anilist-sync-everything")
                } else {
                    if (account.clientId ?? "").isEmpty {
                        TextField("AniList app client ID", text: $clientDraft).font(.system(size: 17, design: .monospaced))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numberPad)
                            .submitLabel(.done).onSubmit(saveClient).settingsRowFrame().accessibilityIdentifier("anilist-sync-client")
                        SettingsDivider()
                        Link(destination: URL(string: "https://anilist.co/settings/developer")!) {
                            SettingsRow(title: "AniList developer page") {
                                Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(uiColor: .tertiaryLabel))
                            }
                        }.buttonStyle(.plain)
                        SettingsDivider()
                    }
                    SettingsRow(title: "Not signed in") {
                        Button(working ? "Opening…" : "Sign in") {
                            if (account.clientId ?? "").isEmpty { saveClient() }
                            Task { await signIn() }
                        }.buttonStyle(SettingsPillButtonStyle()).lineLimit(1).disabled(working).accessibilityIdentifier("anilist-sync-sign-in")
                    }
                }
            }
            if !account.signedIn, (account.clientId ?? "").isEmpty {
                SettingsFootnote(text: "One-time setup: on AniList’s developer page, create an app with the redirect \(AniListSyncAccount.redirect), then paste its client ID above.")
            }
            if !sync.waiting.isEmpty || sync.lastProblem != nil {
                SettingsGroup(label: "Waiting") {
                    SettingsRow(title: sync.sending ? "Sending \(sync.waiting.count.formatted())…" : "\(sync.waiting.count.formatted()) waiting",
                                subtitle: sync.lastProblem) {
                        Button("Send now") { Task { await sync.resume(store: store) } }.buttonStyle(SettingsPillButtonStyle()).lineLimit(1)
                            .disabled(sync.sending || !account.canSend)
                    }
                    if let progress = sync.progress, progress.total > 0 {
                        SendProgressBar(fraction: Double(progress.done) / Double(progress.total)).padding(.horizontal, 16).padding(.bottom, 12)
                    }
                }
            }
            if !sync.notKept.isEmpty {
                SettingsGroup(label: "Not kept on AniList", info: "AniList couldn’t take these, or TwilDiary couldn’t tell where they go. Everything else carries on.") {
                    ForEach(Array(sync.notKept.prefix(30).enumerated()), id: \.element.id) { index, item in
                        if index > 0 { SettingsDivider() }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                            Text(item.reason).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    SettingsDivider()
                    Button("Clear this list") { sync.clearNotKept() }.font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
            }
            if let message { SettingsFootnote(text: message) }
            if account.signedIn || !(account.clientId ?? "").isEmpty {
                Button(role: .destructive) { confirmRemove = true } label: {
                    Text("Disconnect AniList sync").font(.system(size: 17)).frame(maxWidth: .infinity, minHeight: 52)
                }.buttonStyle(.plain).foregroundStyle(.red).cardSurface(16).accessibilityIdentifier("anilist-sync-remove")
            }
        }
        .onAppear { clientDraft = account.clientId ?? "" }
        .task { await sync.resume(store: store) }
        .confirmationDialog("Send your whole anime diary to AniList?", isPresented: $confirmEverything, titleVisibility: .visible) {
            Button("Send everything") { sync.sendEverything(store: store) }
        } message: {
            Text("Each anime’s seasons get their progress, status, score and dates on AniList, about two seconds a title, in the background. Entries already on AniList are updated to match your diary.")
        }
        .confirmationDialog("Disconnect the AniList sync?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Disconnect and remove", role: .destructive) { account.removeEverything(); clientDraft = ""; message = "AniList sync is disconnected and removed from this iPhone. Nothing on AniList changed." }
        } message: {
            Text("Signs out and deletes what TwilDiary kept for the AniList sync on this iPhone. Your AniList list stays as it is.")
        }
    }

    private func saveClient() {
        let id = clientDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { account.clientId = id }
    }
    private func signIn() async {
        working = true; message = nil
        defer { working = false }
        do {
            if try await account.signIn(using: webSession) { message = "Signed in. Turn on “Also save my activity to AniList”, then Send everything once." }
        } catch { message = error.localizedDescription }
    }
}
