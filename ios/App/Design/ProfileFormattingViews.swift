import SwiftUI
import UIKit

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
                if index > 0 || !short.isEmpty { Divider().overlay(Color.primary.opacity(0.06)).padding(.horizontal, 12).accessibilityHidden(true) }
                row(fact)
            }
        }
        .foregroundStyle(Color(themed: "#e6e2ec")).tint(Color(themed: "#d1cdd8"))
        .background(Color(themed: "#141418"), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
    }
    private func label(_ fact: ProfileFact) -> some View {
        HStack(spacing: 5) {
            Image(systemName: fact.icon).imageScale(.small).accessibilityHidden(true)
            Text(fact.label).fixedSize(horizontal: false, vertical: true)
        }.font(.caption).foregroundStyle(Color(themed: "#a9a7b6"))
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

/// "Also known as" on cast, voice actor and character pages: a card in the facts box's style with
/// each name as a chip (the first eight, then "+N more"), instead of a run-on sentence of up to
/// twenty names in several scripts (owner's request). Hold a name to copy it.
struct ProfileAliases: View {
    let values: [String]
    var excluding: [String] = []
    @State private var expanded = false
    private static let shown = 8
    var body: some View {
        let aliases = ProfileText.aliases(values, excluding: excluding)
        if !aliases.isEmpty {
            let visible = expanded ? aliases : Array(aliases.prefix(Self.shown))
            VStack(alignment: .leading, spacing: 10) {
                Text("ALSO KNOWN AS").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Color(themed: "#a9a7b6"))
                InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                    ForEach(visible, id: \.self) { name in
                        Text(name).font(.subheadline).foregroundStyle(HomeStyle.primary).lineLimit(2)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                            .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = name } }
                    }
                    if aliases.count > Self.shown {
                        Button(expanded ? "Fewer" : "+\(aliases.count - Self.shown) more") {
                            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                        }.font(.subheadline.weight(.semibold)).foregroundStyle(HomeStyle.chipText)
                            .padding(.horizontal, 12).padding(.vertical, 6).background(HomeStyle.chip, in: Capsule())
                            .buttonStyle(.plain).accessibilityIdentifier("profile-aliases-more")
                    }
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(themed: "#141418"), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
            .accessibilityElement(children: .contain).accessibilityLabel("Also known as")
            .accessibilityIdentifier("profile-aliases")
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
    var body: some View {
        let facts = content.facts.filter { !excludingFacts.contains($0.id) }
        let sites = (content.links + additionalLinks).reduce(into: [ProfileWebsiteLink]()) { values, link in
            if !values.contains(where: { $0.id == link.id }) { values.append(link) }
        }
        VStack(alignment: .leading, spacing: 18) {
            // The prose first, then what the description lists, each kind in its own card.
            VStack(alignment: .leading, spacing: 4) {
                ProfileBiography(text: biographyOverride ?? AniListText.formatted(content.markdown, hideSpoilers: false), expanded: $expanded,
                                 identifier: biographyID)
                if let source = biographyOverride == nil ? content.source : sourceOverride { ProfileSourceNote(source: source) }
            }
            if !facts.isEmpty { ProfileHighlights(facts: facts).accessibilityIdentifier("profile-additional-details") }
            ForEach(content.sections) { section in ProfileSectionCard(section: section) }
            if !sites.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LINKS").font(.system(size: 13, weight: .bold)).foregroundStyle(Color(themed: "#a9a7b6"))
                    ProfileWebsiteButtons(links: sites)
                }.accessibilityElement(children: .contain).accessibilityIdentifier("profile-links-section")
            }
            if !content.references.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RELATED PROFILES AND TITLES").font(.system(size: 13, weight: .bold)).foregroundStyle(Color(themed: "#a9a7b6"))
                    InlineFlowLayout(spacing: 12, rowSpacing: 4) {
                        ForEach(content.references) { link in
                            Link(destination: link.url) { Text(link.title).underline().font(.subheadline).frame(minHeight: 44) }
                                .buttonStyle(.plain).foregroundStyle(Color(themed: "#e6e2ec"))
                                .accessibilityIdentifier("profile-reference-" + link.id)
                        }
                    }
                }
            }
        }
    }
}

// MARK: Highlights (owner's request): the description's common fields, picked out by kind

/// One card per kind of field (Profile, Affiliations, Role and rank, Powers and abilities, Family
/// and relations, Likes and hobbies, More details), in that order.
struct ProfileHighlights: View {
    let facts: [ProfileFormattedBiography.Fact]
    var body: some View {
        let groups = Dictionary(grouping: facts, by: \.kind).sorted { $0.key < $1.key }
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups, id: \.key) { kind, facts in
                ProfileHighlightCard(title: kind.title, icon: kind.icon) {
                    ForEach(facts) { fact in
                        VStack(alignment: .leading, spacing: 8) {
                            // A card with one field named like the card needs no second label.
                            if facts.count > 1 || !(kind == .affiliation || kind == .relations || fact.label.lowercased() == kind.title.lowercased()) {
                                Text(fact.label.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.4).foregroundStyle(Color(themed: "#a9a7b6"))
                            }
                            if kind == .relations { ProfileRelations(items: fact.items) } else { ProfileValue(fact: fact) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .contain).accessibilityIdentifier("profile-detail-" + fact.id)
                    }
                }
            }
        }
    }
}

/// The highlight container: a small tinted tile with the kind's symbol, its title, then its content.
struct ProfileHighlightCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                    .frame(width: 30, height: 30).background(HomeStyle.chip, in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
                Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(HomeStyle.primary)
            }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            content
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
    }
}

