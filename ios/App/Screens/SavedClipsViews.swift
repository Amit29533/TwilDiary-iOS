import SwiftUI
import AVKit
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import TwilDiaryCore

// MARK: Rows

/// A clip's picture: the title's poster once it's named, else its still, else a link symbol.
struct ClipThumbnail: View {
    let clip: SavedClip
    var width: CGFloat = 48
    var height: CGFloat = 72
    var body: some View {
        Group {
            if let poster = clip.chosen?.posterPath {
                Artwork(path: CatalogTools.image(poster, size: "w185"), title: clip.label, initialsOnly: false)
            } else if let still = ClipStore.url(clip.thumbnail), let image = UIImage(contentsOfFile: still.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: clip.kind == .text ? "text.quote" : "link").font(.app(size: 18, weight: .medium)).foregroundStyle(HomeStyle.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .tertiarySystemFill))
            }
        }.frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: Studio.corner(8), style: .continuous))
    }
}

/// One clip in a list: its picture, what it is or the title it's from, where it came from, and
/// where it stands.
struct ClipRow: View {
    let clip: SavedClip
    var body: some View {
        HStack(spacing: 12) {
            ClipThumbnail(clip: clip)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                Text(detail).font(.app(size: 12.5)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                tag.padding(.top, 3)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if clip.state == .identifying || clip.state == .waiting { ProgressView().controlSize(.small) }
            else { Image(systemName: "chevron.right").font(.app(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.secondary) }
        }.padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
    private var title: String {
        if let chosen = clip.chosen { return chosen.name }
        if clip.kind == .text || clip.kind == .link, let text = clip.text, !text.isEmpty { return "“" + String(text.prefix(60)) + "”" }
        return clip.label
    }
    private var detail: String {
        let what = clip.kind == .video ? "Video" : clip.kind == .image ? "Picture" : "Reel"
        let when = clip.created.formatted(.relative(presentation: .named))
        return [clip.chosen == nil ? nil : what, clip.author ?? clip.source, when].compactMap { $0 }.joined(separator: " · ")
    }
    @ViewBuilder private var tag: some View {
        switch clip.state {
        case .identified:
            if let chosen = clip.chosen { ClipTag(text: [chosen.tv ? "TV series" : "Movie", chosen.year.map(String.init)].compactMap { $0 }.joined(separator: " · "), tint: Color(uiColor: .systemGreen)) }
        case .needsPick: ClipTag(text: "Pick the title", tint: Color(uiColor: .systemOrange))
        case .notFound: ClipTag(text: "Couldn’t tell · search", tint: HomeStyle.secondary)
        case .waiting, .identifying: ClipTag(text: "Identifying…", tint: HomeStyle.secondary)
        }
    }
}

private struct ClipTag: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text).font(.app(size: 11, weight: .semibold)).foregroundStyle(tint).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2).background(tint.opacity(0.15), in: Capsule())
    }
}

/// A row that opens what fits: the pick screen for a clip waiting for its title, the title's page
/// once it's named.
struct ClipLink: View {
    let clip: SavedClip
    @Binding var picking: SavedClip?
    @Environment(DiaryStore.self) private var store
    var body: some View {
        if clip.state == .identified, let chosen = clip.chosen {
            if let id = clip.titleID ?? ClipInbox.libraryTitle(for: chosen, store: store), store.title(id) != nil {
                NavigationLink(value: id) { ClipRow(clip: clip) }.buttonStyle(.plain)
            } else {
                NavigationLink(value: CatalogRoute(kind: chosen.tv ? .tv : .movie, id: chosen.tmdbID)) { ClipRow(clip: clip) }.buttonStyle(.plain)
            }
        } else if clip.state == .needsPick || clip.state == .notFound {
            Button { picking = clip } label: { ClipRow(clip: clip) }.buttonStyle(.plain)
        } else {
            ClipRow(clip: clip)
        }
    }
}

// MARK: Search

