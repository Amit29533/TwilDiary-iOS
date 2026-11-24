import SwiftUI
import Observation
import TwilDiaryCore

/// Studio (owner's request, Nov 2026): Native plus the redrawn Home, Glance, title, person and
/// Known for pages, and their motion. It is built on Native (`ThemePalette.studio` has `native`
/// set), so everything Native does still applies; each redrawn piece checks `Studio.on(_:)`.
/// Every change has its own switch (Settings → Appearance → Design lab), on by default, so the
/// owner can try them one at a time and keep the ones that work.
enum StudioChange: String, CaseIterable, Identifiable {
    // Home
    case homeHeader, heroLabel, heroTrack, heroDots, weekBar, posterCaptions, recommendedMatch, newEpisodeDate, groupedRecent
    // Glance
    case glanceHeader, glanceFilters, lastWatchedLabel, lastWatchedTrack, glanceButtons, glanceRows, glanceCaughtUp
    // Title page
    case titleMeta, titleRatings, titleWatchButton, titleStatus, titleAwards, titleCompanies, parentalSeverity
    // People
    case personHero, personFacts, personFrom, personAbout, personWatched, missingPoster, sectionCounts, knownForHeader, knownForRanking, shelfOrder
    // Everywhere
    case badgeTopLeft, layoutSwitch, pressNoBounce

    var id: Self { self }

    enum Group: String, CaseIterable, Identifiable {
        case home = "Home", glance = "Glance", title = "Title page", people = "People", everywhere = "Everywhere"
        var id: Self { self }
    }

    var group: Group {
        switch self {
        case .homeHeader, .heroLabel, .heroTrack, .heroDots, .weekBar, .posterCaptions, .recommendedMatch, .newEpisodeDate, .groupedRecent: .home
        case .glanceHeader, .glanceFilters, .lastWatchedLabel, .lastWatchedTrack, .glanceButtons, .glanceRows, .glanceCaughtUp: .glance
        case .titleMeta, .titleRatings, .titleWatchButton, .titleStatus, .titleAwards, .titleCompanies, .parentalSeverity: .title
        case .personHero, .personFacts, .personFrom, .personAbout, .personWatched, .missingPoster, .sectionCounts, .knownForHeader, .knownForRanking, .shelfOrder: .people
        case .badgeTopLeft, .layoutSwitch, .pressNoBounce: .everywhere
        }
    }

    var title: String {
        switch self {
        case .homeHeader: "Title left, sparkle right"
        case .heroLabel: "Readable hero text"
        case .heroTrack: "Episode track"
        case .heroDots: "Page dots"
        case .weekBar: "This week bar"
        case .posterCaptions: "Tight poster captions"
        case .recommendedMatch: "Match in the caption"
        case .newEpisodeDate: "Date on the episode line"
        case .groupedRecent: "Grouped Recently watched"
        case .glanceHeader: "Shorter Glance header"
        case .glanceFilters: "Dim empty filters"
        case .lastWatchedLabel: "Readable Last watched label"
        case .lastWatchedTrack: "Last watched episode track"
        case .glanceButtons: "Tinted + buttons"
        case .glanceRows: "Compact grouped rows"
        case .glanceCaughtUp: "Caught up section"
        case .titleMeta: "Rating on the meta line"
        case .titleRatings: "Ratings in one card"
        case .titleWatchButton: "Tinted Log a watch"
        case .titleStatus: "Quiet status card"
        case .titleAwards: "Wins and nominations"
        case .titleCompanies: "Monogram for missing logos"
        case .parentalSeverity: "Severity colours"
        case .personHero: "Photo backdrop"
        case .personFacts: "White name, facts together"
        case .personFrom: "Quieter From card"
        case .personAbout: "Bio first"
        case .personWatched: "Watched as a row"
        case .missingPoster: "Name tile for missing posters"
        case .sectionCounts: "Count pills"
        case .knownForHeader: "Plain Known for header"
        case .knownForRanking: "Lead roles first in Known for"
        case .shelfOrder: "Released titles first"
        case .badgeTopLeft: "Rating badge top-left"
        case .layoutSwitch: "Grey layout switches"
        case .pressNoBounce: "Press without bounce"
        }
    }

