import SwiftUI
import TwilDiaryCore

struct ProfileFact: Identifiable {
    let id: String
    let icon: String
    let label: String
    let value: String
    let wide: Bool
    init?(id: String, icon: String, label: String, value: String?, wide: Bool = false) {
        guard let value = ProfileText.line(value) else { return nil }
        self.id = id; self.icon = icon; self.label = label; self.value = value; self.wide = wide
    }
}

struct ProfileFacts: View {
    let items: [ProfileFact]
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var iconWidth = 16
    var body: some View {
        if !items.isEmpty { facts }
    }
    private var facts: some View {
        ProfileFactsLayout(singleColumn: typeSize.isAccessibilitySize) {
            ForEach(items) { fact in
                VStack(alignment: .leading, spacing: 10) {
                    if fact.wide { Divider().overlay(.white.opacity(0.08)).accessibilityHidden(true) }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: fact.icon).font(.subheadline).foregroundStyle(.secondary)
                            .frame(width: iconWidth).padding(.top, 1).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(fact.label).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(AniListText.formatted(fact.value, hideSpoilers: false))
                                .font(fact.wide ? .subheadline : .subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .foregroundStyle(Color(webHex: "#e6e2ec")).tint(Color(webHex: "#d1cdd8"))
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine).accessibilityIdentifier(fact.id)
                    .layoutValue(key: ProfileFactWide.self, value: fact.wide)
            }
        }
    }
}

private struct ProfileFactWide: LayoutValueKey { static let defaultValue = false }

/// Pair compact, borderless facts at equal width and height. Location/agency fields span the
/// available width; neither their words nor the user's text size are shortened.
private struct ProfileFactsLayout: Layout {
    let singleColumn: Bool
    private let columnGap: CGFloat = 20
    private let rowGap: CGFloat = 14
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? 320)
        return CGSize(width: width, height: frames(subviews, width: width).map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, frame) in frames(subviews, width: bounds.width).enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                                 proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
    private func frames(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var result: [CGRect] = [], pending: Int?, y: CGFloat = 0
        let column = max(0, (width - columnGap) / 2)
        for view in subviews {
            if singleColumn || width < 280 || view[ProfileFactWide.self] {
                if let previous = pending {
                    let height = max(44, subviews[previous].sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
                    result[previous].size = CGSize(width: width, height: height)
                    y = result[previous].maxY + rowGap; pending = nil
                }
                let height = max(44, view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
                result.append(CGRect(x: 0, y: y, width: width, height: height)); y += height + rowGap
            } else {
                let height = max(44, view.sizeThatFits(ProposedViewSize(width: column, height: nil)).height)
                if let previous = pending {
                    let row = max(height, result[previous].height)
                    result[previous].size.height = row
                    result.append(CGRect(x: column + columnGap, y: y, width: column, height: row))
                    y += row + rowGap; pending = nil
                } else {
                    pending = result.count
                    result.append(CGRect(x: 0, y: y, width: column, height: height))
                }
            }
        }
        if let previous = pending {
            let height = max(44, subviews[previous].sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
            result[previous].size = CGSize(width: width, height: height)
        }
        return result
    }
}

/// "Source: Wikipedia" under a bio, in place of the credit sentence.
struct ProfileSourceNote: View {
    let source: String
    var body: some View {
        Text("Source: " + source).font(.caption).foregroundStyle(.tertiary).accessibilityIdentifier("profile-biography-source")
    }
}

struct ProfileAliases: View {
    let values: [String]
    var excluding: [String] = []
    @State private var expanded = false
    var body: some View {
        let aliases = ProfileText.aliases(values, excluding: excluding)
        if !aliases.isEmpty {
            ProfileBiography(text: AttributedString("Also known as: " + aliases.joined(separator: " · ")), expanded: $expanded,
                             identifier: "profile-aliases", collapsedLines: 2, style: .subheadline,
                             moreLabel: "More names", lessLabel: "Fewer names")
        }
    }
}

struct ProfileCardCaption: View {
    let title: String
    var secondary = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Text(title).font(secondary ? .caption : .subheadline.weight(.semibold))
            .foregroundStyle(secondary ? Color.secondary : Color.primary)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            .fixedSize(horizontal: false, vertical: true).accessibilityLabel(title)
    }
}

struct ProfileShelf<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if typeSize.isAccessibilitySize { LazyVStack(alignment: .leading, spacing: 16) { content } }
        else {
            ScrollView(.horizontal) { LazyHStack(alignment: .top, spacing: 12) { content } }.scrollIndicators(.hidden)
        }
    }
}

