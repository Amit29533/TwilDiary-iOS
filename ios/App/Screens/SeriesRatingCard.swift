import Charts
import SwiftUI
import TwilDiaryCore

/// The title page's rating chart: every episode of the show in one line, coloured by its overall
/// score (IMDb, TMDB and Trakt together). At rest the header shows the episode count
/// and each source's score for the show; touch or slide along the line and it shows that episode,
/// each source's score and votes for it. Episode names stay hidden for unwatched episodes while
/// spoilers are hidden.
struct SeriesRatingCard: View {
    let show: Int
    let imdbID: String?
    /// The title in your diary, when it is: its watched episodes may show their names.
    var titleID: String? = nil
    @Environment(DiaryStore.self) private var store
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.colorScheme) private var colorScheme
    @State private var ratings: SeriesRatings?
    /// The touched episode, in an observable box so only the header and the marker redraw while a
    /// finger slides along the chart.
    @State private var selection = SeriesRatingSelection()
    private var selected: Int? {
        get { selection.index }
        nonmutating set { selection.index = newValue }
    }
    /// Your watched episodes of this title as "season:number", worked out once when the card loads
    /// (not on every finger movement along the chart).
    @State private var watched: Set<String> = []

    /// One episode on the line: it and its overall score.
    struct Point: Identifiable, Equatable {
        let episode: SeriesRatings.Episode
        let value: Double
        var id: Int { episode.index }
        static func == (a: Point, b: Point) -> Bool { a.episode.index == b.episode.index && a.value == b.value }
    }

    var body: some View {
        Group {
            if let ratings, ratings.episodes.count >= 2 {
                card(ratings)
            } else { Color.clear.frame(height: 0).accessibilityHidden(true) }
        }
        .task(id: show) {
            watched = titleID.map(watchedPlaces) ?? []
            ratings = await SeriesRatingsLoader.load(tmdb: show, imdbID: imdbID, store: store)
        }
    }

    private func card(_ ratings: SeriesRatings) -> some View {
        let points = ratings.episodes.compactMap { episode in episode.overall.map { Point(episode: episode, value: $0) } }
        let episode = selected.flatMap { index in ratings.episodes.first { $0.index == index } }
        return VStack(alignment: .leading, spacing: 8) {
            Button { selected = nil } label: {
                Text(episode.map(heading) ?? "\(ratings.episodes.count) episodes")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(HomeStyle.primary)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.identity)
            }.buttonStyle(.plain).accessibilityHint(episode == nil ? "" : "Back to the whole show")
            // Same size whichever episode is touched, so nothing below jumps while tracing.
            scores(ratings, episode: episode)
                .transaction { $0.animation = nil }
            SeriesRatingLine(points: points, seasons: ratings.episodes, selection: selection,
                             look: String(describing: theme) + "-" + String(describing: colorScheme)).equatable()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Episode ratings")
                .accessibilityValue(chartValue(points))
                .accessibilityAdjustableAction { direction in
                    let indexes = points.map { $0.episode.index }
                    guard !indexes.isEmpty else { return }
                    let current = selected.flatMap { indexes.firstIndex(of: $0) }
                    switch direction {
                    case .increment: selected = indexes[min((current ?? -1) + 1, indexes.count - 1)]
                    case .decrement: selected = indexes[max((current ?? indexes.count) - 1, 0)]
                    @unknown default: return
                    }
                }
            extremes(points)
        }
        .padding(12)
        .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
        .accessibilityElement(children: .contain).accessibilityIdentifier("title-rating-trend")
    }

    private func chartValue(_ points: [Point]) -> String {
        if let index = selected, let point = points.first(where: { $0.episode.index == index }) {
            return "Season \(point.episode.season) episode \(point.episode.number), \(point.value.formatted(.number.precision(.fractionLength(1))))"
        }
        let average = points.isEmpty ? 0 : points.map(\.value).reduce(0, +) / Double(points.count)
        return "Average \(average.formatted(.number.precision(.fractionLength(1))))"
    }

    // MARK: Header

    private func heading(_ episode: SeriesRatings.Episode) -> String {
        let place = "S\(episode.season) · E\(episode.number)"
        guard let name = episode.name, !name.isEmpty, name != "Episode \(episode.number)", nameVisible(episode) else { return place }
        return place + ": " + name
    }
    private func nameVisible(_ episode: SeriesRatings.Episode) -> Bool {
        guard hideSpoilers else { return true }
        guard titleID != nil else { return false }
        return watched.contains("\(episode.season):\(episode.number)")
    }
    private func watchedPlaces(_ titleID: String) -> Set<String> {
        let watched = Set(store.workspace.activeEvents.filter { $0.titleId == titleID }.compactMap(\.episodeId))
        return Set(store.workspace.episodes.filter { $0.titleId == titleID && watched.contains($0.id) }.map { "\($0.season):\($0.number)" })
    }

    /// The overall score and each source's, for the show or for the episode being touched.
    private func scores(_ ratings: SeriesRatings, episode: SeriesRatings.Episode?) -> some View {
        let overall: SeriesRatings.Score? = episode.flatMap { item in item.overall.map { SeriesRatings.Score(value: $0, votes: item.votes) } } ?? ratings.overallShow
        return HStack(spacing: 12) { scoreItems(ratings, episode: episode, overall: overall) }
            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func scoreItems(_ ratings: SeriesRatings, episode: SeriesRatings.Episode?, overall: SeriesRatings.Score?) -> some View {
        if let overall {
            HStack(spacing: 7) {
                ZStack {
                    Circle().stroke(RatingCircles.color(overall.value).opacity(0.2), lineWidth: 3)
                    Circle().trim(from: 0, to: overall.value / 10).stroke(RatingCircles.color(overall.value), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }.frame(width: 22, height: 22)
                score(overall)
            }.accessibilityElement(children: .combine).accessibilityLabel("Overall " + overall.value.formatted(.number.precision(.fractionLength(1))))
        }
        // One place per source the show has, kept while an episode lacks it (a dash), so the row
        // never reflows under the finger.
        ForEach(SeriesRatings.Source.allCases.filter { ratings.show[$0] != nil }, id: \.self) { source in
            let value = episode == nil ? ratings.show[source] : episode?.scores[source]
            HStack(spacing: 7) {
                BrandLogo(service: source == .imdb ? .imdb : source == .tmdb ? .tmdb : .trakt, size: 22)
                score(value)
            }.accessibilityElement(children: .combine)
                .accessibilityLabel(source.rawValue + " " + (value.map { $0.value.formatted(.number.precision(.fractionLength(1))) } ?? "no rating"))
        }
    }
    private func score(_ score: SeriesRatings.Score?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(score.map { $0.value.formatted(.number.precision(.fractionLength(1))) } ?? "–")
                .font(.system(size: 16, weight: .bold)).foregroundStyle(score.map { RatingCircles.color($0.value) } ?? .secondary)
            // Always two lines (blank when there are no votes), so the chart below stays put.
            Text(score.flatMap { $0.votes > 0 ? $0.votes.formatted(.number.notation(.compactName)) : nil } ?? " ")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.monospacedDigit().frame(minWidth: 34, alignment: .leading).contentTransition(.identity)
    }

    // MARK: Best and lowest

    private func extremes(_ points: [Point]) -> some View {
        let best = points.max { $0.value < $1.value }, lowest = points.min { $0.value < $1.value }
        return HStack(spacing: 8) {
            if let best { extreme("Highest", best) }
            if let lowest, lowest.episode.index != best?.episode.index { extreme("Lowest", lowest) }
        }
    }
    private func extreme(_ label: String, _ point: Point) -> some View {
        Button { selected = point.episode.index } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                    Text(heading(point.episode)).font(.caption.weight(.semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(point.value.formatted(.number.precision(.fractionLength(1)))).font(.system(size: 14, weight: .bold)).foregroundStyle(RatingCircles.color(point.value)).monospacedDigit()
            }.padding(.horizontal, 9).padding(.vertical, 6).frame(maxWidth: .infinity).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// The chart's line, drawn once: it only redraws when the scores change, not while a finger slides
/// along it (the marker on top does that), which keeps tracing smooth on long shows.
private struct SeriesRatingLine: View, Equatable {
    let points: [SeriesRatingCard.Point]
    let seasons: [SeriesRatings.Episode]
    let selection: SeriesRatingSelection
    /// The theme and light or dark: the line redraws in the new colours when either changes.
    let look: String
    private struct SeasonStart: Identifiable { let index: Int; let season: Int; var id: Int { index } }

    nonisolated static func == (a: SeriesRatingLine, b: SeriesRatingLine) -> Bool {
        a.points == b.points && a.seasons.count == b.seasons.count && a.look == b.look
    }

    var body: some View {
        let values = points.map { $0.value }
        let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let low = values.min() ?? 0, high = values.max() ?? 10
        let starts = seasonStarts(seasons)
        let step = max(1, Int((Double(starts.count) / 8).rounded(.up)))
        let first = seasons.first?.index ?? 1, last = seasons.last?.index ?? 2
        return Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Episode", point.episode.index), y: .value("Rating", point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Color(themed: "#4caf50").opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Episode", point.episode.index), y: .value("Rating", point.value))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Self.gradient(low: low, high: high))
            }
            RuleMark(y: .value("Average", average))
                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .foregroundStyle(RatingCircles.color(average).opacity(0.85))
                .annotation(position: .trailing, alignment: .center, spacing: 4) {
                    Text(average.formatted(.number.precision(.fractionLength(1)))).font(.system(size: 11, weight: .semibold)).foregroundStyle(RatingCircles.color(average))
                }
            ForEach(starts) { start in
                RuleMark(x: .value("Season", start.index)).lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(.secondary.opacity(0.35))
            }
        }
        .chartYScale(domain: 0...10)
        .chartXScale(domain: first...last)
        .chartYAxis { AxisMarks(position: .leading, values: [0, 2, 4, 6, 8, 10]) { _ in AxisGridLine().foregroundStyle(.secondary.opacity(0.15)); AxisValueLabel() } }
        .chartXAxis {
            AxisMarks(values: starts.enumerated().filter { $0.offset % step == 0 }.map { $0.element.index }) { value in
                AxisValueLabel { if let index = value.as(Int.self), let season = starts.first(where: { $0.index == index })?.season { Text("S\(season)").font(.caption2) } }
            }
        }
        .chartXSelection(value: Binding(get: { selection.index }, set: { picked in
            guard let picked, let index = nearest(picked, in: points.map { $0.episode.index }), index != selection.index else { return }
            selection.index = index
        }))
        .chartGesture { proxy in
            SpatialTapGesture().onEnded { proxy.selectXValue(at: $0.location.x) }
                .simultaneously(with: DragGesture(minimumDistance: 8).onChanged { drag in
                    guard abs(drag.translation.width) >= abs(drag.translation.height) else { return }
                    proxy.selectXValue(at: drag.location.x)
                })
        }
        .chartOverlay { proxy in SeriesRatingMarker(proxy: proxy, points: points, selection: selection) }
        .frame(height: 128)
    }

    /// The line's colour by score, low at the bottom: purple, red, orange, yellow, green, then blue
    /// for the best, laid over the line's own range of scores.
    static func gradient(low: Double, high: Double) -> LinearGradient {
        let stops: [(Double, String)] = [(4, "#8e5bd6"), (5.5, "#e2544f"), (6.8, "#f08a3c"), (7.6, "#e9c447"), (8.2, "#4caf50"), (9.3, "#4aa8f0")]
        let span = max(0.1, high - low)
        let mapped = stops.map { Gradient.Stop(color: Color(themed: $0.1), location: min(1, max(0, ($0.0 - low) / span))) }
        return LinearGradient(stops: mapped, startPoint: .bottom, endPoint: .top)
    }

    private func seasonStarts(_ episodes: [SeriesRatings.Episode]) -> [SeasonStart] {
        var seen = Set<Int>()
        return episodes.compactMap { seen.insert($0.season).inserted ? SeasonStart(index: $0.index, season: $0.season) : nil }
    }
    private func nearest(_ value: Int, in indexes: [Int]) -> Int? {
        indexes.min { abs($0 - value) < abs($1 - value) }
    }
}

/// The touched episode's marker: a line down the chart and a dot on the line.
private struct SeriesRatingMarker: View {
    let proxy: ChartProxy
    let points: [SeriesRatingCard.Point]
    let selection: SeriesRatingSelection

    var body: some View {
        GeometryReader { geometry in
            if let plot = proxy.plotFrame, let index = selection.index, let point = points.first(where: { $0.episode.index == index }),
               let x = proxy.position(forX: point.episode.index), let y = proxy.position(forY: point.value) {
                let frame = geometry[plot]
                Rectangle().fill(Color.white.opacity(0.5)).frame(width: 1, height: frame.height)
                    .position(x: frame.minX + x, y: frame.midY)
                Circle().fill(RatingCircles.color(point.value)).frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                    .position(x: frame.minX + x, y: frame.minY + y)
            }
        }.allowsHitTesting(false)
    }
}

/// The rating chart's touched episode.
@MainActor @Observable final class SeriesRatingSelection {
    var index: Int?
}