    var detail: String {
        switch self {
        case .homeHeader: "TwilDiary on the left, the sparkle button as a glass circle on the right."
        case .heroLabel: "Darker fades over the artwork and a plain white Continue watching label."
        case .heroTrack: "A capsule per episode under the hero; the next one is outlined."
        case .heroDots: "Dots under the hero show there's more to swipe."
        case .weekBar: "Watch time against last week on one bar; smaller Watches and Streak."
        case .posterCaptions: "Details right under the title; every caption the same height."
        case .recommendedMatch: "Recommended keeps the rating badge; the match % moves into the caption."
        case .newEpisodeDate: "New episodes: the date sits on the episode line."
        case .groupedRecent: "Recently watched as one card with dividers."
        case .glanceHeader: "Just \"Glance\"; the count stays on All."
        case .glanceFilters: "A filter with nothing in it is dimmer (still tappable)."
        case .lastWatchedLabel: "Plain white label over a darker fade."
        case .lastWatchedTrack: "Capsules for a short season in place of the fraction and bar."
        case .glanceButtons: "Row + buttons are tinted; one filled button per screen."
        case .glanceRows: "Rows in one card, smaller posters, the bar right under the details."
        case .glanceCaughtUp: "Finished seasons move from Continue to Caught up."
        case .titleMeta: "The certificate joins the year line; genre chips are grey."
        case .titleRatings: "The scores share one card with thin dividers."
        case .titleWatchButton: "Play stays filled; Log a watch is tinted."
        case .titleStatus: "Smaller grey zeros, and You and Community under the two circles."
        case .titleAwards: "\"1 win\" or \"4 nominations\" instead of numbering."
        case .titleCompanies: "Initials on a grey tile when there's no logo."
        case .parentalSeverity: "Amber for Moderate, red for Severe, the same in every row."
        case .personHero: "The person's own photo, blurred, behind the name."
        case .personFacts: "The name in one colour; Born, Age and Birthplace beside the photo."
        case .personFrom: "A plain From label and grey tags in the From card."
        case .personAbout: "The bio comes before Also known as."
        case .personWatched: "One or two watched titles show as rows."
        case .missingPoster: "A title with no poster shows its name on a grey tile."
        case .sectionCounts: "Shows and Movies counts as grey pills."
        case .knownForHeader: "\"Known for\" with the person's name under it."
        case .knownForRanking: "Ranked by how much of a title is theirs, so guest spots on big shows sink."
        case .shelfOrder: "Shows and Movies start with released work; self appearances and unreleased titles go last."
        case .badgeTopLeft: "Rating badges sit top-left on every poster."
        case .layoutSwitch: "List and grid switches are grey, never blue."
        case .pressNoBounce: "Cards sink quickly and settle without a bounce."
        }
    }
}

/// Which Studio changes are switched off (everything is on unless the owner turns it off).
@MainActor @Observable final class StudioLab {
    static let shared = StudioLab()
    static let key = "studio.lab.off"
    private(set) var off: Set<String>

    private init() { off = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? []) }

    func isOn(_ change: StudioChange) -> Bool { !off.contains(change.rawValue) }

    func set(_ change: StudioChange, on: Bool) {
        if on { off.remove(change.rawValue) } else { off.insert(change.rawValue) }
        UserDefaults.standard.set(off.sorted(), forKey: Self.key)
    }

    func turnAllOn() {
        off = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

enum Studio {
    /// True when Studio is the theme on screen.
    static var active: Bool { ThemeStore.current.studio }
    /// True when Studio is on screen and this change's switch is on.
    @MainActor static func on(_ change: StudioChange) -> Bool { ThemeStore.current.studio && StudioLab.shared.isOn(change) }
    /// The rating-badge corner a poster uses: top-left in Studio (owner's redraw), else the caller's own.
    @MainActor static func badgeCorner(_ usual: Alignment) -> Alignment { on(.badgeTopLeft) ? .topLeading : usual }
    /// "LAST WATCHED" → "Last watched".
    static func sentenceCase(_ text: String) -> String {
        let lower = text.lowercased()
        guard let first = lower.first else { return text }
        return first.uppercased() + lower.dropFirst()
    }
}

/// The title page's watch button (Log a watch, Mark E3 watched): Studio tints it, so Play stays
/// the one filled button on the page; otherwise the app's own watch style.
struct StudioWatchButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if Studio.on(.titleWatchButton) { content.buttonStyle(StudioTintedButtonStyle()) } else { content.buttonStyle(.diaryWatch) }
    }
}

/// A tinted capsule: accent text on a faint accent fill, sinking a little when pressed.
struct StudioTintedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Tinted(configuration: configuration) }
    private struct Tinted: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            let accent = Color(uiColor: .systemBlue)
            configuration.label.foregroundStyle(accent)
                .background(accent.opacity(0.18), in: Capsule())
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(reduceMotion ? nil : Motion.pressMotion(pressed: configuration.isPressed), value: configuration.isPressed)
        }
    }
}

/// Studio's list | grid switch: one grey capsule, the chosen side lighter (never the accent),
/// with the light thumb sliding across.
struct StudioLayoutSwitch: View {
    @Binding var grid: Bool
    /// The grid side's identifier; the list side adds "-list".
    var identifier = "layout"
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 2) {
            side(false, symbol: "list.bullet", label: "Show as list")
            side(true, symbol: "square.grid.2x2", label: "Show as grid")
        }.padding(3).background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
    private func side(_ value: Bool, symbol: String, label: String) -> some View {
        Button { withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { grid = value } } label: {
            Image(systemName: symbol).font(.app(size: 15, weight: .semibold))
                .foregroundStyle(grid == value ? Color(uiColor: .label) : Color(uiColor: .secondaryLabel))
                .frame(width: 42, height: 34)
                .background { if grid == value { Capsule().fill(Color(uiColor: .systemGray4)).matchedGeometryEffect(id: "thumb", in: thumb) } }
                .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityAddTraits(grid == value ? .isSelected : [])
            .accessibilityValue(grid ? "Grid" : "List")
            .accessibilityIdentifier(value ? identifier : identifier + "-list")
    }
}

