import SwiftUI
import Observation
import TwilDiaryCore

/// Design Lab (owner's request, Nov 2026): Settings → Design Lab. The redrawn pieces the owner
/// kept as choices, in any theme; everything else from the redraws is simply how the app looks now.
/// Each choice checks `Studio.on(_:)`; the rating badge, corners and Recommended's match are the
/// lab's other settings. "Original" is the app as it was; "Studio" turns every choice on.
/// (Studio was a theme for one build; `DesignLabMigration` moves anyone on it to Native with every choice on.)
enum StudioChange: String, CaseIterable, Identifiable {
    // Home
    case homeHeader, heroTrack, groupedRecent
    // Glance
    case lastWatchedTrack, glanceRows
    // Title page
    case parentalSeverity
    // People
    case personHero, personName

    var id: Self { self }

    /// The lab's pages: an area of the app.
    enum Area: String, CaseIterable, Identifiable {
        case home = "Home", glance = "Glance", title = "Title page", people = "People"
        var id: Self { self }
        var symbol: String {
            switch self { case .home: "house.fill"; case .glance: "plus.circle.fill"; case .title: "film.fill"; case .people: "person.fill" }
        }
        var tile: Color {
            switch self { case .home: Color(uiColor: .systemBlue); case .glance: Color(uiColor: .systemTeal); case .title: Color(uiColor: .systemOrange); case .people: Color(uiColor: .systemPurple) }
        }
        static var pages: [Area] { allCases }
    }

    var area: Area {
        switch self {
        case .homeHeader, .heroTrack, .groupedRecent: .home
        case .lastWatchedTrack, .glanceRows: .glance
        case .parentalSeverity: .title
        case .personHero, .personName: .people
        }
    }

    /// The heading it sits under on its area's page.
    var section: String {
        switch self {
        case .homeHeader, .heroTrack: "Hero"
        case .groupedRecent: "Lists"
        case .lastWatchedTrack: "Last watched"
        case .glanceRows: "The list"
        case .parentalSeverity: "Parental guide"
        case .personHero, .personName: "Header"
        }
    }

    var title: String {
        switch self {
        case .homeHeader: "Logo"
        case .heroTrack: "Progress"
        case .groupedRecent: "Recently watched"
        case .lastWatchedTrack: "Progress"
        case .glanceRows: "Rows"
        case .parentalSeverity: "Colours"
        case .personHero: "Backdrop"
        case .personName: "Name"
        }
    }

    /// The two choices: as it was (off) and the redraw (on).
    var choices: (off: String, on: String) {
        switch self {
        case .homeHeader: ("Left", "Right")
        case .heroTrack, .lastWatchedTrack: ("Bar", "Episode capsules")
        case .groupedRecent: ("Separate cards", "One grouped card")
        case .glanceRows: ("Cards", "Compact")
        case .parentalSeverity: ("By category", "By severity")
        case .personHero: ("Title art", "Own photo")
        case .personName: ("Two-tone", "White")
        }
    }

    /// One line under the choice, where the two words need explaining.
    var note: String? {
        switch self {
        case .glanceRows: "Compact: one card, smaller posters, the bar under the details."
        case .parentalSeverity: "By severity: amber for Moderate, red for Severe, the same in every row."
        case .personHero: "Own photo: blurred behind the name, so no other actor shows there."
        case .personName: "Two-tone shows the second name in the accent colour."
        default: nil
        }
    }
}

/// Where a poster's rating badge sits: each place's own corner (as it was), all top-left, all
/// bottom-left, or none.
enum DesignBadge: String, CaseIterable, Identifiable {
    case original, topLeft, bottomLeft, hidden
    var id: Self { self }
    var title: String { switch self { case .original: "As is"; case .topLeft: "Top"; case .bottomLeft: "Bottom"; case .hidden: "Off" } }
}

/// How round posters and cards are.
enum DesignCorners: String, CaseIterable, Identifiable {
    case squarer, standard, rounder
    var id: Self { self }
    var title: String { switch self { case .squarer: "Squarer"; case .standard: "Standard"; case .rounder: "Rounder" } }
    var scale: CGFloat { switch self { case .squarer: 0.55; case .standard: 1; case .rounder: 1.35 } }
}

