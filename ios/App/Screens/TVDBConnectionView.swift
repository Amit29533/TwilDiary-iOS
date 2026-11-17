import SwiftUI

struct TVDBConnectionView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var checking = false
    @State private var verified = false
    @State private var editing = false
    @State private var input = ""
    @State private var error: String?
    @State private var note: String?

    private var custom: Bool { store.providerSettings.customTvdbKey != nil }
    private var newKey: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var keySource: String {
        if custom { return "Uses your own API key." }
        if store.isPreview || TVDBDirect.builtIn != nil { return "Uses TwilDiary’s built-in key." }
        return "Add a TheTVDB API key to connect."
    }

    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 14) {
                SettingsServiceHeader(logo: .tvdb, title: "TheTVDB", subtitle: "Awards, nominees and winners",
                                      badge: checking ? ("Checking…", .plain) : verified ? ("Connected", .good) : ("Not connected", .missing)) {
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                    layout {
                        Button(checking ? "Checking…" : "Check connection") { Task { await check() } }
                            .buttonStyle(SettingsWideButtonStyle()).disabled(checking)
                            .accessibilityIdentifier("tvdb-check-connection")
                        Button(editing ? "Hide" : "Change API key") {
                            input = ""; error = nil; note = nil
                            withAnimation(Motion.smooth) { editing.toggle() }
                        }.buttonStyle(SettingsWideButtonStyle(outlined: true)).disabled(checking)
                            .accessibilityIdentifier("tvdb-api-toggle")
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("tvdb-connection-error")
                    }
                    if let note {
                        Text(note).font(.footnote).foregroundStyle(Color(themed: "#7fe0b5"))
                            .accessibilityIdentifier("tvdb-api-saved")
                    }
                }
                HStack(spacing: 4) {
                    SettingsFootnote(text: keySource)
                    SettingsInfoButton(text: "TwilDiary reads TheTVDB directly. A key you enter here takes priority over the built-in key.")
                        .padding(.vertical, -10)
                }
                if editing { keyEditor }
                Link("TheTVDB", destination: URL(string: "https://www.thetvdb.com/")!)
                    .font(.footnote).foregroundStyle(ThemeStore.accent).frame(minHeight: 44)
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 100)
        }.diaryScreenBackground()
            .navigationTitle("TheTVDB").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .task { await check() }
    }

    private var keyEditor: some View {
        SettingsGroup(label: "Your own key") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enter a TheTVDB v4 project API key.").font(.footnote).foregroundStyle(HomeStyle.secondary)
                SecureField("TheTVDB API key", text: $input).settingsField(monospaced: true)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(checking)
                    .accessibilityIdentifier("tvdb-api-key-field")
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    Button("Save") { Task { await check(replacingWith: newKey) } }
                        .buttonStyle(SettingsWideButtonStyle()).disabled(newKey.isEmpty || checking)
                        .accessibilityIdentifier("tvdb-api-save")
                    if custom {
                        Button("Use built-in key") {
                            guard store.updateCustomTvdbKey(nil) else { error = store.error; return }
                            input = ""; editing = false; verified = false
                            Task { await check() }
                        }.buttonStyle(SettingsWideButtonStyle(outlined: true)).disabled(checking)
                            .accessibilityIdentifier("tvdb-api-reset")
                    }
                }
            }.padding(15)
        }.accessibilityIdentifier("tvdb-api-panel")
    }

    private func check(replacingWith replacement: String? = nil) async {
        guard !checking else { return }
        checking = true; error = nil; note = nil
        defer { checking = false }
        do {
            if !store.isPreview {
                guard let key = replacement ?? TVDBDirect.key(store) else {
                    throw APIError.message("Add a TheTVDB API key to check the connection.")
                }
                try await TVDBDirect.checkConnection(key: key)
            }
            try Task.checkCancellation()
            if let replacement {
                guard store.updateCustomTvdbKey(replacement) else {
                    error = store.error
                    return
                }
                input = ""; editing = false
                note = "Your TheTVDB key is saved."
            }
            verified = true
        } catch {
            guard !Task.isCancelled else { return }
            if replacement == nil { verified = false }
            self.error = error.localizedDescription
        }
    }
}
