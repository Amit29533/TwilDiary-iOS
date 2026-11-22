import SwiftUI

/// Settings → JellySpace → Home: the rows on JellySpace's home in your order (dragged by their
/// handles), the rows you took off (added back with +), each library's Recently added and Random
/// rows as one row each with the libraries ticked on a page of their own, Dynamic recommendations,
/// My Media's libraries in order with their recommendation switch, and the posters.
///
/// A native list (only the rows on screen are drawn), and the changes kept here until you leave:
/// the old page drew forty rows at once, rebuilt all of them on every tap, and wrote each change
/// at once, which redrew JellySpace's home behind it each time.
struct JellyHomeSettingsPage: View {
    let libraries: [JellyfinLibrary]
    @State private var model = JellyHomeSettingsModel()
    @State private var picking: JellyHomeSettingsModel.Group?
    @State private var header = CompactHeaderState()
    @AppStorage(JellyPrefs.themeCountKey) private var themeCount = 3
    @AppStorage(JellyPrefs.countsKey) private var counts = true
    @AppStorage(JellyPrefs.ticksKey) private var ticks = true
    @AppStorage(JellyPrefs.captionsKey) private var captions = true
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section {
                ForEach(model.shown) { row in
                    shownRow(row).moveDisabled(row.fixedAtTop)
                }
                .onMove { from, to in model.move(from, to) }
            } header: { sectionHeader("Rows on the home · drag to reorder") }.listRowBackground(rowBackground)

            if !model.hidden.isEmpty {
                Section {
                    ForEach(model.hidden) { row in hiddenRow(row) }
                } header: { sectionHeader("Hidden rows") }.listRowBackground(rowBackground)
            }

            Section {
                Picker("Rows on the home", selection: $themeCount) {
                    ForEach(1...5, id: \.self) { Text($0 == 1 ? "1 row" : "\($0) rows").tag($0) }
                }.pickerStyle(.menu).tint(HomeStyle.secondary)
            } header: { sectionHeader("Dynamic recommendations") } footer: {
                footer("Rows from words and tags your titles share: Recommendations for, Random picks for, Must watch. They change every day.")
            }.listRowBackground(rowBackground)

            if !model.libraries.isEmpty {
                Section {
                    ForEach(model.libraries) { library in mediaRow(library) }
                        .onMove { from, to in model.moveLibrary(from, to) }
                } header: { sectionHeader("My Media · drag to reorder") } footer: {
                    footer("The switch beside each: off keeps a library out of recommendations (More like this, Dynamic recommendations, the top poster, For you, Top 10, Hidden gems, the random rows). It stays in My Media and you can still browse it.")
                }.listRowBackground(rowBackground)
            }