/// Recommended's match: a pill on the poster (as it was), green in the caption, or not shown.
enum DesignMatch: String, CaseIterable, Identifiable {
    case onPoster, inCaption, hidden
    var id: Self { self }
    var title: String { switch self { case .onPoster: "On poster"; case .inCaption: "In caption"; case .hidden: "Hidden" } }
}

/// The lab's storage keys (plain strings, readable before the app's views exist).
enum DesignLabKeys {
    static let on = "designLab.on"
    static let badge = "designLab.badge"
    static let corners = "designLab.corners"
    static let match = "designLab.match"
    /// Your Custom mix while Original is chosen.
    static let savedOn = "designLab.saved.on", savedBadge = "designLab.saved.badge"
    static let savedCorners = "designLab.saved.corners", savedMatch = "designLab.saved.match"
}

/// Studio was a theme for one build (Nov 2026). Anyone on it moves to Native with every choice
/// on, a Custom mix (the switches they had turned off stay off), before the theme is first read.
enum DesignLabMigration {
    static func run(_ defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: "theme") == "studio" else { return }
        defaults.set("native", forKey: "theme")
        var off = Set(defaults.stringArray(forKey: "studio.lab.off") ?? [])
        // The name's colour was part of "personFacts" then; it's its own choice now.
        if off.contains("personFacts") { off.insert("personName") }
        defaults.set(StudioChange.allCases.map(\.rawValue).filter { !off.contains($0) }, forKey: DesignLabKeys.on)
        defaults.set((off.contains("badgeTopLeft") ? DesignBadge.original : .topLeft).rawValue, forKey: DesignLabKeys.badge)
        defaults.set((off.contains("recommendedMatch") ? DesignMatch.onPoster : .inCaption).rawValue, forKey: DesignLabKeys.match)
        defaults.removeObject(forKey: "studio.lab.off")
    }
}

/// Design Lab's choices. Nothing is on until the owner picks Studio or a piece (Original).
@MainActor @Observable final class StudioLab {
    static let shared = StudioLab()
    private(set) var on: Set<String>
    private(set) var badge: DesignBadge
    private(set) var corners: DesignCorners
    private(set) var match: DesignMatch

    /// Original (every choice as it was) or Custom (your own mix). Owner's request: no Studio preset.
    enum Preset: String, CaseIterable, Identifiable {
        case original, custom
        var id: Self { self }
        var title: String { switch self { case .original: "Original"; case .custom: "Custom" } }
    }

    private init() {
        DesignLabMigration.run()
        let defaults = UserDefaults.standard
        on = Set(defaults.stringArray(forKey: DesignLabKeys.on) ?? [])
        badge = DesignBadge(rawValue: defaults.string(forKey: DesignLabKeys.badge) ?? "") ?? .original
        corners = DesignCorners(rawValue: defaults.string(forKey: DesignLabKeys.corners) ?? "") ?? .standard
        match = DesignMatch(rawValue: defaults.string(forKey: DesignLabKeys.match) ?? "") ?? .onPoster
    }

    func isOn(_ change: StudioChange) -> Bool { on.contains(change.rawValue) }

    func set(_ change: StudioChange, on value: Bool) {
        if value { on.insert(change.rawValue) } else { on.remove(change.rawValue) }
        UserDefaults.standard.set(on.sorted(), forKey: DesignLabKeys.on)
    }
    func setBadge(_ value: DesignBadge) { badge = value; UserDefaults.standard.set(value.rawValue, forKey: DesignLabKeys.badge) }
    func setCorners(_ value: DesignCorners) { corners = value; UserDefaults.standard.set(value.rawValue, forKey: DesignLabKeys.corners) }
    func setMatch(_ value: DesignMatch) { match = value; UserDefaults.standard.set(value.rawValue, forKey: DesignLabKeys.match) }

    /// How many of an area's pieces are redrawn.
    func count(_ area: StudioChange.Area) -> (on: Int, of: Int) {
        let changes = StudioChange.allCases.filter { $0.area == area }
        return (changes.filter { isOn($0) }.count, changes.count)
    }

