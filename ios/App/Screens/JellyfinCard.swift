import SwiftUI
import TwilDiaryCore

/// Files & drives: Jellyfin as a source of folder locations. Shows which libraries are read
/// (Movies and Shows; photos, home videos and music never), the last sync, and Sync now.
struct JellyfinCard: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var sync: JellyfinSync?
    @State private var setup = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                BrandLogo(service: .jellyfin, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jellyfin").font(.system(size: 16, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                if sync?.configured == true {
                    Button { Task { await sync?.run() } } label: {
                        if sync?.running == true { ProgressView().controlSize(.small).frame(width: 44, height: 44) } else { RoundTool(icon: "refresh-cw") }
                    }.buttonStyle(.springPress).disabled(sync?.running == true || store.writesBlocked).accessibilityLabel("Sync with Jellyfin").accessibilityIdentifier("jellyfin-sync")
                }
            }
            if sync?.configured == true {
                if let libraries = sync?.libraries, !libraries.isEmpty {
                    let readable = libraries.filter(\.readable), skipped = libraries.count - readable.count
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(readable) { library in
                                let on = sync?.isOn(library) == true
                                Button { sync?.toggle(library) } label: {
                                    HStack(spacing: 6) { Image(systemName: on ? "checkmark" : "plus").font(.system(size: 11, weight: .bold)); Text(library.name) }
                                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(on ? theme.accent : Color(webHex: "#c5c0cf"))
                                        .padding(.horizontal, 12).frame(height: 32).background(on ? theme.accent.opacity(0.12) : .white.opacity(0.06), in: Capsule())
                                        .overlay(Capsule().strokeBorder(on ? theme.accent.opacity(0.5) : .white.opacity(0.12)))
                                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : []).accessibilityIdentifier("jellyfin-library-" + library.id)
                            }
                        }
                    }.scrollIndicators(.hidden)
                    if skipped > 0 { caption("\(skipped.counted("other library", "other libraries")) (photos, home videos, music) never read") }
                }
                // Everything on Jellyfin, not just what's mapped: filters for the diary and drives.
                NavigationLink(value: AppDestination.jellyfin) { Text("Browse Jellyfin →").font(.system(size: 13, weight: .semibold)) }
                    .accessibilityIdentifier("jellyfin-browse")
                if let progress = sync?.progress { caption(progress) }
                if let summary = sync?.summary, sync?.running != true {
                    caption("\(summary.mapped.counted("title", "titles")) mapped · \(summary.notInDiary.formatted()) not in your diary · \(summary.personal.counted("personal item", "personal items")) skipped")
                        .accessibilityIdentifier("jellyfin-summary")
                }
                if let error = sync?.error { Text(error).font(.system(size: 12)).foregroundStyle(Color(webHex: "#ff8a80")) }
            } else {
                Button("Connect Jellyfin") { setup = true }.buttonStyle(.diaryRowPrimary).accessibilityIdentifier("jellyfin-connect")
            }
        }.padding(16).diarySectionBackground(radius: 16)
            .task { if sync == nil { sync = JellyfinSync(store: store) }; await sync?.loadLibraries() }
            .sheet(isPresented: $setup, onDismiss: { Task { await sync?.loadLibraries() } }) { JellyfinSetupSheet() }
            .accessibilityElement(children: .contain).accessibilityIdentifier("jellyfin-card")
    }
    private var subtitle: String {
        guard sync?.configured == true else { return "Map your Movies and Shows folders from Jellyfin" }
        if let summary = sync?.summary { return "Synced " + summary.at.formatted(.relative(presentation: .named)) }
        return "Ready to sync over your home Wi-Fi"
    }
    private func caption(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}
