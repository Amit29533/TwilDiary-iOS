import SwiftUI
import UIKit
import TwilDiaryCore

struct FilesView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var showSearch = false
    @State private var selected = "all"
    @AppStorage("filesGrid") private var grid = false
    @State private var copied = ""
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                    ForEach(DiskSummary.make(activeLocations)) { disk in diskButton(disk) }
                    HStack { Text("Mapped folders").font(.system(size: 19, weight: .semibold)); Spacer(); CollectionLayoutToggle(grid: $grid, collection: "files"); Button("Browse titles →") { router.libraryDisk(selected) }.font(.caption.bold()) }
                    if selected != "all" { Button("All drives") { selected = "all" }.font(.caption.bold()) }
                    CollectionLayout(grid: grid) { ForEach(locations) { location in folderRow(location) } }
                    if locations.isEmpty { ContentUnavailableView("No mapped folders", systemImage: "folder", description: Text("Try another drive. Unmatched scanned folders can be linked in Fix mismatches.")) }
                    HStack(alignment: .top, spacing: 10) {
                        DiaryIcon(name: "info", size: 18)
                        VStack(alignment: .leading, spacing: 8) { Text("Availability reflects the last confirmed scan. Disconnected drives keep their mappings and never change watch history.").font(.system(size: 13)).foregroundStyle(.secondary); NavigationLink("Fix mismatches →", value: AppDestination.scanner).font(.system(size: 13, weight: .semibold)) }
                    }.diaryPanel()
                // Keep the final action above the floating tab bar, matching the web shell's bottom clearance.
                }.padding(14).padding(.bottom, 100)
            }.accessibilityIdentifier("files-content").refreshable { await store.refresh() }
        }.diaryScreenBackground().diaryPageNavigation("Files & drives", searchIdentifier: "search-files") { showSearch.toggle() }

    }
    private var activeLocations: [FileLocation] { let ids = Set(store.workspace.activeTitles.map(\.id)); return store.workspace.locations.filter { ids.contains($0.titleId) } }
    private var locations: [FileLocation] { activeLocations.filter { selected == "all" || $0.diskKey == selected || (selected.hasPrefix("drive:") && $0.driveLetter.uppercased() == String(selected.dropFirst(6))) } }
    private func diskButton(_ disk: DiskSummary) -> some View {
        Button { selected = selected == disk.key ? "all" : disk.key } label: {
            HStack(alignment: .top, spacing: 14) {
                DiaryIcon(name: "hard-drive", size: 23).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text(disk.letters.joined(separator: " / ") + " · " + disk.deviceName).font(.system(size: 14, weight: .semibold))
                    Text(disk.folders.counted("mapped folder", "mapped folders") + " · " + disk.titleCount.counted("title", "titles")).font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 5) { Circle().fill(disk.present > 0 ? Color.mint : .secondary).frame(width: 5, height: 5); Text(disk.evidence).font(.system(size: 12)).foregroundStyle(disk.present > 0 ? Color.mint : .secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(20).diarySectionBackground(radius: 16, fill: selected == disk.key ? theme.accent.opacity(0.12) : Color(webHex: "#111115"), stroke: selected == disk.key ? theme.accent.opacity(0.6) : .white.opacity(0.13), emphasized: selected == disk.key)
        }.buttonStyle(.plain).accessibilityAddTraits(selected == disk.key ? .isSelected : [])
    }
    private func folderRow(_ location: FileLocation) -> some View {
        let layout = grid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            DiaryIcon(name: "folder", size: 20).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 7) {
                NavigationLink(value: location.titleId) { HStack(spacing: 5) { Text(store.title(location.titleId)?.name ?? "Unmatched title").font(.system(size: 14, weight: .semibold)); DiaryIcon(name: "chevron-right", size: 14) } }.buttonStyle(.plain)
                Text("\(location.season.map { "Season \($0)" } ?? "Title folder") · \(location.fileCount.counted("file", "files")) · \(location.sizeBytes.map { String(format: "%.1f GB", Double($0) / 1e9) } ?? "Size unknown")").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(location.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(evidence(location.evidence)).font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { UIPasteboard.general.string = location.path; copied = location.id } label: { DiaryIcon(name: copied == location.id ? "check" : "copy", size: 18).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Copy path for \(store.title(location.titleId)?.name ?? "mapped folder")")
        }.padding(18).diarySectionBackground(radius: 16)
            .accessibilityElement(children: .contain).accessibilityIdentifier("file-folder-" + location.id)
    }
    private func evidence(_ value: String) -> String { switch value { case "present": "Confirmed in last scan"; case "unavailable": "Drive disconnected · location preserved"; case "missing": "Confirmed missing in last scan"; default: "Not yet verified" } }
}