/// Studio's episode track: one capsule per episode of a short season, the watched ones filled and
/// the next one outlined. Marking an episode fills its capsule and the outline glides to the next.
struct StudioEpisodeTrack: View {
    let watched: Int
    let total: Int
    var showsNext = true
    var tint: Color = Color(uiColor: .systemBlue)
    var track: Color = .white.opacity(0.22)
    @Namespace private var outline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Capsules stay readable up to 16 episodes; longer seasons keep the bar.
    static func fits(_ total: Int) -> Bool { (1...16).contains(total) }
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(total, 1), id: \.self) { index in
                Capsule().fill(track)
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint).scaleEffect(x: index < watched ? 1 : 0.001, anchor: .leading)
                    }
                    .overlay {
                        if showsNext && index == min(watched, total - 1) {
                            Capsule().strokeBorder(tint, lineWidth: 1).matchedGeometryEffect(id: "next", in: outline)
                        }
                    }
            }
        }.frame(height: 6)
            .animation(reduceMotion ? nil : .snappy(duration: 0.32), value: watched)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(watched) of \(total) episodes watched")
    }
}

/// Studio's ordering for a person's credits. The shared ranking (`PersonSections`) matches the web
/// app and its golden tests, so these run on top of it, only with their Design lab switches on.
enum StudioPeople {
    /// How much of a title is theirs, times how many people rated it: a TV part weighs its episodes
    /// out of 20 (a one-episode guest spot on a huge show weighs little; no count is taken as one).
    static func prominence(_ item: CatalogItem) -> Double {
        let audience = Double(max(0, item.votes ?? 0)) + 1
        let share = item.mediaType == .tv ? min(1, Double(max(1, item.episodeCount ?? 1)) / 20) : 1
        return audience * share
    }
    /// Talk shows, award nights and halftime shows ("Self", "Self - Guest").
    static func isSelf(_ item: CatalogItem) -> Bool {
        (item.character ?? "").range(of: #"^\s*(?:self|himself|herself|themselves)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// Known for: their own roles (no self appearances), most prominent first; ties keep their order.
    static func rankKnownFor(_ items: [CatalogItem]) -> [CatalogItem] {
        let roles = items.filter { !isSelf($0) }
        return (roles.isEmpty ? items : roles).enumerated().sorted { a, b in
            let first = prominence(a.element), second = prominence(b.element)
            return first != second ? first > second : a.offset < b.offset
        }.map(\.element)
    }
    /// Released work first (in the order given, newest first), then self appearances, then titles
    /// with no year or a year still to come.
    static func releasedFirst(_ items: [CatalogItem], currentYear: Int) -> [CatalogItem] {
        func group(_ item: CatalogItem) -> Int {
            guard let year = item.year, year <= currentYear else { return 2 }
            return isSelf(item) ? 1 : 0
        }
        return items.enumerated().sorted { a, b in
            let first = group(a.element), second = group(b.element)
            return first != second ? first < second : a.offset < b.offset
        }.map(\.element)
    }
}

/// Settings → Appearance → Design lab: one switch per Studio change, grouped by page.
struct StudioDesignLab: View {
    @State private var lab = StudioLab.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(StudioChange.Group.allCases) { group in
                SettingsGroup(label: group == .home ? "Design lab · " + group.rawValue : group.rawValue) {
                    let changes = StudioChange.allCases.filter { $0.group == group }
                    ForEach(Array(changes.enumerated()), id: \.element) { index, change in
                        if index > 0 { SettingsDivider() }
                        Toggle(isOn: Binding(get: { lab.isOn(change) }, set: { lab.set(change, on: $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.title).font(.app(size: 17)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                                Text(change.detail).font(.app(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(2)
                            }
                        }.tint(Color(uiColor: .systemGreen)).padding(.horizontal, 16).padding(.vertical, 9).frame(minHeight: 52)
                            .accessibilityIdentifier("studio-lab-" + change.rawValue)
                    }
                }
            }
            if !lab.off.isEmpty {
                Button("Turn every change back on") { lab.turnAllOn() }
                    .font(.app(size: 15, weight: .semibold)).padding(.leading, 16)
                    .accessibilityIdentifier("studio-lab-all-on")
            }
            SettingsFootnote(text: "Each switch changes one thing on screen, right away. Keep the ones you like.")
        }
    }
}
