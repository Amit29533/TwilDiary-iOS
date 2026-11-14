import SwiftUI
import TwilDiaryCore

/// Settings → APIs: the keys the server uses (TMDB, Trakt, Cloudflare), replaceable from here and
/// stored encrypted; Jellyfin's address and key, kept on this iPhone; and the server address.
/// A key is never shown in full, only its last four characters.
struct APIsView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var model: APIKeysModel?
    @State private var editing: APIKeyStatus?
    @State private var removing: APIKeyStatus?
    @State private var editingJellyfin = false
    @State private var jellyfinRevision = 0
    /// The AI service a key is being added for.
    @State private var addingAIKey: SemanticSearch.Service?
    @State private var aiKeys: [SemanticSearch.Service: [String]] = Dictionary(uniqueKeysWithValues: SemanticSearch.Service.allCases.map { ($0, SemanticSearch.ownKeys($0)) })

    var body: some View {
        EdgeToEdgeScroll {
            // Design (board 10): one line with ⓘ, then each service: its name, its keys in one card.
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    Text(store.phoneOnly ? "Keys stay on this iPhone." : "Keys are stored encrypted.").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary)
                    Spacer(minLength: 0)
                    SettingsInfoButton(text: store.phoneOnly
                        ? "Keys are kept in this iPhone’s Keychain and sent only to their own service. Only their last four characters are ever shown."
                        : "Keys are sent to the server once and stored encrypted. Only their last four characters are ever shown. Removing a key goes back to the one set on the server.")
                }.padding(.leading, 4)
                if store.phoneOnly {
                    // No server sign-in: the keys this iPhone uses.
                    phoneKeys
                } else if let model, model.loaded, model.keys.isEmpty, let error = model.error {
                    // Nothing to list: one clear card instead of empty service sections.
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(themed: "#e7ca90")).accessibilityHidden(true)
                            Text("Keys couldn’t be loaded").font(.system(size: 15, weight: .semibold))
                        }
                        Text(error).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Try again") { Task { await model.load() } }.buttonStyle(.diaryRowSecondary)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(theme.field, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08))).accessibilityIdentifier("apis-unavailable")
                } else if let model, model.loaded {
                    if let error = model.error { Text(error).font(.system(size: 13)).foregroundStyle(Color(themed: "#ff8a80")) }
                    service(.tmdb, "TMDB", keys: model.keys.filter { $0.service == "tmdb" })
                    service(.trakt, "Trakt", keys: model.keys.filter { $0.service == "trakt" }, note: "A new client ID signs Trakt out.")
                    service(.cloudflare, "Cloudflare", keys: model.keys.filter { $0.service == "cloudflare" })
                    let signIn = model.keys.filter { $0.service == "mdblist" }
                    if !signIn.isEmpty {
                        service(nil, "Sign-in apps", icon: "iphone", keys: signIn, note: "App ID for MDBList sign-in.",
                                info: "TwilDiary’s own app ID for MDBList. Once it’s set, MDBList’s page offers “Sign in” without your own developer keys.")
                    }
                } else if model?.error == nil { ProgressView().frame(maxWidth: .infinity, minHeight: 160) }
                if !store.phoneOnly { aiSection(.gemini); aiSection(.groq); aiSection(.requesty) }
                jellyfin
                if !store.phoneOnly { server }
            }.padding(16).padding(.bottom, 100)
        }.diaryScreenBackground().navigationTitle("APIs").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .refreshable { await model?.load() }
            .task { if store.phoneOnly { return }; if model == nil { model = APIKeysModel(store: store) }; await model?.load() }
            .sheet(item: $addingAIKey, onDismiss: reloadAIKeys) { GeminiKeySheet(service: $0) }
            .sheet(item: $editing) { key in
                ReplaceKeySheet(key: key) { value in
                    // An error belongs in the sheet, not on the page hidden behind it.
                    guard let model else { return "Not loaded yet" }
                    if await model.save(key.name, value: value) { return nil }
                    defer { model.error = nil }
                    return model.error ?? "The key couldn’t be saved."
                }
            }
            .sheet(isPresented: $editingJellyfin, onDismiss: { jellyfinRevision += 1 }) { JellyfinSetupSheet() }
            .alert("Go back to the server’s own key?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),  presenting: removing) { key in
                Button("Remove saved key", role: .destructive) { Task { await model?.remove(key.name) } }
                Button("Cancel", role: .cancel) {}
            }
    }

    private func service(_ brand: BrandLogo.Service?, _ name: String, icon: String = "key", keys: [APIKeyStatus], note: String? = nil, info: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            section(brand, name, icon: icon) {
                ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                    if index > 0 { SettingsDivider() }
                    keyRow(key)
                }
            }
            if let note {
                HStack(spacing: 6) {
                    Text(note).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    if let info { SettingsInfoButton(text: info) }
                }.padding(.leading, 4)
            }
        }
    }
    private func keyRow(_ key: APIKeyStatus) -> some View {
        let check = model?.checks[key.name], testing = model?.testing.contains(key.name) == true
        let (name, detail) = Self.splitLabel(key.label)
        // A short note stays beside the name ("(Simkl)"); a long one goes behind ⓘ, without the
        // server's old redirect (the line below shows the one in use).
        let note = detail.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
            .map { $0.components(separatedBy: ";").filter { !$0.lowercased().contains("redirect") }.joined(separator: ";").trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let inline = note.flatMap { $0.count <= 16 ? "(" + $0 + ")" : nil }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                (inline.map { tag in Text("\(name) \(Text(tag).foregroundStyle(HomeStyle.secondary).fontWeight(.regular))") } ?? Text(name))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2)
                if let note, inline == nil { SettingsInfoButton(text: note).padding(.vertical, -10) }
                Spacer(minLength: 8)
                sourcePill(key.source)
            }
            if key.service == "mdblist" {
                // The https return page (it hands the reply to the app), as the sign-in sends it.
                Text("Redirect: " + ProviderWebSignIn.redirect(for: .mdblist)).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            HStack(spacing: 8) {
                Text(key.hint.map { "••••" + $0 } ?? "No key").font(.system(size: 13, design: .monospaced)).foregroundStyle(HomeStyle.secondary)
                if let updated = key.updatedAt.flatMap({ DiaryDate.parse($0) }) { Text("· replaced " + updated.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
                Spacer(minLength: 0)
                if testing { ProgressView().controlSize(.small) }
                else if let check { status(check.ok, check.message).accessibilityIdentifier("api-status-" + key.name) }
            }
            HStack(spacing: 8) {
                Button("Replace") { editing = key }.buttonStyle(SettingsPillButtonStyle()).accessibilityIdentifier("api-replace-" + key.name)
                Button("Test") { Task { await model?.test(key.name) } }.buttonStyle(SettingsPillButtonStyle(outlined: true)).disabled(testing || key.source == "missing").accessibilityIdentifier("api-test-" + key.name)
                if key.source == "saved" { Button("Remove", role: .destructive) { removing = key }.buttonStyle(SettingsPillButtonStyle(outlined: true)).accessibilityIdentifier("api-remove-" + key.name) }
                Spacer(minLength: 0)
            }.padding(.top, 6)
        }.padding(15).accessibilityElement(children: .contain).accessibilityIdentifier("api-row-" + key.name)
    }
    /// "App client ID (MDBList)" → the name, and "(MDBList)" shown in grey.
    private static func splitLabel(_ label: String) -> (String, String?) {
        guard label.hasSuffix(")"), let open = label.lastIndex(of: "(") else { return (label, nil) }
        return (String(label[..<open]).trimmingCharacters(in: .whitespaces), String(label[open...]))
    }
    private func sourcePill(_ source: String) -> some View {
        switch source {
        case "saved": SettingsBadge(text: "Saved here", tone: .configured)
        case "server": SettingsBadge(text: "Server secret", tone: .plain)
        default: SettingsBadge(text: "Not set", tone: .missing)
        }
    }
    /// "Ready", "2 of 3 ready", or "Resting until 17:05 · daily limit" when nothing can answer now.
    @ViewBuilder private func healthBadge(_ health: SemanticSearch.Health, keys: Int) -> some View {
        if health.total > 0, health.ready == 0, let back = health.back {
            HStack(spacing: 5) { Circle().fill(Color(themed: "#f5c26b")).frame(width: 6, height: 6); Text("Back " + back.formatted(date: .omitted, time: .shortened) + (health.why.map { " · " + $0 } ?? "")) }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(themed: "#f5c26b")).lineLimit(1)
        } else if health.ready < health.total {
            status(true, "\(health.ready) of \(health.total) ready")
        } else {
            status(true, keys > 1 ? "\(keys) keys · ready" : "Ready")
        }
    }
    private func status(_ ok: Bool, _ message: String) -> some View {
        HStack(spacing: 5) { Circle().fill(ok ? Color(themed: "#7fe0b5") : Color(themed: "#ff6b6b")).frame(width: 6, height: 6); Text(message) }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(ok ? Color(themed: "#7fe0b5") : Color(themed: "#ff8a80")).lineLimit(1)
    }

    private var jellyfin: some View {
        let _ = jellyfinRevision
        let configured = store.isPreview || JellyfinSettings.configured
        return section(.jellyfin, "Jellyfin", icon: "") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Server").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                    Spacer(minLength: 8)
                    SettingsBadge(text: "On this iPhone", tone: .plain)
                }
                Text(store.isPreview ? "http://192.168.1.20:8096 · ●●●●a41f" : JellyfinSettings.address.map { $0.absoluteString + (JellyfinSettings.keyHint.map { " · ●●●●" + $0 } ?? " · no key") } ?? "Not set up")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(HomeStyle.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("Read over your home Wi-Fi.").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                    SettingsInfoButton(text: "Jellyfin is read over your home Wi-Fi to map Movies and Shows folders. The key stays on this iPhone.")
                }
                Button(configured ? "Edit" : "Set up") { editingJellyfin = true }.buttonStyle(SettingsPillButtonStyle()).accessibilityIdentifier("jellyfin-setup")
            }.padding(15)
        }
    }
    /// TMDB (TwilDiary's own key, or yours) and Gemini for search by description.
    private var phoneKeys: some View {
        VStack(alignment: .leading, spacing: 20) {
            section(.tmdb, "TMDB", icon: "film") {
                HStack(spacing: 8) {
                    Text(store.providerSettings.customTmdbToken == nil ? "TwilDiary’s key, built in" : "Your own key").font(.system(size: 14)).foregroundStyle(HomeStyle.primary)
                    Spacer(minLength: 0)
                    status(TMDBDirect.token(store) != nil, TMDBDirect.token(store) != nil ? "Ready" : "Missing")
                }.padding(15)
            }
            aiSection(.gemini)
            aiSection(.groq)
            aiSection(.requesty)
        }
    }
    /// Gemini: AI search and CineMind.
    private func reloadAIKeys() {
        for service in SemanticSearch.Service.allCases { aiKeys[service] = SemanticSearch.ownKeys(service) }
    }
    /// Gemini and Groq: AI search and CineMind. Each takes several keys, used in turn; Groq
    /// answers when Gemini can't.
    private func aiSection(_ service: SemanticSearch.Service) -> some View {
        let keys = aiKeys[service] ?? []
        let set = !keys.isEmpty || (service == .gemini && SemanticSearch.keys.first != nil)
        return section(nil, service.name, icon: service == .gemini ? "sparkles" : service == .groq ? "bolt.fill" : "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(service == .gemini ? "AI search and CineMind" : service == .groq ? "Backup when Gemini can’t answer" : "Last backup, many models").font(.system(size: 14)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                    Spacer(minLength: 0)
                    if set { healthBadge(SemanticSearch.health(service), keys: max(1, keys.count)) } else { status(false, "Not set") }
                }
                HStack(spacing: 8) {
                    Text(service == .gemini ? "Lighter model first, then your other keys" : service == .groq ? "Free key, fast open models" : "Free models, 200 requests a day").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    SettingsInfoButton(text: service == .gemini
                        ? "Kept in this iPhone’s Keychain. Each request starts with the next key; if one is used up, the next key answers. Keys share a limit when they’re from the same Google project, so make each in a different project."
                        : service == .groq ? "Kept in this iPhone’s Keychain. When every Gemini key is used up or busy, Groq answers instead, with its keys in turn."
                        : "Kept in this iPhone’s Keychain. Asked when Gemini and Groq can’t answer, starting with your own model (if you set one) and then Requesty’s free models.")
                }
                ForEach(keys, id: \.self) { key in
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary)
                        Text(SemanticSearch.masked(key)).font(.system(size: 14, design: .monospaced)).foregroundStyle(HomeStyle.primary)
                        Spacer(minLength: 0)
                        Button(role: .destructive) { SemanticSearch.removeKey(key, from: service); reloadAIKeys() } label: {
                            Image(systemName: "trash").font(.system(size: 14)).frame(width: 36, height: 36).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(Color(themed: "#ff8a80")).accessibilityLabel("Remove key " + SemanticSearch.masked(key))
                    }.padding(.horizontal, 12).frame(height: 44).background(Color(themed: "#17171d"), in: RoundedRectangle(cornerRadius: 12))
                }
                if service == .requesty, !keys.isEmpty { RequestyModelField() }
                Button(keys.isEmpty ? "Add \(service.name) key" : "Add another key") { addingAIKey = service }
                    .buttonStyle(SettingsPillButtonStyle()).accessibilityIdentifier("apis-" + service.rawValue)
            }.padding(15)
        }
    }
    private var server: some View {
        section(nil, "TwilDiary server", icon: "server.rack") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(BackendEndpoint.production.host ?? "").font(.system(size: 13, design: .monospaced)).foregroundStyle(HomeStyle.primary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    // The diary itself proves the connection; a keys error (an older server) doesn't mean it's down.
                    let online = !store.phoneOnly && store.hasLoadedWorkspace && store.error == nil
                    status(online, store.phoneOnly ? "Not signed in" : online ? "Connected" : "Not connected")
                }
                HStack(spacing: 6) {
                    Text("Fixed in the app.").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                    SettingsInfoButton(text: "Your sign-in is only ever sent to this address, so it can’t be changed in the app.")
                }
            }.padding(15)
        }
    }
    /// A service: a 24 pt tile (its logo, or a symbol) and its name, then its card.
    private func section<Content: View>(_ brand: BrandLogo.Service?, _ name: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Group {
                    if let brand { BrandLogo(service: brand, size: 18) }
                    else { Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(HomeStyle.chipText) }
                }.frame(width: 24, height: 24).background(HomeStyle.chip, in: RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
                Text(name).font(.system(size: 15, weight: .bold)).foregroundStyle(HomeStyle.primary)
            }.padding(.leading, 4).accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0, content: content).frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsCard())
        }
    }
}

