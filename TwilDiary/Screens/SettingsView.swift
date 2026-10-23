import SwiftUI
import TwilDiaryCore

struct SettingsView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var confirmSignOut = false
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(name: "More")
            Form {
                Section("Library") {
                    NavigationLink { FilesView() } label: { Label("Files & drives", systemImage: "externaldrive") }
                    NavigationLink { TrashView() } label: { Label("Trash", systemImage: "trash") }
                    NavigationLink { HistoryView() } label: { Label("Recently watched", systemImage: "clock") }
                }
                Section("Appearance") { Picker(selection: $theme) { ForEach(DiaryTheme.allCases) { value in Text(value.name).tag(value) } } label: { Label("Theme", systemImage: "moon") } }
                Section("Connections") {
                    LabeledContent("Backend", value: "Cloudflare")
                    LabeledContent("Diary", value: store.isPreview ? "UI test fixture" : "Your hosted diary")
                    Text("Your existing Trakt connection and sync data remain on the server. The native sync review screen is still being ported.").font(.caption).foregroundStyle(.secondary)
                }
                Section("About") {
                    LabeledContent("Version", value: "2.0 · Native preview")
                    Text("This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.caption).foregroundStyle(.secondary)
                }
                Section { Button("Sign out", role: .destructive) { confirmSignOut = true }.disabled(store.busy) }
            }.scrollContentBackground(.hidden)
        }.confirmationDialog("Sign out on this device? Your hosted diary stays saved.", isPresented: $confirmSignOut, titleVisibility: .visible) { Button("Sign out", role: .destructive) { store.signOut() } }
    }
}

struct FilesView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            ForEach(drives, id: \.self) { drive in
                Section("Drive " + drive) {
                    ForEach(store.workspace.locations.filter { $0.driveLetter == drive }) { location in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(store.title(location.titleId)?.name ?? "Title").font(.headline)
                            Text(location.evidence == "present" ? "Available on Server" : "Not Available on Server").font(.caption).foregroundStyle(location.evidence == "present" ? .green : .secondary)
                            Text(location.path).font(.caption.monospaced()).textSelection(.enabled)
                        }.padding(.vertical, 5)
                    }
                }
            }
        }.overlay { if drives.isEmpty { ContentUnavailableView("No mapped files", systemImage: "externaldrive", description: Text("Scan your drives from the existing PC app to link local copies.")) } }
            .navigationTitle("Files & drives").navigationBarBackButtonHidden().toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
    }
    private var drives: [String] { Set(store.workspace.locations.map(\.driveLetter)).sorted() }
}