            Section {
                Toggle("Unwatched counts", isOn: $counts).tint(theme.accent)
                Toggle("Watched ticks", isOn: $ticks).tint(theme.accent)
                Toggle("Titles", isOn: $captions).tint(theme.accent)
            } header: { sectionHeader("Posters") } footer: {
                footer("Titles off: no names under posters, and the rows close up as Netflix's do: bigger posters, close together, with small corners; Continue Watching shows just the picture.")
            }.listRowBackground(rowBackground)
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectHidden(true, for: .top)
        .onScrollGeometryChange(for: CGFloat.self, of: { value in
            (min(1, max(0, (value.contentOffset.y + value.contentInsets.top) / 48)) * 32).rounded() / 32
        }) { _, progress in header.update(progress) }
        .overlay(alignment: .top) {
            GeometryReader { geometry in
                FeatheredHeaderBackdrop(state: header, height: geometry.safeAreaInsets.top, always: false)
                    .offset(y: -geometry.safeAreaInsets.top)
            }.allowsHitTesting(false)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .diaryScreenBackground().diaryPageNavigation("Home")
        .navigationDestination(item: $picking) { group in JellyHomeLibraryPicker(model: model, group: group) }
        .onAppear { model.load(libraries) }
        // The libraries came in (or changed): what was changed so far is kept, then read again.
        .onChange(of: libraries.map(\.id)) { _, _ in model.save(); model.load(libraries) }
        .onDisappear { model.save() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.save() } }
    }

    // MARK: Rows

    private func shownRow(_ row: JellyHomeSettingsModel.Row) -> some View {
        HStack(spacing: 12) {
            Button { withAnimation { model.hide(row) } } label: {
                Image(systemName: "minus.circle.fill").font(.system(size: 21)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.red)
            }
            .buttonStyle(.plain).accessibilityLabel("Hide " + row.title).accessibilityIdentifier("jellyspace-home-hide-" + row.id)
            if let group = row.group {
                Button { picking = group } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).foregroundStyle(HomeStyle.primary)
                            Text(model.summary(group)).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text("\(model.ticked(group).count)").foregroundStyle(HomeStyle.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("jellyspace-home-row-" + row.id)
            } else {
                Text(row.title).foregroundStyle(HomeStyle.primary).accessibilityIdentifier("jellyspace-home-row-" + row.id)
                Spacer(minLength: 0)
            }
        }
    }

    private func hiddenRow(_ row: JellyHomeSettingsModel.Row) -> some View {
        Button { withAnimation { model.show(row) } } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill").font(.system(size: 21)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.green)
                Text(row.title).foregroundStyle(HomeStyle.primary)
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).moveDisabled(true)
        .accessibilityLabel("Show " + row.title).accessibilityIdentifier("jellyspace-home-show-" + row.id)
    }

    private func mediaRow(_ library: JellyfinLibrary) -> some View {
        let on = !model.recommendOff.contains(library.id)
        return HStack(spacing: 12) {
            Image(systemName: JellySpace.symbol(library.type)).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(HomeStyle.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(library.name).foregroundStyle(HomeStyle.primary).lineLimit(1)
                Text(on ? "In recommendations" : "Browse only").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { on }, set: { model.setRecommends(library.id, $0) }))
                .labelsHidden().tint(theme.accent)
                .accessibilityLabel("Recommend from \(library.name)")
                .accessibilityIdentifier("jellyspace-recommend-" + library.id)
        }
        .accessibilityIdentifier("jellyspace-media-order-" + library.id)
    }

    // MARK: Look (as Settings → Customise)

    private var rowBackground: Color { ThemeStore.current.native ? Color(uiColor: .secondarySystemBackground) : HomeStyle.card }
    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 13, weight: ThemeStore.current.native ? .regular : .bold))
            .foregroundStyle(HomeStyle.secondary).textCase(nil).accessibilityAddTraits(.isHeader)
    }
    private func footer(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary)
    }
}

/// Recently added or Random from: which libraries get a row, ticked.
private struct JellyHomeLibraryPicker: View {
    let model: JellyHomeSettingsModel
    let group: JellyHomeSettingsModel.Group
    @State private var header = CompactHeaderState()