/// Paste a new key: a hidden field, Save checks it with its service straight after.
private struct ReplaceKeySheet: View {
    let key: APIKeyStatus
    /// nil when saved; otherwise what went wrong.
    let save: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var value = ""
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Paste the new \(key.label.lowercased()). It’s checked with the service as soon as it’s saved.").font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("New key", text: $value).font(.system(size: 15, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused).padding(.horizontal, 14).frame(height: 48).background(theme.field, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12))).accessibilityIdentifier("api-key-field")
                if let failure { Text(failure).font(.system(size: 13)).foregroundStyle(Color(themed: "#ff8a80")).fixedSize(horizontal: false, vertical: true) }
                Button {
                    saving = true
                    Task { failure = await save(value); saving = false; if failure == nil { dismiss() } }
                } label: { Text(saving ? "Saving…" : "Save and test").frame(maxWidth: .infinity) }
                    .buttonStyle(.diaryPrimary).disabled(saving || value.trimmingCharacters(in: .whitespaces).count < 8).accessibilityIdentifier("api-key-save")
                Spacer(minLength: 0)
            }.padding(20)
                .navigationTitle(key.label).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .onAppear { focused = true }
        }.presentationDetents([.height(300)]).presentationDragIndicator(.visible)
    }
}

/// Jellyfin's address and API key, tested against the server before they're kept.
struct JellyfinSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var address = ""
    @State private var key = ""
    @State private var checking = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            EdgeToEdgeScroll {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) { BrandLogo(service: .jellyfin, size: 30); Text("Connect Jellyfin").font(.system(size: 17, weight: .semibold)) }
                    Text("Use the address you open Jellyfin with at home, such as 192.168.1.20:8096. Create a key in Jellyfin under Dashboard → API Keys.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    field("Address", text: $address, secure: false).keyboardType(.URL).accessibilityIdentifier("jellyfin-address")
                    field(JellyfinSettings.keyHint.map { "API key (••••\($0) kept if empty)" } ?? "API key", text: $key, secure: true).accessibilityIdentifier("jellyfin-key")
                    if let message { Text(message).font(.system(size: 13)).foregroundStyle(message.hasPrefix("Connected") ? Color.mint : Color(themed: "#ff8a80")) }
                    Button { Task { await connect() } } label: { Text(checking ? "Checking…" : "Test and save").frame(maxWidth: .infinity) }
                        .buttonStyle(.diaryPrimary).disabled(checking || JellyfinSettings.normalized(address) == nil || (key.isEmpty && JellyfinSettings.apiKey == nil))
                        .accessibilityIdentifier("jellyfin-save")
                    if JellyfinSettings.configured {
                        Button("Forget Jellyfin on this iPhone", role: .destructive) { JellyfinSettings.forget(); dismiss() }.font(.system(size: 14)).frame(maxWidth: .infinity, minHeight: 44)
                    }
                }.padding(20)
            }.navigationTitle("Jellyfin").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .onAppear { address = JellyfinSettings.address?.absoluteString ?? "" }
        }.presentationDetents([.height(480)]).presentationDragIndicator(.visible)
    }
    private func field(_ title: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure { SecureField(title, text: text) } else { TextField(title, text: text) }
        }.font(.system(size: 15, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(.horizontal, 14).frame(height: 48).background(theme.field, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
    }
    private func connect() async {
        guard let url = JellyfinSettings.normalized(address) else { return }
        checking = true; defer { checking = false }
        if store.isPreview { message = "Connected to Jelly"; return }
        let candidate = key.isEmpty ? (JellyfinSettings.apiKey ?? "") : key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let info = try await JellyfinClient(base: url, key: candidate).server()
            try JellyfinSettings.save(address: url, apiKey: key.isEmpty ? nil : candidate)
            message = "Connected to " + (info.ServerName ?? "Jellyfin")
            try? await Task.sleep(for: .seconds(0.8)); dismiss()
        } catch { message = error.localizedDescription }
    }
}

/// Requesty's model (or "policy/…" routing policy) to ask first; empty uses its free models.
private struct RequestyModelField: View {
    @State private var value = SemanticSearch.requestyModel ?? ""
    var body: some View {
        TextField("Model (optional), e.g. google/gemini-flash", text: $value)
            .font(.system(size: 14, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(.horizontal, 12).frame(height: 44).background(Color(themed: "#17171d"), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: value) { _, now in SemanticSearch.requestyModel = now }
            .accessibilityIdentifier("apis-requesty-model")
    }
}
