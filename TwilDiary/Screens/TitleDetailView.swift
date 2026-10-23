import SwiftUI
import TwilDiaryCore

struct TitleDetailView: View {
    let id: String
    @Environment(DiaryStore.self) private var store
    @State private var season = 1
    @State private var showOverview = false
    @State private var showNotes = false
    @State private var showLocation = false
    @State private var notes = ""
    @State private var rating = 7.0
    @State private var showRating = false
    @State private var resetConfirmation = false
    @State private var card: WatchCard?
    var body: some View {
        Group {
            if let title = store.title(id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header(title)
                        Text(title.overview).foregroundStyle(Color(white: 0.75)).font(.subheadline).lineSpacing(4).lineLimit(showOverview ? nil : 3)
                            .overlay(alignment: .bottomTrailing) { if !showOverview { Button("More") { showOverview = true }.font(.subheadline.bold()).padding(.leading, 12).background(.black) } }
                        progressPanel(title)
                        if title.isSeries {
                            HStack { Text("Episodes").font(.title2.bold()); Spacer(); Picker("Season", selection: $season) { ForEach(title.seasons ?? [], id: \.number) { Text($0.name).tag($0.number) } }.pickerStyle(.menu) }
                            if let manifest = title.seasons?.first(where: { $0.number == season }), manifest.metadataLoadedAt == nil {
                                Button("Load season episodes") { Task { await store.loadSeason(title, number: season); await loadCard(title) } }.buttonStyle(.bordered).disabled(store.busy)
                            }
                            LazyVStack(spacing: 10) { ForEach(episodes) { episode in
                                HStack(spacing: 12) {
                                    Artwork(path: episode.still, title: "").overlay { if episode.hidden != false { Image(systemName: "eye.slash").foregroundStyle(.secondary) } }.frame(width: 88, height: 53).clipShape(RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 4) { Text("\(episode.number) · \(episode.name.isEmpty ? "Episode \(episode.number)" : episode.name)").font(.subheadline); Text(watched.contains(episode.id) ? "Watched" : card?.next?.id == episode.id ? "Up next" : "Not watched").font(.caption).foregroundStyle(.secondary) }
                                    Spacer(minLength: 0); Image(systemName: watched.contains(episode.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(watched.contains(episode.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                }.padding(10).background(card?.next?.id == episode.id ? Color.purple.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 15))
                            } }
                        }
                        VStack(spacing: 20) {
                            DisclosureGroup("Notes", isExpanded: $showNotes) {
                                VStack(alignment: .leading, spacing: 12) {
                                    TextEditor(text: $notes).frame(minHeight: 110).scrollContentBackground(.hidden)
                                    Button("Save notes") { Task { await store.patch(title, values: ["notes": notes]) } }.disabled(store.busy || notes == title.notes || notes.count > 20_000)
                                }.padding(.top, 12)
                            }
                            Divider()
                            DisclosureGroup(isExpanded: $showLocation) { ForEach(locations) { location in
                                VStack(alignment: .leading, spacing: 7) { Text(location.evidence == "present" ? "Available · \(location.deviceName)" : location.evidence.capitalized).font(.subheadline.bold()); Text(location.path).font(.caption.monospaced()).textSelection(.enabled); Text("\(location.fileCount) files").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                            } } label: { Text(serverLabel).font(.subheadline.weight(.semibold)) }
                        }.diaryPanel()
                    }.padding(.horizontal, 16).padding(.bottom, 32)
                }.background(alignment: .top) {
                    Artwork(path: title.backdrop, title: title.name).frame(height: 310).overlay(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)).ignoresSafeArea(edges: .top)
                }.background(.black)
                    .toolbar(.visible, for: .navigationBar).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button { Task { await store.patch(title, values: ["favorite": !title.favorite]) } } label: { Image(systemName: title.favorite ? "heart.fill" : "heart") }.accessibilityLabel("Favorite").disabled(store.busy)
                            Menu { Button(title.queued == true ? "Remove from Queue" : "Add to Queue") { Task { await store.patch(title, values: ["queued": title.queued != true]) } } } label: { Image(systemName: "ellipsis") }
                        }
                    }
                    .task { notes = title.notes; rating = title.score ?? 7; await loadCard(title); if let selected = card?.season?.number { season = selected } }
                    .task(id: season) { await loadCard(title) }
                    .sheet(isPresented: $showRating) { ratingSheet(title) }
                    .confirmationDialog("Reset progress to 0? Logged watches will be removed, with Undo available.", isPresented: $resetConfirmation, titleVisibility: .visible) {
                        Button("Reset to Planned", role: .destructive) { Task { await store.setStatus(title, status: "planned"); await loadCard(title) } }
                    }
            } else { ContentUnavailableView("Title unavailable", systemImage: "film") }
        }
    }
    private func header(_ title: MediaTitle) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            Artwork(path: title.poster, title: title.name).frame(width: 114, height: 171).clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 12) {
                Text(title.name).font(.system(size: 24, weight: .bold)).tracking(-0.7).fixedSize(horizontal: false, vertical: true)
                Text([title.year.map(String.init), title.categoryName, title.runtimeMinutes.map { "\($0) min" }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if let rating = title.communityScore { Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill").foregroundStyle(.yellow) }
                    Button { showRating = true } label: { Label(title.score.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "Your rating —", systemImage: "star") }.font(.caption)
                }.font(.subheadline)
            }.padding(.bottom, 4)
        }.padding(.top, 105)
    }
    private func progressPanel(_ title: MediaTitle) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Menu { ForEach(["planned", "watching", "completed", "dropped"], id: \.self) { status in
                    Button(status.capitalized) {
                        if status == "planned" && title.status != "planned" { resetConfirmation = true }
                        else { Task { await store.setStatus(title, status: status); await loadCard(title) } }
                    }
                } } label: { Label(title.status.capitalized, systemImage: "play.fill").font(.subheadline.bold()) }.buttonStyle(.bordered)
                Spacer(minLength: 0)
                if let minutes = remaining(title) { Text("\(DiaryDate.duration(minutes)) left").font(.caption).foregroundStyle(Color(white: 0.75)).shadow(color: .black, radius: 3) }
            }
            if let card {
                HStack { Text(title.isSeries ? "Episode \(card.progress.watched) of \(card.progress.total)" : card.progress.watched > 0 ? "Watched" : "Ready to watch").font(.title3.bold()); Spacer(); Text("\(percent)%").foregroundStyle(.tint).font(.title3.bold()) }
                ProgressView(value: Double(percent), total: 100)
                if let next = card.next { HStack { Image(systemName: "eye.slash").frame(width: 55, height: 46).background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10)); VStack(alignment: .leading) { Text("UP NEXT").font(.caption2.bold()).foregroundStyle(.tint); Text("Episode \(next.number)").font(.subheadline.bold()) }; Spacer() }.padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16)) }
                Button { Task { await store.markNext(title, season: season); await loadCard(title) } } label: {
                    Label(card.next.map { "Mark E\($0.number) watched" } ?? "Mark watched", systemImage: "checkmark").font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).disabled(store.busy || (title.isSeries && card.next == nil) || (!title.isSeries && card.progress.watched > 0))
                HStack { Label("Watched today", systemImage: "calendar").font(.caption).foregroundStyle(.secondary); Spacer(); Button(title.isSeries ? "Rate show" : "Rate movie") { showRating = true }.font(.caption.bold()) }
                if card.previous != nil { Button("Remove latest watch") { Task { await store.removeLatest(title, season: title.isSeries ? season : nil); await loadCard(title) } }.font(.caption).disabled(store.busy) }
            } else { ProgressView("Loading progress…") }
        }.diaryPanel()
    }
    private func ratingSheet(_ title: MediaTitle) -> some View {
        NavigationStack {
            Form {
                Section("Your rating") {
                    Stepper(value: $rating, in: 1...10, step: 0.5) {
                        Text(rating, format: .number.precision(.fractionLength(1)))
                    }
                    Button("Save rating") {
                        Task { await store.patch(title, values: ["score": rating]); showRating = false }
                    }
                    Button("Clear rating") {
                        Task { await store.patch(title, values: ["score": NSNull()]); showRating = false }
                    }
                }
            }
                .navigationTitle(title.isSeries ? "Rate show" : "Rate movie").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showRating = false } } }
        }.presentationDetents([.medium])
    }
    private var episodes: [Episode] { store.workspace.episodes.filter { $0.titleId == id && $0.season == season }.sorted { $0.number < $1.number } }
    private var watched: Set<String> { Set(store.workspace.activeEvents.filter { $0.titleId == id }.compactMap(\.episodeId)) }
    private var locations: [FileLocation] { store.workspace.locations.filter { $0.titleId == id } }
    private var serverLabel: String { let drives = Set(locations.filter { $0.evidence == "present" }.map { "Drive " + $0.driveLetter.trimmingCharacters(in: CharacterSet(charactersIn: ":")) }).sorted(); return drives.isEmpty ? "Not Available on Server" : "Available on Server: " + drives.joined(separator: " / ") }
    private var percent: Int { guard let card, card.progress.total > 0 else { return 0 }; return Int((Double(card.progress.watched) / Double(card.progress.total) * 100).rounded()) }
    private func remaining(_ title: MediaTitle) -> Int? { title.isSeries ? SeasonProgress.calculate(title: title, workspace: store.workspace, season: season).remainingMinutes : title.runtimeMinutes.map { card?.progress.watched == 1 ? 0 : $0 } }
    private func loadCard(_ title: MediaTitle) async {
        if store.isPreview { card = PreviewData.card; return }
        do { card = try await store.card(title, season: title.isSeries ? season : nil) }
        catch { store.error = error.localizedDescription }
    }
}