    /// Original: every choice as it was. Anything else is Custom.
    var preset: Preset {
        on.isEmpty && badge == .original && corners == .standard && match == .onPoster ? .original : .custom
    }
    /// Your mix, kept when you pick Original, so picking Custom brings it back.
    var hasSavedMix: Bool { UserDefaults.standard.object(forKey: DesignLabKeys.savedOn) != nil }

    func apply(_ preset: Preset) {
        let defaults = UserDefaults.standard
        switch preset {
        case .original:
            guard self.preset == .custom else { return }
            defaults.set(on.sorted(), forKey: DesignLabKeys.savedOn)
            defaults.set(badge.rawValue, forKey: DesignLabKeys.savedBadge)
            defaults.set(corners.rawValue, forKey: DesignLabKeys.savedCorners)
            defaults.set(match.rawValue, forKey: DesignLabKeys.savedMatch)
            on = []; badge = .original; corners = .standard; match = .onPoster
        case .custom:
            guard self.preset == .original, let saved = defaults.stringArray(forKey: DesignLabKeys.savedOn) else { return }
            on = Set(saved)
            badge = DesignBadge(rawValue: defaults.string(forKey: DesignLabKeys.savedBadge) ?? "") ?? .original
            corners = DesignCorners(rawValue: defaults.string(forKey: DesignLabKeys.savedCorners) ?? "") ?? .standard
            match = DesignMatch(rawValue: defaults.string(forKey: DesignLabKeys.savedMatch) ?? "") ?? .onPoster
        }
        defaults.set(on.sorted(), forKey: DesignLabKeys.on)
        defaults.set(badge.rawValue, forKey: DesignLabKeys.badge)
        defaults.set(corners.rawValue, forKey: DesignLabKeys.corners)
        defaults.set(match.rawValue, forKey: DesignLabKeys.match)
    }
}

enum Studio {
    /// True when this redrawn piece is chosen in Design Lab (any theme).
    @MainActor static func on(_ change: StudioChange) -> Bool { StudioLab.shared.isOn(change) }
    /// The theme's accent, for tinted buttons and progress (blue in Native, violet in Twilight…).
    @MainActor static var accent: Color { TilePrefs.shared.theme.accent }
    /// The rating-badge corner a poster uses: the caller's own unless Design Lab moves them all.
    @MainActor static func badgeCorner(_ usual: Alignment) -> Alignment {
        switch StudioLab.shared.badge {
        case .topLeft: .topLeading
        case .bottomLeft: .bottomLeading
        case .original, .hidden: usual
        }
    }
    /// False when Design Lab hides rating badges on posters.
    @MainActor static var showsBadge: Bool { StudioLab.shared.badge != .hidden }
    /// A poster's or card's corner radius, as Design Lab's Corners has it.
    @MainActor static func corner(_ radius: CGFloat) -> CGFloat { (radius * StudioLab.shared.corners.scale).rounded() }
    /// "LAST WATCHED" → "Last watched".
    static func sentenceCase(_ text: String) -> String {
        let lower = text.lowercased()
        guard let first = lower.first else { return text }
        return first.uppercased() + lower.dropFirst()
    }
}

/// The title page's watch button (Log a watch, Mark E3 watched): tinted, so Play stays the one
/// filled button on the page (owner's redraw, now standard).
struct StudioWatchButtonStyle: ViewModifier {
    func body(content: Content) -> some View { content.buttonStyle(StudioTintedButtonStyle()) }
}

/// A tinted capsule: accent text on a faint accent fill, sinking a little when pressed.
struct StudioTintedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Tinted(configuration: configuration) }
    private struct Tinted: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            let accent = Studio.accent
            configuration.label.foregroundStyle(accent)
                .background(accent.opacity(0.18), in: Capsule())
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? Motion.pressScale(0.97) : 1)
                .animation(reduceMotion ? nil : Motion.pressMotion(pressed: configuration.isPressed), value: configuration.isPressed)
        }
    }
}

/// The list | grid switch with "Grey" chosen: one grey capsule, the chosen side lighter (never the
/// accent), with the light thumb sliding across.
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
            // A light tap as the thumb moves (the round toggle it replaced had one).
            .haptic(.selection, trigger: grid)
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

