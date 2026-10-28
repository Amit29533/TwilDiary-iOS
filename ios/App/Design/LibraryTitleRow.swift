import SwiftUI
import TwilDiaryCore

/// The list branch of the source TitleCard, sharing Library's public-rating preference.
struct LibraryTitleRow: View {
    let title: MediaTitle
    var archived = false
    @Environment(DiaryStore.self) private var store
    @AppStorage("publicRatingSource") private var ratingSource = PublicRatingSource.tmdb

    var body: some View {
        let score = store.publicScore(title, source: ratingSource)
        let present = !archived && store.hasPresentLocation(title.id)
        HStack(spacing: 14) {
            Artwork(path: title.poster, title: title.name).frame(width: 72, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 10) {
                Text(title.name).font(.system(size: 15, weight: .semibold)).lineLimit(1).frame(minHeight: 20.25)
                    .frame(maxWidth: .infinity, alignment: .leading)
                InlineFlowLayout(spacing: 10, rowSpacing: 10) {
                    if let score { RatingBadge(score: score) }
                    DiaryIcon(name: archived ? "trash-2" : title.statusIconName, size: 16)
                    if title.queued == true { DiaryIcon(name: "download", size: 15) }
                    if present { DiaryIcon(name: "monitor", size: 15) }
                }.foregroundStyle(Color(webHex: "#c5c0cf"))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 13).padding(.vertical, 11)
            .foregroundStyle(Color(webHex: "#f3f0f7"))
            .background {
                GeometryReader { geometry in
                    ZStack {
                        Color(webHex: "#101014")
                        if let path = title.poster {
                            LibraryCoverArtwork(path: path).frame(width: geometry.size.width, height: geometry.size.height).opacity(0.65)
                        }
                        LinearGradient(stops: [
                            .init(color: Color(webHex: "#09090c4d"), location: 0),
                            .init(color: Color(webHex: "#08080bce"), location: 0.45),
                            .init(color: Color(webHex: "#08080bf2"), location: 1)
                        ], startPoint: .leading, endPoint: .trailing)
                    }.allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.11)))
            .contentShape(Rectangle()).accessibilityElement(children: .ignore).accessibilityLabel(title.name)
            .accessibilityValue([
                archived ? "In Trash" : title.status.capitalized,
                score.map { "Rating " + $0.formatted(.number.precision(.fractionLength(1))) },
                title.queued == true ? "In Queue" : nil,
                present ? "On your PC" : nil
            ].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Source TitleCard uses its raw poster behind list rows, independently of the foreground Poster crop.
private struct LibraryCoverArtwork: View {
    let path: String
    @Environment(\.displayScale) private var displayScale
    @State private var loadedArtwork: PublicArtworkBitmap?
    @State private var loadedRequest: PublicArtworkRequest?
    var body: some View {
        GeometryReader { geometry in
            // Same shared, downsampled cache as Artwork: no AsyncImage re-download
            // or full-size main-thread decode when a row scrolls back into view.
            let request = PublicArtworkRequest(path: path, pixels: Double(max(geometry.size.width, geometry.size.height) * displayScale))
            Group {
                if path.hasPrefix("/demo/"), let image = DemoArtwork.image("asset:" + URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent) {
                    crop(Image(uiImage: image), size: geometry.size)
                } else if let request, let bitmap = (loadedRequest == request ? loadedArtwork : nil) ?? PublicArtworkCache.shared.cached(request) {
                    crop(Image(decorative: bitmap.image, scale: displayScale), size: geometry.size)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                .task(id: request) {
                    guard let request else { loadedArtwork = nil; loadedRequest = nil; return }
                    if let saved = PublicArtworkCache.shared.cached(request) { loadedRequest = request; loadedArtwork = saved; return }
                    let bitmap = await PublicArtworkCache.shared.image(request)
                    guard !Task.isCancelled else { return }
                    loadedRequest = request; loadedArtwork = bitmap
                }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func crop(_ image: Image, size: CGSize) -> some View {
        image.resizable().scaledToFill()
            .alignmentGuide(VerticalAlignment.center) { dimensions in dimensions.height * 0.4 }
            .frame(width: size.width, height: size.height)
            .offset(y: -size.height * 0.1)
    }
}

extension MediaTitle {
    var statusIconName: String {
        switch status {
        case "watching": "circle-play"
        case "completed": "circle-check"
        case "dropped": "circle-x"
        default: "clock-3"
        }
    }
}
