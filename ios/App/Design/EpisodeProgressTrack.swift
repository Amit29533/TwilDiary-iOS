import SwiftUI
import TwilDiaryCore

struct EpisodeProgressTrack: View {
    let segments: [EpisodeSegment]
    let season: Int
    @AppStorage("theme") private var theme = DiaryTheme.twilight

    var body: some View {
        ZStack {
            EpisodeSegmentShape(segments: segments, state: .unwatched).fill(.white.opacity(32.0 / 255))
            EpisodeSegmentShape(segments: segments, state: .next).fill(theme.accent.opacity(0.3608))
            EpisodeSegmentShape(segments: segments, state: .watched).fill(theme.accent)
        }
        .frame(height: 12)
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Season \(season) episodes watched")
        .accessibilityValue("\(segments.filter { $0 == .watched }.count) of \(segments.count) episodes watched")
        .accessibilityIdentifier("episode-progress")
    }
}

private struct EpisodeSegmentShape: Shape {
    let segments: [EpisodeSegment]
    let state: EpisodeSegment

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !segments.isEmpty else { return path }
        // Same 12-unit slot, 9-unit piece, 3-unit gap and rounded ends as the web SVG.
        let unit = rect.width / CGFloat(segments.count * 12)
        for index in segments.indices where segments[index] == state {
            let piece = CGRect(x: rect.minX + CGFloat(index * 12 + 1) * unit,
                               y: rect.minY + rect.height / 12,
                               width: 9 * unit, height: rect.height * 10 / 12)
            path.addRoundedRect(in: piece, cornerSize: CGSize(width: 3 * unit, height: rect.height / 4))
        }
        return path
    }
}
