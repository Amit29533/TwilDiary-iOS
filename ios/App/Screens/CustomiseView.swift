import SwiftUI

struct CustomiseRoute: Hashable {}

/// Settings → Customise: Home's sections and Explore's rows in your order (hide any you don't
/// use), the tab bar's order and where the app opens, and how posters look.
struct CustomiseView: View {
    @AppStorage(HomeSection.key) private var homeText = ""
    @AppStorage(HomeSection.continueKey) private var showContinue = true
    @AppStorage(ExploreRow.key) private var exploreText = ""
    @AppStorage(TabLayout.key) private var tabText = ""
    @AppStorage(AppTab.launchKey) private var launchTab = AppTab.glance
    @AppStorage(PosterSize.key) private var posterSize = PosterSize.regular
    @AppStorage(PosterSize.ratingKey) private var showsRating = true
    @AppStorage(PosterSize.captionKey) private var showsCaption = true
    @State private var confirmReset = false

    var body: some View {
        let home = HomeSection.layout(homeText), explore = ExploreRow.layout(exploreText), tabs = TabLayout.layout(tabText)
        List {
            Section {
                Toggle(isOn: $showContinue) { label("Continue watching at the top", symbol: "play.rectangle", hidden: !showContinue) }
                    .accessibilityIdentifier("customise-home-continue")
                ForEach(home.order, id: \.self) { id in
                    if let section = HomeSection(rawValue: id) {
                        row(section.title, symbol: section.symbol, hidden: home.hidden.contains(id), hideable: section.hideable,
                            identifier: "customise-home-" + id) { homeText = Self.toggled(home, id).text }
                    }
                }
                .onMove { from, to in var next = home; next.order.move(fromOffsets: from, toOffset: to); homeText = next.text }
            } header: { Text("Home") } footer: { Text("Drag to reorder; tap the eye to hide or show. Explore & Canvas can move but not go: it's the way into them.") }

            Section {
                ForEach(explore.order, id: \.self) { id in
                    if let item = ExploreRow(rawValue: id) {
                        row(item.title, symbol: item.symbol, hidden: explore.hidden.contains(id), hideable: true,
                            identifier: "customise-explore-" + id) { exploreText = Self.toggled(explore, id).text }
                    }
                }
                .onMove { from, to in var next = explore; next.order.move(fromOffsets: from, toOffset: to); exploreText = next.text }
            } header: { Text("Explore") } footer: { Text("The rows of Explore, top to bottom.") }

            Section {
                Picker(selection: $launchTab) {
                    ForEach(tabs.visible.compactMap(AppTab.init(rawValue:)), id: \.self) { Text($0.label).tag($0) }
                } label: { label("Opens on", symbol: "arrow.forward.app", hidden: false) }
                    .accessibilityIdentifier("customise-launch-tab")
                ForEach(tabs.order, id: \.self) { id in
                    if let tab = AppTab(rawValue: id) {
                        row(tab.label, symbol: tab.systemIcon, hidden: tabs.hidden.contains(id), hideable: TabLayout.hideable(tab),
                            identifier: "customise-tab-" + id) {
                            tabText = Self.toggled(tabs, id).text
                            // The app can't open on a tab that's hidden.
                            if TabLayout.layout(tabText).hidden.contains(launchTab.rawValue) { launchTab = .home }
                        }
                    }
                }
                .onMove { from, to in var next = tabs; next.order.move(fromOffsets: from, toOffset: to); tabText = next.text }
            } header: { Text("Tab bar") } footer: { Text("Drag to reorder the tabs. Glance can be hidden; Home, Library, Search and Profile stay, since other pages open them.") }

            Section {
                Picker("Poster size", selection: $posterSize) {
                    ForEach(PosterSize.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("customise-poster-size")
                Toggle(isOn: $showsRating) { label("Rating on posters", symbol: "star", hidden: !showsRating) }
                    .accessibilityIdentifier("customise-poster-rating")
                Toggle(isOn: $showsCaption) { label("Name under posters", symbol: "textformat", hidden: !showsCaption) }
                    .accessibilityIdentifier("customise-poster-caption")
            } header: { Text("Posters") } footer: {
                Text("\(posterSize.title): \(posterSize.columns) posters across grids and rows.")
            }

            Section {
                Button("Back to the original layout", role: .destructive) { confirmReset = true }
                    .accessibilityIdentifier("customise-reset")
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .diaryScreenBackground().diaryPageNavigation("Customise")
        .confirmationDialog("Back to the original layout?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Home, Explore, tabs and posters", role: .destructive) {
                homeText = ""; exploreText = ""; tabText = ""; showContinue = true
                posterSize = .regular; showsRating = true; showsCaption = true
                Haptics.play(.success)
            }
        }
    }

    private func label(_ title: String, symbol: String, hidden: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(hidden ? .secondary : .primary).frame(width: 24)
            Text(title).foregroundStyle(hidden ? .secondary : .primary)
        }
    }
    /// One section: its name, and the eye that hides or shows it (none where it has to stay).
    private func row(_ title: String, symbol: String, hidden: Bool, hideable: Bool, identifier: String, toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            label(title, symbol: symbol, hidden: hidden)
            Spacer(minLength: 8)
            if hideable {
                Button { toggle(); Haptics.play(.selection) } label: {
                    Image(systemName: hidden ? "eye.slash" : "eye").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(hidden ? Color.secondary : Color.accentColor).frame(width: 36, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(hidden ? "Show " + title : "Hide " + title).accessibilityIdentifier(identifier)
            } else {
                Image(systemName: "lock").font(.system(size: 13)).foregroundStyle(.tertiary).accessibilityLabel("Always shown")
            }
        }
    }
    private static func toggled(_ layout: SectionOrder, _ id: String) -> SectionOrder {
        var next = layout
        if next.hidden.contains(id) { next.hidden.remove(id) } else { next.hidden.insert(id) }
        return next
    }
}
