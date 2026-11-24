import UIKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// TwilDiary in another app's share sheet: it saves what it's given (a link, its text, a video or
/// a picture) as a clip for the app to identify, and shows a first guess from the words when it
/// can. The work of identifying happens in the app (a share sheet has little memory and time).
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        model.close = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let host = UIHostingController(rootView: ShareSheetView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let caption = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).compactMap { $0.attributedContentText?.string }.first
        Task { await model.save(providers, caption: caption) }
    }
}

@MainActor @Observable final class ShareModel {
    enum Phase { case saving, saved, copied(String), failed(String) }
    var phase = Phase.saving
    var clip: SavedClip?
    var still: UIImage?
    var guess: SavedClip.Candidate?
    var close: () -> Void = {}

    /// Reads the shared items and saves one clip: a video or picture file if there is one, else the
    /// link, with any text that came along.
    func save(_ providers: [NSItemProvider], caption: String?) async {
        // No shared folder (the sideloading tool dropped the app group): a link still gets to the
        // app, copied for Saved clips' Paste; a video can't.
        let folder = ClipStore.sharedFolder
        var input = ClipShareInput()
        input.add(text: caption)
        var file: String?, kind = SavedClip.Kind.text, media = false
        for provider in providers {
            if file == nil, provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                media = true
                if let folder { file = await copyFile(provider, type: .movie, into: folder, ext: "mov") }
                if file != nil { kind = .video }
            } else if file == nil, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                media = true
                if let folder { file = await copyFile(provider, type: .image, into: folder, ext: "jpg") }
                if file != nil { kind = .image }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                input.add(url: await loadURL(provider))
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                input.add(text: await loadText(provider))
            }
        }
        let (link, words) = input.resolved()
        guard let folder else {
            if let link {
                UIPasteboard.general.string = [link.absoluteString, words].compactMap { $0 }.joined(separator: "\n")
                phase = .copied("Link copied. Open TwilDiary and tap Paste in Search → Saved clips; it finds the title from there.")
            } else if media {
                phase = .failed("This copy of TwilDiary can’t take videos from the share sheet. Save the video to Photos, then add it in TwilDiary: Search → Saved clips → From Photos.")
            } else {
                phase = .failed("There was nothing here TwilDiary could save.")
            }
            await quickGuess(words)
            return
        }
        if file == nil, link != nil { kind = .link }
        guard file != nil || link != nil || !(words ?? "").isEmpty else { phase = .failed("There was nothing here TwilDiary could save."); return }
        var clip = SavedClip(kind: kind, url: link?.absoluteString, text: words, file: file,
                             source: kind == .video || kind == .image ? (link == nil ? "Photos" : ClipText.source(of: link?.absoluteString)) : ClipText.source(of: link?.absoluteString))
        if kind == .video, let file, let still = await Self.still(of: folder.appendingPathComponent(file)) {
            self.still = still
            let name = clip.id.uuidString + "-still.jpg"
            if let data = still.jpegData(compressionQuality: 0.8), (try? data.write(to: folder.appendingPathComponent(name))) != nil { clip.thumbnail = name }
        } else if kind == .image, let file {
            still = UIImage(contentsOfFile: folder.appendingPathComponent(file).path)
            clip.thumbnail = file
        }
        guard ClipStore.add(clip, to: folder) else {
            ClipStore.removeFiles(of: clip, in: folder)
            phase = .failed("TwilDiary couldn’t save this clip.")
            return
        }
        self.clip = clip
        phase = .saved
        await quickGuess(clip.text)
    }

    /// A first guess from the words alone, with the key built into the app (no guess without one).
    private func quickGuess(_ text: String?) async {
        guard let key = ClipTMDB.builtInKey else { return }
        var found: [SavedClip.Candidate] = []
        for query in ClipText.queries(caption: text, limit: 3) {
            found += await ClipTMDB.search(query, key: key)
        }
        let ranked = ClipRanking.merged(found)
        if ClipRanking.state(for: ranked) == .identified { guess = ranked.first }
    }

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
    private func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }
    /// Copies the shared file into the clips folder (the one handed over is only there for a moment).
    private func copyFile(_ provider: NSItemProvider, type: UTType, into folder: URL, ext: String) async -> String? {
        let name = UUID().uuidString + "." + ext
        let destination = folder.appendingPathComponent(name)
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                continuation.resume(returning: url.flatMap { Self.copy($0, to: destination) ? name : nil })
            }
        }
    }
    nonisolated private static func copy(_ source: URL, to destination: URL) -> Bool {
        (try? FileManager.default.copyItem(at: source, to: destination)) != nil
    }

    /// A frame from the start of the video, to show it by.
    nonisolated static func still(of video: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        guard let frame = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: frame.image)
    }
}

/// The share sheet's small screen: the clip, "Saved to your clips", and the first guess.
struct ShareSheetView: View {
    let model: ShareModel
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("TwilDiary").font(.headline)
                    Spacer()
                    Button("Done") { model.close() }.font(.body.weight(.semibold)).buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
                switch model.phase {
                case .saving:
                    HStack(spacing: 10) { ProgressView(); Text("Saving…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, minHeight: 96)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .copied(let message):
                    Label(message, systemImage: "doc.on.clipboard").font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if let guess = model.guess { guessRow(guess) }
                case .saved:
                    if let clip = model.clip { clipCard(clip) }
                    Label("Saved to your clips", systemImage: "checkmark.circle.fill").font(.body.weight(.semibold))
                        .foregroundStyle(.primary).symbolRenderingMode(.multicolor)
                    if let guess = model.guess { guessRow(guess) }
                    Text("TwilDiary checks it properly when you next open the app, and asks you if it isn’t sure.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18).padding(.bottom, 12)
            .background(Color(uiColor: .secondarySystemBackground), in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        }.ignoresSafeArea(edges: .bottom)
    }
    private func clipCard(_ clip: SavedClip) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let still = model.still { Image(uiImage: still).resizable().scaledToFill() }
                else { Image(systemName: "link").font(.title2).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .tertiarySystemFill)) }
            }.frame(width: 64, height: 96).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(clip.text?.isEmpty == false ? clip.text! : clip.url ?? clip.label).font(.subheadline).lineLimit(4)
                Text([clip.kind == .video ? "Video" : clip.kind == .image ? "Picture" : "Link", clip.source].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(10).background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
    private func guessRow(_ guess: SavedClip.Candidate) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: guess.posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w185" + $0) }) { image in image.resizable().scaledToFill() } placeholder: { Color(uiColor: .tertiarySystemFill) }
                .frame(width: 34, height: 51).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text("Looks like " + guess.name).font(.subheadline.weight(.semibold))
                Text([guess.tv ? "TV series" : "Movie", guess.year.map(String.init), "from the caption"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(8).background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