/// The episode track: capsules for the season, the watched ones filled and the next one outlined.
/// Marking an episode fills its capsule and the outline glides to the next. Every season gets the
/// same look (owner: a bar on some heroes and capsules on others looked broken): up to 16 episodes
/// a capsule each; a longer season shares them out, a few episodes to a capsule, and the capsule
/// you're part-way through fills part-way.
struct StudioEpisodeTrack: View {
    let watched: Int
    let total: Int
    var showsNext = true
    /// The fill; the theme's accent when not given.
    var tint: Color? = nil
    var track: Color = .white.opacity(0.22)
    @Namespace private var outline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Any season whose episode count is known (an unknown count keeps the bar).
    static func fits(_ total: Int) -> Bool { total >= 1 }
    /// Episodes per capsule: one, or as many as keep the track to 16 capsules.
    static func perCapsule(_ total: Int) -> Int { max(1, Int((Double(max(total, 1)) / 16).rounded(.up))) }
    /// How much of capsule `index` is watched, 0…1.
    static func fill(_ index: Int, watched: Int, total: Int) -> Double {
        let per = perCapsule(total), start = index * per, size = min(per, max(total - start, 1))
        return min(1, max(0, Double(watched - start) / Double(size)))
    }
    var body: some View {
        let fill = tint ?? Studio.accent
        let per = Self.perCapsule(total)
        let count = max(1, Int((Double(max(total, 1)) / Double(per)).rounded(.up)))
        let next = min(watched / per, count - 1)
        HStack(spacing: count > 12 ? 2 : 3) {
            ForEach(0..<count, id: \.self) { index in
                Capsule().fill(track)
                    .overlay(alignment: .leading) {
                        Capsule().fill(fill).scaleEffect(x: max(0.001, Self.fill(index, watched: watched, total: total)), anchor: .leading)
                    }
                    .overlay {
                        if showsNext && watched < total && index == next {
                            Capsule().strokeBorder(fill, lineWidth: 1).matchedGeometryEffect(id: "next", in: outline)
                        }
                    }
            }
        }.frame(height: 6)
            .animation(reduceMotion ? nil : .snappy(duration: 0.32), value: watched)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(watched) of \(total) episodes watched")
    }
}

/// Orderings for a person's credits. The shared ranking (`PersonSections`) matches the web app and
/// its golden tests, so these run on top of it, only when chosen in Design Lab.
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

// MARK: - Settings pages

/// Settings → Design Lab: the starting point, the areas, and the whole app's feel.
struct DesignLabView: View {
    @State private var lab = StudioLab.shared
    @AppStorage(Haptics.key) private var haptics = true
    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 20) {
                SettingsIntro(eyebrow: "Design Lab", text: "Choose how each part of the app looks. Works with every theme.")
                VStack(alignment: .leading, spacing: 8) {
                    DesignLabHeading(text: "Starting point")
                    NativeSegmentedControl(segments: StudioLab.Preset.allCases.map { NativeSegment(value: $0, title: $0.title, id: "design-lab-preset-" + $0.rawValue) },
                                           selection: Binding(get: { lab.preset }, set: { lab.apply($0) }))
                    SettingsFootnote(text: lab.preset == .custom ? "Your own mix. Original shows the app as it was; Custom brings your mix back."
                                     : lab.hasSavedMix ? "Every choice as it was. Custom brings your mix back."
                                     : "Every choice as it was. Change any choice below to make your own mix.")
                }
                SettingsGroup(label: "Redrawn") {
                    ForEach(Array(StudioChange.Area.pages.enumerated()), id: \.element) { index, area in
                        if index > 0 { SettingsDivider() }
                        NavigationLink { DesignLabAreaView(area: area) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: area.symbol).font(.app(size: 15, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 30, height: 30).background(area.tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Text(area.rawValue).font(.app(size: 17)).foregroundStyle(HomeStyle.primary)
                                Spacer(minLength: 8)
                                let count = lab.count(area)
                                Text("\(count.on) of \(count.of)").font(.app(size: 15)).foregroundStyle(HomeStyle.secondary).monospacedDigit()
                                Image(systemName: "chevron.right").font(.app(size: 14, weight: .semibold)).foregroundStyle(Color(uiColor: .tertiaryLabel))
                            }.settingsRowFrame().contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("design-lab-area-" + area.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))
                    }
                }
                SettingsGroup(label: "Feel") {
                    DesignLabChoice(title: "Rating badge", note: "As is: each place keeps its corner. Top or Bottom: every poster the same. Off: none.",
                                    segments: DesignBadge.allCases.map { NativeSegment(value: $0, title: $0.title, id: "design-lab-badge-" + $0.rawValue) },
                                    selection: Binding(get: { lab.badge }, set: { lab.setBadge($0) }))
                    SettingsDivider()
                    DesignLabChoice(title: "Corners", note: "Posters, and cards in Native.",
                                    segments: DesignCorners.allCases.map { NativeSegment(value: $0, title: $0.title, id: "design-lab-corners-" + $0.rawValue) },
                                    selection: Binding(get: { lab.corners }, set: { lab.setCorners($0) }))
                    SettingsDivider()
                    // Haptics (moved here from the Theme page): the little taps when you mark, add,
                    // switch tabs and trace the rating chart. Turning them on answers with one.
                    Toggle(isOn: $haptics) { SettingsRowTitle("Haptics", "").frame(maxWidth: .infinity, alignment: .leading) }
                        .tint(Color(uiColor: .systemGreen)).settingsRowFrame().accessibilityIdentifier("settings-haptics")
                        .onChange(of: haptics) { _, on in if on { Haptics.play(.success) } }
                }
                SettingsFootnote(text: "Changes instantly · saved on this iPhone")
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 32)
        }.diaryScreenBackground().diaryPageNavigation("Design Lab")
    }
}