/// Search's Saved clips: the newest few, and the way to all of them (and to adding one).
struct SavedClipsSection: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var inbox = ClipInbox.shared
    @State private var picking: SavedClip?
    /// The clipboard holds a link (checked without reading it, so iOS asks nothing).
    @State private var linkCopied = false
    /// The clipboard's version last pasted here, so the same link isn't offered twice.
    @AppStorage(ClipInbox.pastedKey) private var pastedChange = -1
    var body: some View {
        let clips = inbox.clips
        VStack(alignment: .leading, spacing: Gap.heading) {
            HStack(spacing: 10) {
                Text("Saved clips").font(.app(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
                if !clips.isEmpty { CountPill(count: clips.count) }
                Spacer(minLength: 0)
                SectionMoreLink(label: "All saved clips", value: AppDestination.savedClips, identifier: "search-saved-clips")
            }.frame(minHeight: Gap.headingRow)
            // A link the share sheet copied (an install without the shared folder), or one you
            // copied yourself: one tap adds it.
            if linkCopied && UIPasteboard.general.changeCount != pastedChange {
                HStack(spacing: 12) {
                    Image(systemName: "doc.on.clipboard").font(.app(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                        .frame(width: 36, height: 36).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text("A copied link is ready to add").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                    Spacer(minLength: 0)
                    PasteButton(payloadType: String.self) { [store] strings in
                        Task { @MainActor in await ClipInbox.shared.add(pasted: strings.joined(separator: "\n"), store: store) }
                    }.labelStyle(.iconOnly).buttonBorderShape(.capsule)
                }.padding(12).cardSurface(18).accessibilityIdentifier("search-paste-clip")
            }
            if clips.isEmpty {
                // How clips get here, in one line (the page behind the chevron adds them too).
                NavigationLink(value: AppDestination.savedClips) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.up").font(.app(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                            .frame(width: 36, height: 36).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text("Share a reel or video to TwilDiary and it finds the title.").font(.app(size: 14)).foregroundStyle(HomeStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }.padding(12).cardSurface(18)
                }.buttonStyle(.plain)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(clips.prefix(4).enumerated()), id: \.element.id) { index, clip in
                        if index > 0 { Rectangle().fill(Color(uiColor: .separator)).frame(height: 1 / 3).padding(.leading, 72) }
                        ClipLink(clip: clip, picking: $picking)
                    }
                }.cardSurface(18).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .task { linkCopied = UIPasteboard.general.hasURLs; await inbox.process(store: store) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { linkCopied = UIPasteboard.general.hasURLs } }
        .sheet(item: $picking) { clip in ClipPickView(clipID: clip.id) }
    }
}

// MARK: All clips

struct SavedClipsPage: View {
    @Environment(DiaryStore.self) private var store
    @State private var inbox = ClipInbox.shared
    @State private var picking: SavedClip?
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    var body: some View {
        let clips = inbox.clips
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: Gap.section) {
                // Two more ways in, for a link you copied or a video in Photos. (The picker's label
                // is a Sendable closure, so it gets plain values, not the view's state.)
                let adding = importing, ink = HomeStyle.primary
                HStack(spacing: 10) {
                    PasteButton(payloadType: String.self) { [store] strings in
                        Task { @MainActor in await ClipInbox.shared.add(pasted: strings.joined(separator: "\n"), store: store) }
                    }.labelStyle(.titleAndIcon).buttonBorderShape(.capsule).tint(Color(uiColor: .tertiarySystemFill))
                    PhotosPicker(selection: $photo, matching: .any(of: [.videos, .images])) {
                        Label(adding ? "Adding…" : "From Photos", systemImage: "photo.on.rectangle")
                            .font(.app(size: 15, weight: .semibold)).foregroundStyle(ink)
                            .padding(.horizontal, 14).frame(height: 36).background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                    }.disabled(importing)
                    Spacer(minLength: 0)
                }
                if clips.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No clips yet").font(.app(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        Text("In Instagram, TikTok, YouTube, Photos or Files, tap Share and choose TwilDiary. It saves the clip here and works out which movie or show it’s from.")
                            .font(.app(size: 14)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).cardSurface(18)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                            if index > 0 { Rectangle().fill(Color(uiColor: .separator)).frame(height: 1 / 3).padding(.leading, 72) }
                            ClipLink(clip: clip, picking: $picking)
                                .contextMenu {
                                    if clip.state != .needsPick { Button("Choose the title", systemImage: "list.bullet") { picking = clip } }
                                    if let link = clip.url.flatMap(URL.init(string:)) { Link(destination: link) { Label("Open where it came from", systemImage: "arrow.up.right") } }
                                    Button("Delete", systemImage: "trash", role: .destructive) { inbox.remove(clip) }
                                }
                        }
                    }.cardSurface(18).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }.padding(.horizontal, Gap.gutter).padding(.top, 8).padding(.bottom, 100)
        }
        .diaryScreenBackground().diaryPageNavigation("Saved clips")
        .task { await inbox.process(store: store) }
        .refreshable { await inbox.process(store: store) }
        .sheet(item: $picking) { clip in ClipPickView(clipID: clip.id) }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            importing = true
            Task {
                let video = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
                if let data = try? await item.loadTransferable(type: Data.self) { await inbox.add(media: data, video: video, store: store) }
                importing = false
                photo = nil
            }
        }
    }
}

