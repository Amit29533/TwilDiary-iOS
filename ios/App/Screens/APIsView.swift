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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Keys are sent to the server once and stored encrypted. Only their last four characters are ever shown. Removing a key goes back to the one set on the server.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let model, model.loaded, model.keys.isEmpty, let error = model.error {
                    // Nothing to list: one clear card instead of empty service sections.
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(webHex: "#e7ca90")).accessibilityHidden(true)
                            Text("Keys couldn’t be loaded").font(.system(size: 15, weight: .semibold))
                        }
                        Text(error).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Try again") { Task { await model.load() } }.buttonStyle(.diaryRowSecondary)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(theme.field, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08))).accessibilityIdentifier("apis-unavailable")
                } else if let model, model.loaded {
                    if let error = model.error { Text(error).font(.system(size: 13)).foregroundStyle(Color(webHex: "#ff8a80")) }
                    service(.tmdb, "TMDB", keys: model.keys.filter { $0.service == "tmdb" })
                    service(.trakt, "Trakt", keys: model.keys.filter { $0.service == "trakt" }, note: "A new client ID signs Trakt out; connect again from the Trakt page.")
                    service(nil, "Cloudflare", keys: model.keys.filter { $0.service == "cloudflare" })
                } else if model?.error == nil { ProgressView().frame(maxWidth: .infinity, minHeight: 160) }
                jellyfin
                server
            }.padding(16).padding(.bottom, 100)
        }.diaryScreenBackground().navigationTitle("APIs").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .refreshable { await model?.load() }
            .task { if model == nil { model = APIKeysModel(store: store) }; await model?.load() }
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
            .confirmationDialog("Go back to the server’s own key?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { key in
                Button("Remove saved key", role: .destructive) { Task { await model?.remove(key.name) } }
            }
    }

    private func service(_ brand: BrandLogo.Service?, _ name: String, keys: [APIKeyStatus], note: String? = nil) -> some View {
        section(brand, name, icon: "cloud.fill", tint: Color(webHex: "#F38020")) {
            ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                if index > 0 { divider }
                keyRow(key)
            }
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 12) }
        }
    }
    private func keyRow(_ key: APIKeyStatus) -> some View {
        let check = model?.checks[key.name], testing = model?.testing.contains(key.name) == true
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(key.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7"))
                Spacer(minLength: 8)
                sourcePill(key.source)
            }
            HStack(spacing: 8) {
                Text(key.hint.map { "••••" + $0 } ?? "No key").font(.system(size: 14, design: .monospaced)).foregroundStyle(.secondary)
                if let updated = key.updatedAt.flatMap({ DiaryDate.parse($0) }) { Text("· replaced " + updated.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if testing { ProgressView().controlSize(.small) }
                else if let check { status(check.ok, check.message).accessibilityIdentifier("api-status-" + key.name) }
            }
            HStack(spacing: 8) {
                Button("Replace") { editing = key }.buttonStyle(.diaryRowPrimary).accessibilityIdentifier("api-replace-" + key.name)
                Button("Test") { Task { await model?.test(key.name) } }.buttonStyle(.diaryRowSecondary).disabled(testing || key.source == "missing").accessibilityIdentifier("api-test-" + key.name)
                if key.source == "saved" { Button("Remove", role: .destructive) { removing = key }.buttonStyle(.diaryRowSecondary).accessibilityIdentifier("api-remove-" + key.name) }
                Spacer(minLength: 0)
            }
        }.padding(14).accessibilityElement(children: .contain).accessibilityIdentifier("api-row-" + key.name)
    }
    private func sourcePill(_ source: String) -> some View {
        let (text, tint): (String, Color) = switch source { case "saved": ("Saved here", theme.accent); case "server": ("Server secret", Color(webHex: "#c5c0cf")); default: ("Not set", Color(webHex: "#e7ca90")) }
        return Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).padding(.horizontal, 10).frame(height: 24).background(tint.opacity(0.14), in: Capsule())
    }
    private func status(_ ok: Bool, _ message: String) -> some View {
        HStack(spacing: 5) { Circle().fill(ok ? Color.mint : Color(webHex: "#ff6b6b")).frame(width: 6, height: 6); Text(message) }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(ok ? Color.mint : Color(webHex: "#ff8a80")).lineLimit(1)
    }

    private var jellyfin: some View {
        let _ = jellyfinRevision
        let configured = store.isPreview || JellyfinSettings.configured
        return section(.jellyfin, "Jellyfin", icon: "", tint: .clear) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Server").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7"))
                    Spacer(minLength: 8)
                    Text("On this iPhone").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(webHex: "#c5c0cf")).padding(.horizontal, 10).frame(height: 24).background(Color.white.opacity(0.08), in: Capsule())
                }
                Text(store.isPreview ? "http://192.168.1.20:8096 · ••••a41f" : JellyfinSettings.address.map { $0.absoluteString + (JellyfinSettings.keyHint.map { " · ••••" + $0 } ?? " · no key") } ?? "Not set up")
                    .font(.system(size: 14, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("Read over your home Wi-Fi to map Movies and Shows folders. The key stays on this iPhone.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(configured ? "Edit" : "Set up") { editingJellyfin = true }.buttonStyle(.diaryRowPrimary).accessibilityIdentifier("jellyfin-setup")
            }.padding(14)
        }
    }
    private var server: some View {
        section(nil, "TwilDiary server", icon: "server.rack", tint: Color(webHex: "#5E5CE6")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(BackendEndpoint.production.host ?? "").font(.system(size: 14, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    // The diary itself proves the connection; a keys error (an older server) doesn't mean it's down.
                    status(store.hasLoadedWorkspace && store.error == nil, store.hasLoadedWorkspace && store.error == nil ? "Connected" : "Not connected")
                }
                Text("Your sign-in is only ever sent to this address, so it can’t be changed in the app.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(14)
        }
    }
    private func section<Content: View>(_ brand: BrandLogo.Service?, _ name: String, icon: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let brand { BrandLogo(service: brand, size: 20) }
                else { Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).frame(width: 20, height: 20).background(tint.gradient, in: RoundedRectangle(cornerRadius: 5)).accessibilityHidden(true) }
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 4).accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0, content: content).background(theme.field, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
        }
    }
    private var divider: some View { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 14) }
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
                if let failure { Text(failure).font(.system(size: 13)).foregroundStyle(Color(webHex: "#ff8a80")).fixedSize(horizontal: false, vertical: true) }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) { BrandLogo(service: .jellyfin, size: 30); Text("Connect Jellyfin").font(.system(size: 17, weight: .semibold)) }
                    Text("Use the address you open Jellyfin with at home, such as 192.168.1.20:8096. Create a key in Jellyfin under Dashboard → API Keys.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    field("Address", text: $address, secure: false).keyboardType(.URL).accessibilityIdentifier("jellyfin-address")
                    field(JellyfinSettings.keyHint.map { "API key (••••\($0) kept if empty)" } ?? "API key", text: $key, secure: true).accessibilityIdentifier("jellyfin-key")
                    if let message { Text(message).font(.system(size: 13)).foregroundStyle(message.hasPrefix("Connected") ? Color.mint : Color(webHex: "#ff8a80")) }
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
