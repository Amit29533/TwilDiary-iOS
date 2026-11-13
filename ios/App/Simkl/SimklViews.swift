import SwiftUI

/// The add-on's row in Connections (the one line ConnectionsView has for it).
struct SimklConnectionsRow: View {
    @State private var account = SimklAccount.shared
    @State private var mirror = SimklMirror.shared
    var body: some View {
        SettingsGroup(label: "Also save to") {
            NavigationLink { SimklSettingsView() } label: {
                HStack(spacing: 14) {
                    BrandLogo(service: .simkl, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Simkl").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                }.padding(.horizontal, 15).frame(minHeight: 64).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("connections-simkl")
        }
    }
    private var subtitle: String {
        guard account.signedIn else { return "Not connected" }
        guard account.saving else { return "Connected · not saving" }
        let waiting = mirror.queue.jobs.count
        return waiting > 0 ? "Saving your activity · \(waiting) waiting" : "Saving your activity"
    }
}

/// Simkl's page: sign in, the "Also save my activity to Simkl" switch, what's waiting, what Simkl
/// couldn't take, and "Disconnect and remove".
struct SimklSettingsView: View {
    @State private var account = SimklAccount.shared
    @State private var mirror = SimklMirror.shared
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.webAuthenticationSession) private var webSession
    @State private var working = false
    @State private var message: String?
    @State private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsGroup(label: "Account") {
                    HStack(spacing: 14) {
                        BrandLogo(service: .simkl, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.signedIn ? (account.username.map { "@" + $0 } ?? "Signed in") : "Simkl")
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            Text(account.signedIn ? "Connected on this iPhone" : "Sign in to copy your activity to Simkl")
                                .font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                        }
                        Spacer(minLength: 4)
                        if !account.signedIn {
                            Button { Task { await signIn() } } label: {
                                Text(working ? "Opening…" : "Sign in").font(.system(size: 14, weight: .bold)).foregroundStyle(WatchStyle.ink)
                                    .padding(.horizontal, 14).frame(height: 34).background(WatchStyle.fill, in: Capsule())
                            }.buttonStyle(.plain).disabled(working).accessibilityIdentifier("simkl-sign-in")
                        }
                    }.padding(.horizontal, 15).frame(minHeight: 72)
                }
                if account.signedIn {
                    SettingsGroup {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Also save my activity to Simkl").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                Text("Works when you use another service").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                            }
                            Spacer(minLength: 4)
                            Toggle("", isOn: $account.saving).labelsHidden().tint(theme.accent).accessibilityIdentifier("simkl-saving")
                        }.padding(.horizontal, 15).frame(minHeight: 64)
                    }
                    SettingsFootnote(text: "Watches, removals, ratings and Planned, Watching, Completed, On hold and Dropped are copied as you make them, from now on. Your diary stays where it is; Simkl gets a copy.")
                    if !mirror.queue.jobs.isEmpty || mirror.lastProblem != nil {
                        SettingsGroup(label: "Waiting") {
                            HStack {
                                Text(mirror.sending ? "Sending \(mirror.queue.jobs.count)…" : "\(mirror.queue.jobs.count) waiting")
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                Spacer()
                                Button("Send now") { Task { await mirror.sendNow() } }.font(.system(size: 14, weight: .semibold)).tint(theme.accent)
                                    .disabled(mirror.sending || !account.saving)
                            }.padding(.horizontal, 15).frame(minHeight: 56)
                        }
                        if let problem = mirror.lastProblem { SettingsFootnote(text: problem) }
                    }
                }
                if !mirror.notKept.isEmpty {
                    SettingsGroup(label: "Not kept on Simkl", info: "Simkl couldn’t find these, even by air date. They aren’t sent again; the rest of your activity carries on.") {
                        ForEach(Array(mirror.notKept.prefix(30).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { SettingsDivider() }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                                Text(item.reason).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 15).padding(.vertical, 10)
                        }
                        SettingsDivider()
                        Button("Clear this list") { mirror.clearNotKept() }.font(.system(size: 14, weight: .semibold)).tint(theme.accent)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
                if let message { SettingsFootnote(text: message) }
                if account.signedIn || !mirror.queue.jobs.isEmpty || !mirror.notKept.isEmpty {
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Text("Disconnect and remove").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 50)
                    }.buttonStyle(.plain).foregroundStyle(.red).background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("simkl-remove")
                    SettingsFootnote(text: "Signs out and deletes everything TwilDiary kept for Simkl on this iPhone. Nothing on Simkl changes.")
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }.diaryScreenBackground().diaryPageNavigation("Simkl")
            .confirmationDialog("Disconnect Simkl and remove what TwilDiary kept for it?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Disconnect and remove", role: .destructive) { account.removeEverything(); message = "Simkl is disconnected and removed from this iPhone." }
            }
            .task { await mirror.resume() }
    }

    private func signIn() async {
        working = true; message = nil
        defer { working = false }
        do {
            if try await account.signIn(using: webSession) { message = "Signed in. Turn on “Also save my activity to Simkl” to start." }
        } catch { message = error.localizedDescription }
    }
}
