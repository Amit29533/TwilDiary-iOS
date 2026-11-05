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

/// A profile's facts in one card. Short facts (dates, age, height, counts) share a grid of up to
/// three columns, fewer when a value wouldn't fit, so nothing is truncated; long facts (places,
/// date of death) are full-width rows with the label on the left and the value on the right, and
/// a value too long for one line moves under its label and wraps. Labels read before values.
struct ProfileFacts: View {
    let items: [ProfileFact]
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if !items.isEmpty { card }
    }
    private var card: some View {
        let short = items.filter { !$0.wide }, wide = items.filter(\.wide)
        return VStack(alignment: .leading, spacing: 0) {
            if !short.isEmpty {
                ProfileStatGrid(maxColumns: typeSize.isAccessibilitySize ? 1 : 3) {
                    ForEach(short) { fact in stat(fact) }
                }.padding(.vertical, 4)
            }
            ForEach(Array(wide.enumerated()), id: \.element.id) { index, fact in
                if index > 0 || !short.isEmpty { Divider().overlay(.white.opacity(0.06)).padding(.horizontal, 12).accessibilityHidden(true) }
                row(fact)
            }
        }
        .foregroundStyle(Color(webHex: "#e6e2ec")).tint(Color(webHex: "#d1cdd8"))
        .background(Color(webHex: "#141418"), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
    }
    private func label(_ fact: ProfileFact) -> some View {
        HStack(spacing: 5) {
            Image(systemName: fact.icon).imageScale(.small).accessibilityHidden(true)
            Text(fact.label).fixedSize(horizontal: false, vertical: true)
        }.font(.caption).foregroundStyle(.secondary)
    }
    private func value(_ fact: ProfileFact) -> Text {
        Text(AniListText.formatted(fact.value, hideSpoilers: false)).font(.subheadline.weight(.semibold))
    }
    private func stat(_ fact: ProfileFact) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label(fact)
            value(fact).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine).accessibilityIdentifier(fact.id)
    }
    private func row(_ fact: ProfileFact) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                label(fact).fixedSize()
                Spacer(minLength: 12)
                value(fact).lineLimit(1).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                label(fact)
                value(fact).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 12).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine).accessibilityIdentifier(fact.id)
    }
}

/// Short facts in equal columns and equal-height rows: three when every value fits, else two,
/// else one; of the counts that fit, the one with the fewest rows and empty cells (four facts
/// make two by two rather than three and one).
private struct ProfileStatGrid: Layout {
    let maxColumns: Int
    private let columnGap: CGFloat = 4
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
    private func columnWidth(_ count: Int, _ width: CGFloat) -> CGFloat {
        max(0, (width - columnGap * CGFloat(count - 1)) / CGFloat(count))
    }
    private func columns(_ subviews: Subviews, width: CGFloat) -> Int {
        guard !subviews.isEmpty else { return 1 }
        var best = 1, bestScore = (subviews.count, 0)
        for count in 2...max(2, maxColumns) where count <= maxColumns && count <= subviews.count {
            let column = columnWidth(count, width)
            guard subviews.allSatisfy({ $0.sizeThatFits(.unspecified).width <= column + 0.5 }) else { continue }
            let rows = (subviews.count + count - 1) / count, empty = rows * count - subviews.count
            if (rows, empty) < bestScore { best = count; bestScore = (rows, empty) }
        }
        return best
    }
    private func frames(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        let count = columns(subviews, width: width), column = columnWidth(count, width)
        var result: [CGRect] = [], y: CGFloat = 0
        for start in stride(from: 0, to: subviews.count, by: count) {
            let row = start..<min(start + count, subviews.count)
            let height = row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
            for (offset, _) in row.enumerated() {
                result.append(CGRect(x: CGFloat(offset) * (column + columnGap), y: y, width: column, height: height))
            }
            y += height
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