    var body: some View {
        List {
            Section {
                ForEach(model.choices(group)) { library in
                    let on = model.ticked(group).contains(library.id)
                    Button { model.tick(group, library.id, !on) } label: {
                        HStack {
                            Text(library.name).foregroundStyle(HomeStyle.primary)
                            Spacer(minLength: 8)
                            if on { Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor) }
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("jellyspace-home-pick-" + library.id)
                }
            } header: {
                Text("ONE ROW FOR EACH LIBRARY TICKED").font(.system(size: 13, weight: ThemeStore.current.native ? .regular : .bold))
                    .foregroundStyle(HomeStyle.secondary).textCase(nil)
            } footer: {
                Text("The ticked rows sit together where \(group.title) is on the home, in My Media's order. None ticked takes it off the home.")
                    .font(.system(size: 13)).foregroundStyle(HomeStyle.secondary)
            }
            .listRowBackground(ThemeStore.current.native ? Color(uiColor: .secondarySystemBackground) : HomeStyle.card)
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectHidden(true, for: .top)
        .onScrollGeometryChange(for: CGFloat.self, of: { value in
            (min(1, max(0, (value.contentOffset.y + value.contentInsets.top) / 48)) * 32).rounded() / 32
        }) { _, progress in header.update(progress) }
        .overlay(alignment: .top) {
            GeometryReader { geometry in
                FeatheredHeaderBackdrop(state: header, height: geometry.safeAreaInsets.top, always: false)
                    .offset(y: -geometry.safeAreaInsets.top)
            }.allowsHitTesting(false)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .diaryScreenBackground().diaryPageNavigation(group.title)
    }
}

/// The Home page's rows while you change them. Read from the saved settings as the page opens and
/// written back (in the same form the home reads) as you leave it.
@MainActor @Observable final class JellyHomeSettingsModel {
    /// Recently added or Random from: one row on this page, a row per ticked library on the home.
    enum Group: String, Hashable, Identifiable {
        case latest, random
        var id: String { rawValue }
        var title: String { self == .latest ? "Recently added" : "Random from" }
        var prefix: String { rawValue + ":" }
        var oldToken: String { self == .latest ? JellyHomeRow.libraries.rawValue : JellyHomeRow.random.rawValue }
    }
    enum Row: Hashable, Identifiable {
        case fixed(JellyHomeRow), group(Group)
        var id: String {
            switch self {
            case .fixed(let row): row.rawValue
            case .group(let group): group.oldToken
            }
        }
        var title: String {
            switch self {
            case .fixed(let row): row.title
            case .group(let group): group.title
            }
        }
        var group: Group? { if case .group(let group) = self { group } else { nil } }
        /// The top poster and My Media stay at the top (they can be hidden, not moved).
        var fixedAtTop: Bool { if case .fixed(let row) = self { row.fixedAtTop } else { false } }
    }

    private(set) var shown: [Row] = []
    private(set) var hidden: [Row] = []
    /// My Media's libraries in order.
    private(set) var libraries: [JellyfinLibrary] = []
    private(set) var recommendOff: Set<String> = []
    private var latestOn: Set<String> = []
    private var randomOn: Set<String> = []
    /// What the saved settings hold that this page doesn't show (a hidden library's rows), kept as is.
    private var otherRows: [String] = []
    private var otherOff: [String] = []
    private var otherMedia: [String] = []
    private var changed = false

    func load(_ all: [JellyfinLibrary]) {
        let defaults = UserDefaults.standard
        let rowsRaw = defaults.string(forKey: JellyPrefs.rowsKey) ?? ""
        let hiddenRaw = defaults.string(forKey: JellyPrefs.hiddenRowsKey) ?? ""
        let mediaRaw = defaults.string(forKey: JellyPrefs.mediaOrderKey) ?? ""
        libraries = JellyMediaOrder.sorted(all, mediaRaw)
        recommendOff = JellyRecommendOff.ids(defaults.string(forKey: JellyRecommendOff.key) ?? "")
        let sections = JellyHomeRow.sections(rowsRaw, libraries: all)
        let off = JellyHomeRow.hiddenSections(hiddenRaw, libraries: all)
        latestOn = Set(all.map(\.id).filter { !off.contains(Group.latest.prefix + $0) })
        randomOn = Set(all.filter(JellyDiscover.holdsVideo).map(\.id).filter { !off.contains(Group.random.prefix + $0) })
        var order: [Row] = [.fixed(.hero), .fixed(.media)]
        for section in sections {
            let row: Row
            switch section.kind {
            case .fixed(let fixed): row = .fixed(fixed)
            case .latest: row = .group(.latest)
            case .random: row = .group(.random)
            }
            if !order.contains(row) { order.append(row) }
        }
        // A group with no library to show (Random with no film or show library) isn't offered.
        order.removeAll { row in row.group.map { choices($0).isEmpty } ?? false }
        shown = order.filter { isOn($0, off: off) }
        hidden = order.filter { !isOn($0, off: off) }
        let known = Set(sections.map(\.id) + [JellyHomeRow.hero.rawValue, JellyHomeRow.media.rawValue])
        otherRows = rowsRaw.split(separator: ",").map(String.init).filter { !known.contains($0) && !Self.groupTokens.contains($0) }
        otherOff = hiddenRaw.split(separator: ",").map(String.init).filter { !known.contains($0) && !Self.groupTokens.contains($0) }
        otherMedia = mediaRaw.split(separator: ",").map(String.init).filter { id in !all.contains { $0.id == id } }
        changed = false
    }
    private static let groupTokens: Set<String> = [JellyHomeRow.libraries.rawValue, JellyHomeRow.random.rawValue]

    private func isOn(_ row: Row, off: Set<String>) -> Bool {
        switch row {
        case .fixed(let fixed): !off.contains(fixed.rawValue)
        case .group(let group): !ticked(group).isEmpty
        }
    }

    // MARK: Reading

    /// The libraries a group can have rows for, in My Media's order.
    func choices(_ group: Group) -> [JellyfinLibrary] {
        group == .latest ? libraries : libraries.filter(JellyDiscover.holdsVideo)
    }
    func ticked(_ group: Group) -> [String] {
        let on = group == .latest ? latestOn : randomOn
        return choices(group).map(\.id).filter(on.contains)
    }
    /// "Movies, Shows +3".
    func summary(_ group: Group) -> String {
        let names = choices(group).filter { ticked(group).contains($0.id) }.map(\.name)
        guard !names.isEmpty else { return "None" }
        return names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " +\(names.count - 2)" : "")
    }

    // MARK: Changing

    func hide(_ row: Row) {
        guard let at = shown.firstIndex(of: row) else { return }
        shown.remove(at: at)
        hidden.append(row)
        changed = true
    }
    func show(_ row: Row) {
        guard let at = hidden.firstIndex(of: row) else { return }
        hidden.remove(at: at)
        // A group added back with nothing ticked gets every library.
        if let group = row.group, ticked(group).isEmpty { setAll(group, choices(group).map(\.id)) }
        switch row {
        case .fixed(.hero): shown.insert(row, at: 0)
        case .fixed(.media): shown.insert(row, at: shown.first == .fixed(.hero) ? 1 : 0)
        default: shown.append(row)
        }
        changed = true
    }
    func move(_ from: IndexSet, _ to: Int) {
        shown.move(fromOffsets: from, toOffset: to)
        // Nothing goes above the top poster and My Media.
        shown = shown.filter(\.fixedAtTop) + shown.filter { !$0.fixedAtTop }
        changed = true
    }
    func tick(_ group: Group, _ library: String, _ on: Bool) {
        var set = group == .latest ? latestOn : randomOn
        if on { set.insert(library) } else { set.remove(library) }
        setAll(group, Array(set))
        let row = Row.group(group)
        if ticked(group).isEmpty, let at = shown.firstIndex(of: row) { shown.remove(at: at); hidden.append(row) }
        if !ticked(group).isEmpty, let at = hidden.firstIndex(of: row) { hidden.remove(at: at); shown.append(row) }
        changed = true
    }
    private func setAll(_ group: Group, _ ids: [String]) {
        if group == .latest { latestOn = Set(ids) } else { randomOn = Set(ids) }
    }
    func moveLibrary(_ from: IndexSet, _ to: Int) {
        libraries.move(fromOffsets: from, toOffset: to)
        changed = true
    }
    func setRecommends(_ library: String, _ on: Bool) {
        if on { recommendOff.remove(library) } else { recommendOff.insert(library) }
        changed = true
    }

    // MARK: Saving

    /// Written in the form the home reads: every section's id in order (a group's ticked libraries
    /// first, in My Media's order), and the ids of those switched off.
    func save() {
        guard changed else { return }
        changed = false
        func ids(_ row: Row) -> [String] {
            switch row {
            case .fixed(let fixed): return [fixed.rawValue]
            case .group(let group):
                let on = ticked(group)
                return (on + choices(group).map(\.id).filter { !on.contains($0) }).map { group.prefix + $0 }
            }
        }
        let rows = (shown + hidden).filter { !$0.fixedAtTop }.flatMap(ids) + otherRows
        var off = otherOff
        for row in hidden { off += ids(row) }
        for row in shown {
            guard let group = row.group else { continue }
            let on = ticked(group)
            off += choices(group).map(\.id).filter { !on.contains($0) }.map { group.prefix + $0 }
        }
        let defaults = UserDefaults.standard
        defaults.set(rows.joined(separator: ","), forKey: JellyPrefs.rowsKey)
        defaults.set(Array(Set(off)).sorted().joined(separator: ","), forKey: JellyPrefs.hiddenRowsKey)
        defaults.set((libraries.map(\.id) + otherMedia).joined(separator: ","), forKey: JellyPrefs.mediaOrderKey)
        defaults.set(recommendOff.sorted().joined(separator: ","), forKey: JellyRecommendOff.key)
    }
}
