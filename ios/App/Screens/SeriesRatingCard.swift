import Charts
import SwiftUI
import TwilDiaryCore

/// The title page's rating chart: every episode of the show in one line, coloured by its score,
/// with Overall, IMDb, TMDB and Trakt to choose from. At rest the header shows the episode count
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
    @AppStorage("seriesRatings.source") private var sourceName = "Overall"
    @State private var ratings: SeriesRatings?
    @State private var selected: Int?

    private var source: SeriesRatings.Source? { SeriesRatings.Source(rawValue: sourceName) }
    /// One episode on the line: it and its score in the chosen source.
    private struct Point: Identifiable { let episode: SeriesRatings.Episode; let value: Double; var id: Int { episode.index } }
    private struct SeasonStart: Identifiable { let index: Int; let season: Int; var id: Int { index } }

    var body: some View {
        Group {
            if let ratings, ratings.episodes.count >= 2 {
                card(ratings)
            } else { Color.clear.frame(height: 0).accessibilityHidden(true) }
        }
        .task(id: show) { ratings = await SeriesRatingsLoader.load(tmdb: show, imdbID: imdbID, store: store) }
    }

    private func card(_ ratings: SeriesRatings) -> some View {
        let available = ratings.sources
        let chosen = source.flatMap { available.contains($0) ? $0 : nil }
        let points = ratings.episodes.compactMap { episode in episode.score(chosen).map { Point(episode: episode, value: $0) } }
        let episode = selected.flatMap { index in ratings.episodes.first { $0.index == index } }
        return VStack(alignment: .leading, spacing: 10) {
            Button { selected = nil } label: {
                Text(episode.map(heading) ?? "\(ratings.episodes.count) episodes")
                    .font(.system(size: 19, weight: .bold)).foregroundStyle(HomeStyle.primary)
                    .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).accessibilityHint(episode == nil ? "" : "Back to the whole show")
            scores(ratings, episode: episode)
            if available.count > 1 {
                NativeSegmentedControl(segments: [NativeSegment(value: "Overall", title: "Overall", id: "series-rating-overall")]
                    + available.map { NativeSegment(value: $0.rawValue, title: $0.rawValue, id: "series-rating-" + $0.rawValue.lowercased()) },
                                       selection: Binding(get: { chosen?.rawValue ?? "Overall" }, set: { sourceName = $0 }))
            }
            chart(points, seasons: ratings.episodes)
            extremes(points)
        }
        .padding(14)
        .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
        .accessibilityElement(children: .contain).accessibilityIdentifier("title-rating-trend")
    }

    // MARK: Header

    private func heading(_ episode: SeriesRatings.Episode) -> String {
        let place = "S\(episode.season) · E\(episode.number)"
        guard let name = episode.name, !name.isEmpty, name != "Episode \(episode.number)", nameVisible(episode) else { return place }
        return place + ": " + name
    }
    private func nameVisible(_ episode: SeriesRatings.Episode) -> Bool {
        guard hideSpoilers else { return true }
        guard let titleID else { return false }
        return watchedPlaces(titleID).contains("\(episode.season):\(episode.number)")
    }
    private func watchedPlaces(_ titleID: String) -> Set<String> {
        let watched = Set(store.workspace.activeEvents.filter { $0.titleId == titleID }.compactMap(\.episodeId))
        return Set(store.workspace.episodes.filter { $0.titleId == titleID && watched.contains($0.id) }.map { "\($0.season):\($0.number)" })
    }

    /// The overall score and each source's, for the show or for the episode being touched.
    private func scores(_ ratings: SeriesRatings, episode: SeriesRatings.Episode?) -> some View {
        let overall: SeriesRatings.Score? = episode.flatMap { item in item.overall.map { SeriesRatings.Score(value: $0, votes: item.votes) } } ?? ratings.overallShow
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { scoreItems(ratings, episode: episode, overall: overall) }
            ScrollView(.horizontal) { HStack(spacing: 12) { scoreItems(ratings, episode: episode, overall: overall) } }.scrollIndicators(.hidden)
        }
    }
    @ViewBuilder private func scoreItems(_ ratings: SeriesRatings, episode: SeriesRatings.Episode?, overall: SeriesRatings.Score?) -> some View {
        if let overall {
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(RatingCircles.color(overall.value).opacity(0.2), lineWidth: 3)
                    Circle().trim(from: 0, to: overall.value / 10).stroke(RatingCircles.color(overall.value), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }.frame(width: 24, height: 24)
                score(overall)
            }.accessibilityElement(children: .combine).accessibilityLabel("Overall " + overall.value.formatted(.number.precision(.fractionLength(1))))
        }
        ForEach(SeriesRatings.Source.allCases, id: \.self) { source in
            if let value = episode.map({ $0.scores[source] }) ?? ratings.show[source] {
                HStack(spacing: 8) {
                    BrandLogo(service: source == .imdb ? .imdb : source == .tmdb ? .tmdb : .trakt, size: 24)
                    score(value)
                }.accessibilityElement(children: .combine).accessibilityLabel(source.rawValue + " " + value.value.formatted(.number.precision(.fractionLength(1))))
            }
        }
    }
    private func score(_ score: SeriesRatings.Score) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(score.value.formatted(.number.precision(.fractionLength(1)))).font(.system(size: 16, weight: .bold)).foregroundStyle(RatingCircles.color(score.value))
            if score.votes > 0 {
                Text(score.votes.formatted(.number.notation(.compactName))).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.monospacedDigit()
    }

    // MARK: Chart

    private func chart(_ points: [Point], seasons: [SeriesRatings.Episode]) -> some View {
        let values = points.map { $0.value }
        let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let low = values.min() ?? 0, high = values.max() ?? 10
        let starts = seasonStarts(seasons)
        let step = max(1, Int((Double(starts.count) / 8).rounded(.up)))
        let first = seasons.first?.index ?? 1, last = seasons.last?.index ?? 2
        let marker = selected.flatMap { index in points.first { $0.episode.index == index } }
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
            if let marker {
                RuleMark(x: .value("Selected", marker.episode.index)).foregroundStyle(.white.opacity(0.5))
                PointMark(x: .value("Episode", marker.episode.index), y: .value("Rating", marker.value)).symbolSize(70).foregroundStyle(RatingCircles.color(marker.value))
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
        .chartXSelection(value: Binding(get: { selected }, set: { picked in
            guard let picked else { return }
            selected = nearest(picked, in: points.map { $0.episode.index })
        }))
        .chartGesture { proxy in
            SpatialTapGesture().onEnded { proxy.selectXValue(at: $0.location.x) }
                .simultaneously(with: DragGesture(minimumDistance: 8).onChanged { drag in
                    guard abs(drag.translation.width) >= abs(drag.translation.height) else { return }
                    proxy.selectXValue(at: drag.location.x)
                })
        }
        .frame(height: 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Episode ratings")
        .accessibilityValue(marker.map { "Season \($0.episode.season) episode \($0.episode.number), \($0.value.formatted(.number.precision(.fractionLength(1))))" } ?? "Average \(average.formatted(.number.precision(.fractionLength(1))))")
        .accessibilityAdjustableAction { direction in
            let indexes = points.map { $0.episode.index }
            let current = selected.flatMap { indexes.firstIndex(of: $0) }
            switch direction {
            case .increment: selected = indexes[min((current ?? -1) + 1, indexes.count - 1)]
            case .decrement: selected = indexes[max((current ?? indexes.count) - 1, 0)]
            @unknown default: return
            }
        }
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

    // MARK: Best and lowest

    private func extremes(_ points: [Point]) -> some View {
        let best = points.max { $0.value < $1.value }, lowest = points.min { $0.value < $1.value }
        return VStack(spacing: 6) {
            if let best { extreme("Highest rated", best) }
            if let lowest, lowest.episode.index != best?.episode.index { extreme("Lowest rated", lowest) }
        }
    }
    private func extreme(_ label: String, _ point: Point) -> some View {
        Button { selected = point.episode.index } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                    Text(heading(point.episode)).font(.footnote.weight(.semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(point.value.formatted(.number.precision(.fractionLength(1)))).font(.system(size: 15, weight: .bold)).foregroundStyle(RatingCircles.color(point.value)).monospacedDigit()
            }.padding(.horizontal, 10).padding(.vertical, 7).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