/// A field's value: short items as chips, longer ones as a dotted list, prose as text.
private struct ProfileValue: View {
    let fact: ProfileFormattedBiography.Fact
    var body: some View {
        let items = fact.items
        if items.allSatisfy({ ProfileFormattedBiography.Fact.visible($0).count <= 34 }) {
            InlineFlowLayout(spacing: 6, rowSpacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in ProfileChip(markdown: item) }
            }
        } else if items.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(HomeStyle.chipText).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        ProfileRichText(markdown: item)
                    }
                }
            }
        } else {
            ProfileRichText(markdown: fact.markdown)
        }
    }
}

/// "[Loid Forger](…) (Adoptive Father)": the name (still a link) with the relation under it.
private struct ProfileRelations: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Rectangle().fill(Color(themed: "#1c1c23")).frame(height: HomeStyle.hairline) }
                let (name, relation) = Self.split(item)
                HStack(spacing: 12) {
                    Image(systemName: "person.fill").font(.system(size: 13)).foregroundStyle(HomeStyle.chipText)
                        .frame(width: 32, height: 32).background(HomeStyle.round, in: Circle()).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AniListText.formatted(name, hideSpoilers: false)).font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(HomeStyle.primary).tint(HomeStyle.primary).lineLimit(2)
                        if let relation { Text(relation).font(.system(size: 12)).foregroundStyle(Color(themed: "#a9a7b6")).lineLimit(2) }
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 8)
            }
        }
    }
    static func split(_ item: String) -> (String, String?) {
        guard let match = item.firstMatch(of: /^(.*\S)\s*\(([^()]{1,60})\)\s*$/), !String(match.1).hasSuffix("](") else { return (item, nil) }
        return (String(match.1), String(match.2).prefix(1).uppercased() + String(match.2).dropFirst())
    }
}

private struct ProfileChip: View {
    let markdown: String
    var body: some View {
        Text(AniListText.formatted(markdown, hideSpoilers: false)).font(.system(size: 14, weight: .semibold))
            .foregroundStyle(HomeStyle.primary).tint(HomeStyle.chipText).lineLimit(1)
            .padding(.horizontal, 12).frame(minHeight: 32)
            .pillSurface(border: nil)
            .overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
    }
}

private struct ProfileRichText: View {
    let markdown: String
    var body: some View {
        Text(AniListText.formatted(markdown, hideSpoilers: false)).font(.system(size: 15)).lineSpacing(2)
            .foregroundStyle(HomeStyle.primary).tint(HomeStyle.chipText).fixedSize(horizontal: false, vertical: true)
    }
}

/// A bulleted part of a description ("Awards", "Trivia", "Non-anime roles") as its own card:
/// the first four items; "Show all" opens the whole list in a sheet, so the page never grows long
/// or jumps when it's closed again.
struct ProfileSectionCard: View {
    let section: ProfileFormattedBiography.Section
    @State private var all = false
    var body: some View {
        ProfileHighlightCard(title: section.title, icon: section.icon) {
            VStack(alignment: .leading, spacing: 9) {
                items(Array(section.items.prefix(4)))
                if section.items.count > 4 {
                    Button("Show all \(section.items.count)") { all = true }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.chipText).buttonStyle(.plain).frame(minHeight: 36)
                        .accessibilityIdentifier("profile-section-all-" + section.id)
                }
            }
        }.accessibilityIdentifier("profile-section-" + section.id)
            .sheet(isPresented: $all) {
                NavigationStack {
                    ScrollView { items(section.items).padding(.horizontal, 20).padding(.vertical, 12) }
                        .background(Color(themed: "#111116"))
                        .navigationTitle(section.title).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { all = false } } }
                }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
    }
    private func items(_ list: [String]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Circle().fill(HomeStyle.chipText).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                    ProfileRichText(markdown: item)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Awards a TMDB biography mentions, as chips.
struct ProfileAwards: View {
    let awards: [String]
    var body: some View {
        if !awards.isEmpty {
            ProfileHighlightCard(title: "Awards and honours", icon: "trophy") {
                InlineFlowLayout(spacing: 6, rowSpacing: 6) { ForEach(awards, id: \.self) { ProfileChip(markdown: $0) } }
            }.accessibilityIdentifier("profile-awards")
        }
    }
}

/// Where you came to this profile from (owner's request: one consistent row on actor, voice actor
/// and character pages, in the facts card's style): FROM, the title, and the role when it's known
/// ("as Emma" with a Voice tag). Tapping goes back to that title.
struct ProfileSourceRow: View {
    let title: String
    var role: String? = nil
    let action: () -> Void
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    /// "Emma (voice)" → "Emma" and a Voice tag.
    private var parts: (name: String, voice: Bool)? {
        guard let role = ProfileText.line(role) else { return nil }
        let voice = role.localizedCaseInsensitiveContains("(voice)")
        let name = role.replacingOccurrences(of: "(voice)", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : (name, voice)
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.accent)
                    .frame(width: 36, height: 36).background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("FROM").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Color(themed: "#a9a7b6"))
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(HomeStyle.primary)
                        .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if let parts {
                        HStack(spacing: 6) {
                            Text("as " + parts.name).font(.caption).foregroundStyle(Color(themed: "#a9a7b6")).lineLimit(1)
                            if parts.voice {
                                Text("Voice").font(.system(size: 10, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(HomeStyle.chip, in: Capsule())
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.uturn.backward").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(themed: "#a9a7b6"))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(themed: "#141418"), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Goes back to \(title)")
    }
}
