import SwiftUI
import UniformTypeIdentifiers
import TwilDiaryCore

/// Settings → Sync & backup → Import from another app: Letterboxd, IMDb or TV Time. The export
/// is read and matched to TMDB on the phone, you see what was found, then it's added where your
/// diary lives (only what's missing there).
struct ImportHistoryView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var source: ImportSource?
    @State private var picking = false
    @State private var phase = Phase.choose
    @State private var work: Task<Void, Never>?

    enum Phase: Equatable {
        case choose
        case reading
        case matching(done: Int, total: Int)
        case ready(found: [ImportEntry], missed: [String])
        case sending
        case finished(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }.padding(.horizontal, 20).padding(.vertical, 16)
            }
            .background(Color(webHex: "#111116"))
            .navigationTitle("Import your history").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { work?.cancel(); dismiss() }.accessibilityIdentifier("import-close")
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .zip, .plainText, .data], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, let source else { return }
            start(source, urls: urls)
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .choose:
            Text("Bring your watches, ratings and watchlist from another app. They’re added to \(destination); anything already there is left as it is.")
                .font(.system(size: 15)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(ImportSource.allCases) { option in
                Button { source = option; picking = true } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(option.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        Text(option.hint).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                }.buttonStyle(.springPress).accessibilityIdentifier("import-" + option.rawValue)
            }
        case .reading:
            progress("Reading the export…", value: nil)
        case .matching(let done, let total):
            progress("Finding \(done) of \(total) on TMDB…", value: total > 0 ? Double(done) / Double(total) : nil)
        case .ready(let found, let missed):
            let watches = found.reduce(0) { $0 + $1.plays.count }, rated = found.count { $0.rating != nil }, planned = found.count { $0.planned }
            VStack(alignment: .leading, spacing: 10) {
                Text("Found in your \(source?.name ?? "") export").font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                line("film.stack", found.count.counted("title", "titles"))
                line("checkmark.circle", watches.counted("watch", "watches"))
                line("star", rated.counted("rating", "ratings"))
                line("bookmark", planned.counted("planned title", "planned titles"))
                if !missed.isEmpty {
                    line("questionmark.circle", "\(missed.count.counted("title", "titles")) not found on TMDB: " + missed.prefix(6).joined(separator: ", ") + (missed.count > 6 ? "…" : ""))
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 18))
            Button { send(found) } label: { Text("Add to \(destination)") }
                .buttonStyle(SettingsPrimaryButtonStyle()).disabled(found.isEmpty).accessibilityIdentifier("import-send")
        case .sending:
            progress("Adding to \(destination)… This can take a few minutes for a big history.", value: nil)
        case .finished(let message):
            Label(message, systemImage: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(HomeStyle.primary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("import-result")
            Button("Done") { dismiss() }.buttonStyle(SettingsPrimaryButtonStyle())
        case .failed(let message):
            Text(message).font(.system(size: 15)).foregroundStyle(Color(webHex: "#ff8a80")).fixedSize(horizontal: false, vertical: true)
            Button("Try again") { phase = .choose }.buttonStyle(SettingsPrimaryButtonStyle())
        }
    }

    private var destination: String {
        if store.onThisPhone { return "the diary on this phone" }
        return store.diaryService?.name ?? "your diary"
    }
    private func progress(_ text: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.system(size: 15)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
            if let value { ProgressView(value: value).tint(HomeStyle.chipText) } else { ProgressView().tint(HomeStyle.chipText) }
        }
    }
    private func line(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 15)).foregroundStyle(HomeStyle.soft).lineLimit(3)
    }

    private func start(_ source: ImportSource, urls: [URL]) {
        phase = .reading
        work = Task {
            var picked: [(name: String, data: Data)] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { picked.append((url.lastPathComponent, data)) }
            }
            let files = picked
            let entries = await Task.detached(priority: .userInitiated) { HistoryImport.entries(source, files: HistoryImport.csvFiles(files)) }.value
            guard !Task.isCancelled else { return }
            guard !entries.isEmpty else {
                phase = .failed("Nothing to import was found in that file. " + source.hint); return
            }
            guard let token = TMDBDirect.token(store) else { phase = .failed("Matching titles needs TMDB, which isn’t set up."); return }
            let result = await HistoryImport.match(entries, token: token) { done, total in phase = .matching(done: done, total: total) }
            guard !Task.isCancelled else { return }
            phase = .ready(found: result.matched, missed: result.missed)
        }
    }

    private func send(_ found: [ImportEntry]) {
        phase = .sending
        work = Task {
            do {
                let workspace = HistoryImport.workspace(found)
                let message = try await ServerBackups.restore(DiaryExport(workspace: workspace), store: store)
                phase = .finished(message)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
