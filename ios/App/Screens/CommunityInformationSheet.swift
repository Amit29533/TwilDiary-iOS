import SwiftUI

struct CommunityInformationSheet: View {
    let name: String
    var artwork: String? = nil
    let identity: CommunityIdentity?
    @Environment(DiaryStore.self) private var store
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var controller = CommunityInformationController()
    @State private var retryRevision = 0
    @State private var detent = PresentationDetent.medium
    var body: some View {
        VStack(spacing: 0) {
            Text("Information").font(.headline).frame(maxWidth: .infinity).padding(.top, 24).padding(.bottom, 16)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("community-information-heading")
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(name).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    // A cached page paints in the first frame; the sheet no longer shows a
                    // 300 pt loading placeholder that is replaced a moment later.
                    if let value = controller.value ?? identity.flatMap({ store.cachedCommunityInformation($0) }) {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("Community stats").font(.title2.bold())
                            if let stats = value.stats {
                                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 24) {
                                    GridRow { metric("Watchers", stats.watchers); metric("Plays", stats.plays); metric("Collectors", stats.collectors) }
                                    GridRow { metric("Comments", stats.comments); metric("Lists", stats.lists); Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                                }
                            } else { notice(value.statsState, sentiment: false) }
                        }
                        VStack(alignment: .leading, spacing: 18) {
                            Text("What people are saying").font(.title2.bold())
                            if let sentiments = value.sentiments, value.sentimentsState == .available {
                                VStack(alignment: .leading, spacing: 16) {
                                    ForEach(Array(sentiments.good.enumerated()), id: \.offset) { index, text in opinion(text, positive: true).accessibilityIdentifier("community-positive-\(index)") }
                                    ForEach(Array(sentiments.bad.enumerated()), id: \.offset) { index, text in opinion(text, positive: false).accessibilityIdentifier("community-negative-\(index)") }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                                    .accessibilityElement(children: .contain)
                                    .accessibilityIdentifier("community-sentiment-card")
                                Text("Trakt’s community summary · \(sentiments.commentCount.formatted()) comments · Updated \(sentiments.analyzedAt.prefix(10))")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            } else { notice(value.sentimentsState, sentiment: true) }
                        }
                        if value.statsState == .unavailable || value.sentimentsState == .unavailable {
                            Button("Retry community information") { retryRevision += 1 }.buttonStyle(.glass).buttonBorderShape(.capsule).disabled(controller.loading)
                        }
                    }
                    if controller.loading && controller.value == nil && identity.flatMap({ store.cachedCommunityInformation($0) }) == nil { DiaryLoadingPlaceholder(height: 300, label: "Loading community information") }
                    if let error = controller.error { RetryNotice(message: error) { retryRevision += 1 } }
                    Text("Community information from Trakt. These are overall activity and comment summaries, independent of your personal rating.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(20).padding(.bottom, 20)
            }.scrollContentBackground(.hidden).background(.clear)
        // Half height only, on the system glass: it never switches to the opaque large
        // sheet, so it stays see-through instead of flashing between the two.
        }.presentationDetents([.medium], selection: $detent).presentationDragIndicator(.visible)
            .modifier(SolidSheetBackground(enabled: reduceTransparency))
            .task(id: TaskIdentity(identity: identity, session: store.sessionRevision, retry: retryRevision)) {
                await controller.load(identity, retry: retryRevision > 0) { identity, retry in try await store.communityInformation(identity, retry: retry) }
            }
    }
    private struct TaskIdentity: Equatable { let identity: CommunityIdentity?; let session: UUID; let retry: Int }
    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value, format: .number.notation(.compactName)).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityValue(value.formatted())
    }
    private func opinion(_ text: String, positive: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Capsule().fill(positive ? Color.green : Color.red).frame(width: 3, height: 24).accessibilityHidden(true)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine).accessibilityLabel((positive ? "Positive: " : "Negative: ") + text)
    }
    private func notice(_ state: CommunityInformation.State, sentiment: Bool) -> some View {
        let text: String
        switch state {
        case .unmatched: text = identity == nil ? "Match this title to TMDB to see its community information." : "No matching Trakt title was found."
        case .notConfigured: text = "Trakt community information is not configured on this server."
        case .empty: text = sentiment ? "No community sentiment summary is available yet." : "No community activity is available yet."
        case .unavailable: text = sentiment ? "Trakt’s community sentiment summary is temporarily unavailable." : "Trakt’s community stats are temporarily unavailable."
        case .available: text = "Community information was incomplete. Please retry."
        }
        return Text(text).foregroundStyle(.secondary).font(.subheadline).fixedSize(horizontal: false, vertical: true)
    }
}

/// Reduce Transparency gets a solid sheet; otherwise the system glass shows through.
private struct SolidSheetBackground: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.presentationBackground(Color(webHex: "#1c1c1e")) } else { content }
    }
}