struct ProfileMediaRow: View {
    let image: String?
    let name: String
    var detail: String? = nil
    var score: Double? = nil
    var provider: String? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Artwork(path: image, title: name).frame(width: 64, height: 96).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                ProfileCardCaption(title: name)
                if let detail = ProfileText.line(detail) { ProfileCardCaption(title: detail, secondary: true) }
                if let score, score > 0 {
                    RatingBadge(score: score, source: provider)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.primary)
            // Plain buttons otherwise expose only the union of the artwork/text
            // bounds, leaving the trailing whitespace outside the row's action.
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}

/// Supplemental fields remain labelled text. External websites have a separate
/// section; links to characters/staff/anime stay in prose and use native routing.
struct ProfileAbout: View {
    let content: ProfileFormattedBiography
    var excludingFacts: Set<String> = []
    var additionalLinks: [ProfileWebsiteLink] = []
    var biographyID = "profile-biography"
    /// Prose to show instead of the description's own (the merged person page uses TMDB's when
    /// AniList's says less); facts, links and references still come from the description.
    var biographyOverride: AttributedString? = nil
    /// Shown under the bio as "Source: …" (the credit line is cut from the prose).
    var sourceOverride: String? = nil
    @State private var expanded = false
    @State private var detailsExpanded = false
    var body: some View {
        let facts = content.facts.filter { !excludingFacts.contains($0.id) }
        let sites = (content.links + additionalLinks).reduce(into: [ProfileWebsiteLink]()) { values, link in
            if !values.contains(where: { $0.id == link.id }) { values.append(link) }
        }
        VStack(alignment: .leading, spacing: 18) {
            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(detailsExpanded ? facts : Array(facts.prefix(3))) { fact in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fact.label).font(.caption).foregroundStyle(.secondary)
                            Text(AniListText.formatted(fact.markdown, hideSpoilers: false)).font(.subheadline)
                                .foregroundStyle(Color(webHex: "#e6e2ec")).tint(Color(webHex: "#d1cdd8"))
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .contain).accessibilityIdentifier("profile-detail-" + fact.id)
                    }
                    if facts.count > 3 {
                        Button(detailsExpanded ? "Fewer details" : "More details") { detailsExpanded.toggle() }
                            .font(.subheadline).buttonStyle(.plain).foregroundStyle(.primary).frame(minHeight: 44)
                    }
                }.accessibilityIdentifier("profile-additional-details")
            }
            if !sites.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Links").font(.caption).foregroundStyle(.secondary)
                    ProfileWebsiteButtons(links: sites)
                }.accessibilityElement(children: .contain).accessibilityIdentifier("profile-links-section")
            }
            if !content.references.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Related profiles and titles").font(.caption).foregroundStyle(.secondary)
                    InlineFlowLayout(spacing: 12, rowSpacing: 4) {
                        ForEach(content.references) { link in
                            Link(destination: link.url) { Text(link.title).underline().font(.subheadline).frame(minHeight: 44) }
                                .buttonStyle(.plain).foregroundStyle(Color(webHex: "#e6e2ec"))
                                .accessibilityIdentifier("profile-reference-" + link.id)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ProfileBiography(text: biographyOverride ?? AniListText.formatted(content.markdown, hideSpoilers: false), expanded: $expanded,
                                 identifier: biographyID)
                if let source = biographyOverride == nil ? content.source : sourceOverride { ProfileSourceNote(source: source) }
            }
        }
    }
}