/// One area's page: its pieces under their headings, each a choice between as-it-was and the redraw.
struct DesignLabAreaView: View {
    let area: StudioChange.Area
    @State private var lab = StudioLab.shared
    private struct LabSection: Identifiable {
        let name: String
        var changes: [StudioChange]
        var id: String { name }
    }
    private var sections: [LabSection] {
        var result: [LabSection] = []
        for change in StudioChange.allCases where change.area == area {
            if let index = result.firstIndex(where: { $0.name == change.section }) { result[index].changes.append(change) }
            else { result.append(LabSection(name: change.section, changes: [change])) }
        }
        return result
    }
    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(sections) { section in
                    SettingsGroup(label: section.name) {
                        ForEach(Array(section.changes.enumerated()), id: \.element) { index, change in
                            if index > 0 { SettingsDivider() }
                            DesignLabToggleChoice(change: change, lab: lab)
                        }
                    }
                }
                // Recommended's match has three choices of its own.
                if area == .home {
                    SettingsGroup(label: "Recommended") {
                        DesignLabChoice(title: "Match", note: nil,
                                        segments: DesignMatch.allCases.map { NativeSegment(value: $0, title: $0.title, id: "design-lab-match-" + $0.rawValue) },
                                        selection: Binding(get: { lab.match }, set: { lab.setMatch($0) }))
                    }
                }
                SettingsFootnote(text: "Each choice changes that part of the app right away.")
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 32)
        }.diaryScreenBackground().diaryPageNavigation(area.rawValue)
    }
}

/// A heading above a lone control, in the grouped list's style.
private struct DesignLabHeading: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.app(size: 13)).foregroundStyle(HomeStyle.secondary).padding(.leading, 16)
    }
}

/// A titled choice inside a group: the name, the segmented control and an optional line under it.
private struct DesignLabChoice<Value: Hashable>: View {
    let title: String
    let note: String?
    let segments: [NativeSegment<Value>]
    @Binding var selection: Value
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.app(size: 16)).foregroundStyle(HomeStyle.primary)
            NativeSegmentedControl(segments: segments, selection: $selection)
            if let note { Text(note).font(.app(size: 12)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// A redrawn piece as a two-way choice: as it was, or the redraw.
private struct DesignLabToggleChoice: View {
    let change: StudioChange
    let lab: StudioLab
    var body: some View {
        DesignLabChoice(title: change.title, note: change.note,
                        segments: [NativeSegment(value: false, title: change.choices.off, id: "design-lab-\(change.rawValue)-off"),
                                   NativeSegment(value: true, title: change.choices.on, id: "design-lab-\(change.rawValue)-on")],
                        selection: Binding(get: { lab.isOn(change) }, set: { lab.set(change, on: $0) }))
    }
}