private struct ClipEvidenceFile: Transferable {
    let url: URL
    let video: Bool

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try copy($0.file, video: true) }
        FileRepresentation(importedContentType: .image) { try copy($0.file, video: false) }
    }

    private static func copy(_ source: URL, video: Bool) throws -> Self {
        let ext = source.pathExtension.isEmpty ? (video ? "mov" : "jpg") : source.pathExtension
        let name = UUID().uuidString + "." + ext
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: url)
        return Self(url: url, video: video)
    }
}

// MARK: Pick the title

/// "Which one is it?": the best guesses with posters and a match figure, or a search when none fit.
/// Nothing enters the diary until you choose.
struct ClipPickView: View {
    let clipID: UUID
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var inbox = ClipInbox.shared
    @State private var selected: SavedClip.Candidate?
    @State private var searching = false
    @State private var query = ""
    @State private var results: [SavedClip.Candidate] = []
    @State private var working = false
    @State private var evidence: PhotosPickerItem?
    @State private var evidenceError: String?
    var body: some View {
        let clip = inbox.clips.first { $0.id == clipID }
        NavigationStack {
            ScrollView {
                if let clip {
                    VStack(alignment: .leading, spacing: 0) {
                        header(clip)
                        if clip.url != nil, clip.state == .notFound || clip.state == .needsPick {
                            VStack(spacing: 8) {
                                Text(clip.evidenceSummary).font(.footnote).foregroundStyle(.secondary)
                                PhotosPicker(selection: $evidence, matching: .any(of: [.images, .videos])) {
                                    Label("Add screenshot or video", systemImage: "photo.badge.plus")
                                }.buttonStyle(.bordered)

                            }.padding(.top, 12)
                        }
                        if let evidenceError { Text(evidenceError).font(.footnote).foregroundStyle(.secondary) }
                        if clip.state == .notFound {
                            if let hint = clip.identificationHint {
                                Text(hint).font(.footnote).foregroundStyle(.secondary)
                                    .padding(.horizontal, Gap.gutter).padding(.top, 12)
                            }
                            Button("Try identifying again") {
                                Task { await inbox.retry(clip.id, store: store) }
                            }.padding(.top, 12)
                        } else if clip.state == .waiting || clip.state == .identifying {
                            ProgressView("Identifying clip…").padding(.top, 12)
                        }
                        let options = searching || clip.candidates.isEmpty ? results : clip.candidates
                        VStack(alignment: .leading, spacing: 2) {
                            Text(searching || clip.candidates.isEmpty ? "Find the title" : "Which one is it?").font(.app(size: 22, weight: .bold)).tracking(-0.22)
                            Text(searching || clip.candidates.isEmpty ? "Search TMDB for the movie or show." : "TwilDiary’s best guesses, most likely first.")
                                .font(.app(size: 13)).foregroundStyle(HomeStyle.secondary)
                        }.padding(.horizontal, Gap.gutter).padding(.top, 14)
                        if searching || clip.candidates.isEmpty {
                            TextField("Movie or show", text: $query).textFieldStyle(.roundedBorder).submitLabel(.search)
                                .onSubmit { Task { await search() } }.padding(.horizontal, Gap.gutter).padding(.top, 12)
                        }
                        if !options.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(Array(options.enumerated()), id: \.element.id) { index, candidate in
                                    if index > 0 { Rectangle().fill(Color(uiColor: .separator)).frame(height: 1 / 3).padding(.leading, 68) }
                                    Button { selected = candidate } label: { option(candidate, showsMatch: !searching && !clip.candidates.isEmpty) }.buttonStyle(.plain)
                                }
                            }.cardSurface(18).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)).padding(.horizontal, Gap.gutter).padding(.top, 12)
                        }
                        VStack(spacing: 10) {
                            Button { Task { await choose(clip, add: true) } } label: {
                                Text("Add to Planned").font(.app(size: 16, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 48)
                            }.buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 14))
                            Button { Task { await choose(clip, add: false) } } label: {
                                Text("Just keep the clip with it").font(.app(size: 16, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 48)
                            }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14))
                        }.disabled(selected == nil || working || !store.canMutate).padding(.horizontal, Gap.gutter).padding(.top, 14)
                        if !searching && !clip.candidates.isEmpty {
                            Button("None of these · Search") { searching = true; selected = nil }
                                .font(.app(size: 14, weight: .semibold)).frame(maxWidth: .infinity).padding(.top, 14)
                        }
                    }.disabled(working).padding(.bottom, 30)
                } else {
                    Text("This clip is gone.").foregroundStyle(.secondary).padding(40)
                }
            }
            .navigationTitle("Saved clip").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { selected = clip?.candidates.first }
            .onChange(of: evidence) { _, item in
                guard let item else { return }
                Task { await attach(item) }
            }
            .onChange(of: clip?.candidates) { _, choices in
                if !searching { selected = choices?.first }
            }
        }
    }
    private func attach(_ item: PhotosPickerItem) async {
        working = true
        evidenceError = nil
        defer { working = false; evidence = nil }
        do {
            guard let media = try await item.loadTransferable(type: ClipEvidenceFile.self) else {
                throw CocoaError(.fileReadUnknown)
            }
            defer { try? FileManager.default.removeItem(at: media.url) }
            guard let folder = ClipStore.folder else { throw CocoaError(.fileWriteUnknown) }
            let id = clipID
            try await Task.detached(priority: .userInitiated) {
                try ClipStore.attach(media.url, video: media.video, to: id, in: folder)
            }.value
            selected = nil
            results = []
            searching = false
            query = ""
            await inbox.process(store: store)
        } catch {
            evidenceError = "Couldn’t attach this item. Please try again."
        }
    }

    private func header(_ clip: SavedClip) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ClipThumbnail(clip: clip, width: 80, height: 120)
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.text?.isEmpty == false ? clip.text! : clip.label).font(.app(size: 14)).foregroundStyle(HomeStyle.primary).lineLimit(5)
                Text([clip.author ?? clip.source, clip.method.map { "named from the " + $0 }].compactMap { $0 }.joined(separator: " · "))
                    .font(.app(size: 12)).foregroundStyle(HomeStyle.secondary)
                if let link = clip.url.flatMap(URL.init(string:)) {
                    Link(destination: link) { Label("Open where it came from", systemImage: "arrow.up.right").font(.app(size: 13, weight: .semibold)) }.padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, Gap.gutter).padding(.top, 12)
    }
    private func option(_ candidate: SavedClip.Candidate, showsMatch: Bool) -> some View {
        HStack(spacing: 12) {
            Artwork(path: CatalogTools.image(candidate.posterPath, size: "w185"), title: candidate.name, initialsOnly: false)
                .frame(width: 44, height: 66).clipShape(RoundedRectangle(cornerRadius: Studio.corner(8), style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name).font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2)
                Text([candidate.tv ? "TV series" : "Movie", candidate.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.app(size: 12.5)).foregroundStyle(HomeStyle.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if showsMatch {
                Text("\(Int((candidate.confidence * 100).rounded()))%").font(.app(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.secondary).monospacedDigit()
            }
            Image(systemName: selected?.id == candidate.id ? "checkmark.circle.fill" : "circle").font(.app(size: 22))
                .foregroundStyle(selected?.id == candidate.id ? Color.accentColor : Color(uiColor: .tertiaryLabel))
        }.padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
            .accessibilityElement(children: .combine).accessibilityAddTraits(selected?.id == candidate.id ? .isSelected : [])
    }
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let token = TMDBDirect.token(store) else { return }
        results = ClipRanking.merged(await ClipTMDB.search(text, key: token))
        selected = results.first
    }
    private func choose(_ clip: SavedClip, add: Bool) async {
        guard let selected else { return }
        working = true
        defer { working = false }
        do {
            try await inbox.choose(selected, for: clip, addToPlanned: add, store: store)
            Haptics.play(.success)
            dismiss()
        } catch {
            inbox.reload()
            evidenceError = "Couldn’t save the title for this clip. Check its latest details and try again."
        }
    }
}

// MARK: Home

/// Home's nudge when a clip waits for its title.
struct HomeClipNudge: View {
    @State private var inbox = ClipInbox.shared
    var body: some View {
        let count = inbox.toPick.count
        if count > 0 {
            NavigationLink(value: AppDestination.savedClips) {
                HStack(spacing: 12) {
                    Image(systemName: "film.stack").font(.app(size: 17, weight: .semibold)).foregroundStyle(Color(uiColor: .systemOrange))
                        .frame(width: 36, height: 36).background(Color(uiColor: .systemOrange).opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(count == 1 ? "1 clip to pick" : "\(count) clips to pick").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        Text("Saved clips that need you to choose the title").font(.app(size: 12.5)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.app(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                }.padding(12).cardSurface(18).contentShape(Rectangle())
            }.buttonStyle(.springPress).accessibilityIdentifier("home-clips-to-pick")
        }
    }
}

// MARK: Title pages

/// "Your clips" on a title's page: the clips kept with it. A link opens the post where it came
/// from; a saved video plays here.
struct TitleClipsShelf: View {
    let tmdbID: Int
    let tv: Bool
    @State private var inbox = ClipInbox.shared
    @State private var playing: SavedClip?
    @Environment(\.openURL) private var openURL
    var body: some View {
        let clips = inbox.clips(tmdbID: tmdbID, tv: tv)
        if !clips.isEmpty {
            VStack(alignment: .leading, spacing: Gap.heading) {
                HStack(spacing: 10) {
                    Text("Your clips").font(.app(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
                    CountPill(count: clips.count)
                    Spacer(minLength: 0)
                }.frame(minHeight: Gap.headingRow)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Gap.item) {
                        ForEach(clips) { clip in
                            Button { open(clip) } label: { card(clip) }.buttonStyle(.springPress)
                                .accessibilityLabel(clip.kind == .video ? "Play clip" : "Open clip")
                        }
                    }
                }.scrollIndicators(.hidden).scrollClipDisabled()
            }
            .sheet(item: $playing) { clip in ClipPlayer(clip: clip) }
        }
    }
    private func card(_ clip: SavedClip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                if let still = ClipStore.url(clip.thumbnail), let image = UIImage(contentsOfFile: still.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color(uiColor: .tertiarySystemFill).overlay { Image(systemName: "link").font(.app(size: 22)).foregroundStyle(HomeStyle.secondary) }
                }
                Image(systemName: clip.kind == .video ? "play.fill" : "arrow.up.right").font(.app(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(.black.opacity(0.6), in: Circle()).padding(8)
            }.frame(width: 150, height: 200).clipShape(RoundedRectangle(cornerRadius: Studio.corner(Gap.posterCorner), style: .continuous))
            Text(clip.author ?? clip.source ?? "Clip").font(.app(size: 13.5, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1).padding(.top, 7)
            Text(clip.kind == .video ? "Plays here" : clip.kind == .image ? "Picture" : "Opens where it came from")
                .font(.app(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1).padding(.top, 1)
        }.frame(width: 150, alignment: .leading)
    }
    private func open(_ clip: SavedClip) {
        if clip.kind == .video || clip.kind == .image, ClipStore.url(clip.file) != nil { playing = clip }
        else if let link = clip.url.flatMap(URL.init(string:)) { openURL(link) }
    }
}

/// A saved video playing (or a saved picture shown), full screen.
private struct ClipPlayer: View {
    let clip: SavedClip
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if clip.kind == .video, let player {
                    VideoPlayer(player: player).ignoresSafeArea(edges: .bottom)
                } else if let file = ClipStore.url(clip.file), let image = UIImage(contentsOfFile: file.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Text("This clip’s file is gone.").foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .onAppear {
            if clip.kind == .video, let file = ClipStore.url(clip.file) {
                let made = AVPlayer(url: file)
                player = made
                made.play()
            }
        }
        .onDisappear { player?.pause() }
    }
}
