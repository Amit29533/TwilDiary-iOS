import SwiftUI
import UIKit

struct CustomiseRoute: Hashable {}

/// Settings → Customise: Home's sections and Explore's rows in your order (hide any you don't
/// use), the tab bar's order and where the app opens, and how posters look.
struct CustomiseView: View {
    @AppStorage(HomeSection.key) private var homeText = ""
    @AppStorage(HomeSection.continueKey) private var showContinue = true
    @AppStorage(ExploreRow.key) private var exploreText = ""
    @AppStorage(TabLayout.key) private var tabText = ""
    @AppStorage(AppTab.launchKey) private var launchTab = AppTab.glance
    @State private var confirmReset = false
    /// The title bar's feathered backdrop, as on every other settings page (EdgeToEdgeScroll):
    /// without it the rows scrolled under "Customise" and the back button.
    @State private var header = CompactHeaderState()

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
            } header: { sectionHeader("Home") }.listRowBackground(rowBackground)

            Section {
                ForEach(explore.order, id: \.self) { id in
                    if let item = ExploreRow(rawValue: id) {
                        row(item.title, symbol: item.symbol, hidden: explore.hidden.contains(id), hideable: true,
                            identifier: "customise-explore-" + id) { exploreText = Self.toggled(explore, id).text }
                    }
                }
                .onMove { from, to in var next = explore; next.order.move(fromOffsets: from, toOffset: to); exploreText = next.text }
            } header: { sectionHeader("Explore") }.listRowBackground(rowBackground)

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
            } header: { sectionHeader("Tab bar") }.listRowBackground(rowBackground)

            // Posters have their own page now (Settings → Posters).
            Section {
                Button("Back to the original layout", role: .destructive) { confirmReset = true }
                    .accessibilityIdentifier("customise-reset")
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
        .diaryScreenBackground().diaryPageNavigation("Layout")
        .confirmationDialog("Back to the original layout?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Home, Explore and tabs", role: .destructive) {
                homeText = ""; exploreText = ""; tabText = ""; showContinue = true
                Haptics.play(.success)
            }
        }
    }

    /// The settings cards' colour (the theme's card; Native's grouped surface).
    private var rowBackground: Color { ThemeStore.current.native ? Color(uiColor: .secondarySystemBackground) : HomeStyle.card }
    /// The settings pages' group label (SettingsGroup): uppercase, 13 pt, secondary.
    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased()).font(.app(size: 13, weight: ThemeStore.current.native ? .regular : .bold))
            .foregroundStyle(HomeStyle.secondary).textCase(nil).accessibilityAddTraits(.isHeader)
    }
    private func label(_ title: String, symbol: String, hidden: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.app(size: 15, weight: .semibold)).foregroundStyle(hidden ? .secondary : .primary).frame(width: 24)
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
                    Image(systemName: hidden ? "eye.slash" : "eye").font(.app(size: 16, weight: .semibold))
                        .foregroundStyle(hidden ? Color.secondary : Color.accentColor).frame(width: 36, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(hidden ? "Show " + title : "Hide " + title).accessibilityIdentifier(identifier)
            } else {
                Image(systemName: "lock").font(.app(size: 13)).foregroundStyle(.tertiary).accessibilityLabel("Always shown")
            }
        }
    }
    private static func toggled(_ layout: SectionOrder, _ id: String) -> SectionOrder {
        var next = layout
        if next.hidden.contains(id) { next.hidden.remove(id) } else { next.hidden.insert(id) }
        return next
    }
}

/// Settings → Posters (split out of Layout): how posters look across the app. Each kind of poster
/// has its own slider with a live preview (owner's drawing, 25 Nov 2026): shelf cards, list rows and
/// small rows, then how many go across a grid (`PosterSizes`). Reset puts all four back.
struct PosterSettingsView: View {
    @AppStorage(PosterSizes.shelfKey) private var shelf = PosterSizes.shelfDefault
    @AppStorage(PosterSizes.rowKey) private var row = PosterSizes.rowDefault
    @AppStorage(PosterSizes.smallKey) private var small = PosterSizes.smallDefault
    @AppStorage(PosterSizes.gridKey) private var grid = PosterSizes.gridDefault
    @AppStorage(PosterSize.ratingKey) private var showsRating = true
    @AppStorage(PosterSize.captionKey) private var showsCaption = true
    init() { PosterSizes.migrate() }

    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 20) {
                SettingsIntro(eyebrow: "Posters", text: "How big each kind of poster is, and what shows on them.")
                sizeGroup("Shelf cards", "Sideways rows: Home, title pages, Explore", value: $shelf, range: PosterSizes.shelfRange, step: 5,
                          id: "customise-poster-shelf") {
                    HStack(spacing: 8) {
                        ForEach(0..<4, id: \.self) { _ in sample(width: shelf) }
                    }.frame(maxWidth: .infinity, alignment: .leading).frame(height: PosterSizes.height(PosterSizes.shelfRange.upperBound), alignment: .topLeading).clipped()
                }
                sizeGroup("List rows", "Library list, Search results, calendar", value: $row, range: PosterSizes.rowRange, step: 1,
                          id: "customise-poster-row") {
                    HStack(spacing: 12) {
                        sample(width: row)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Frieren: Beyond Journey's End").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            Text("Anime · Series").font(.app(size: 13)).foregroundStyle(HomeStyle.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                sizeGroup("Small rows", "Stats, a person's credits, Your Lists", value: $small, range: PosterSizes.smallRange, step: 1,
                          id: "customise-poster-small") {
                    HStack(spacing: 12) {
                        sample(width: small)
                        Text("Arcane").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        Spacer(minLength: 0)
                        Text("9 episodes").font(.app(size: 12)).foregroundStyle(HomeStyle.secondary)
                    }
                }
                SettingsGroup(label: "Grids") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Posters across: Library, Explore, Search").font(.app(size: 14)).foregroundStyle(HomeStyle.primary)
                            Spacer(minLength: 8)
                            Text("\(grid)").font(.app(size: 13)).foregroundStyle(HomeStyle.secondary).monospacedDigit()
                        }
                        Picker("Posters across", selection: $grid) {
                            ForEach(Array(PosterSizes.gridRange), id: \.self) { Text("\($0)").tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("customise-poster-grid")
                        HStack(spacing: 8) {
                            ForEach(0..<grid, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 8).fill(Self.fill).aspectRatio(2.0 / 3.0, contentMode: .fit)
                            }
                        }.animation(.smooth, value: grid).accessibilityHidden(true)
                    }.padding(14)
                }
                SettingsGroup(label: "On each poster") {
                    Toggle(isOn: $showsRating) { SettingsRowTitle("Rating", "The community score on the poster") }
                        .settingsRowFrame().accessibilityIdentifier("customise-poster-rating")
                    SettingsDivider()
                    Toggle(isOn: $showsCaption) { SettingsRowTitle("Name under posters", "The title and a line of details") }
                        .settingsRowFrame().accessibilityIdentifier("customise-poster-caption")
                }
                SettingsFootnote(text: "A title page's big poster, wide episode pictures, people's photos and Cines keep their own sizes. Where the rating sits, corners and caption spacing are in Design Lab.")
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 32)
        }
        .diaryScreenBackground().diaryPageNavigation("Posters")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reset") {
                    withAnimation(.smooth) {
                        shelf = PosterSizes.shelfDefault; row = PosterSizes.rowDefault
                        small = PosterSizes.smallDefault; grid = PosterSizes.gridDefault
                    }
                }
                .disabled(shelf == PosterSizes.shelfDefault && row == PosterSizes.rowDefault && small == PosterSizes.smallDefault && grid == PosterSizes.gridDefault)
                .accessibilityIdentifier("customise-poster-reset")
            }
        }
    }

    private static let fill = LinearGradient(colors: [Color(themed: "#5b4a8a"), Color(themed: "#2a2440")], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// A poster-shaped sample at a width.
    private func sample(width: Double) -> some View {
        RoundedRectangle(cornerRadius: width > 80 ? 10 : 7).fill(Self.fill)
            .frame(width: CGFloat(width), height: PosterSizes.height(CGFloat(width)))
            .accessibilityHidden(true)
    }

    /// One kind of poster: its name and where it shows, its width, Smaller to Bigger, and a preview.
    private func sizeGroup<Preview: View>(_ label: String, _ places: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                                          id: String, @ViewBuilder preview: () -> Preview) -> some View {
        SettingsGroup(label: label) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(places).font(.app(size: 14)).foregroundStyle(HomeStyle.primary).lineLimit(2)
                    Spacer(minLength: 8)
                    Text("\(Int(value.wrappedValue)) pt").font(.app(size: 13)).foregroundStyle(HomeStyle.secondary).monospacedDigit()
                }
                Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value.wrappedValue)) }, set: { value.wrappedValue = $0 }),
                       in: range, step: step) {
                    Text(label + " size")
                } minimumValueLabel: {
                    Text("Smaller").font(.app(size: 11)).foregroundStyle(HomeStyle.secondary)
                } maximumValueLabel: {
                    Text("Bigger").font(.app(size: 11)).foregroundStyle(HomeStyle.secondary)
                }
                .accessibilityValue("\(Int(value.wrappedValue)) points wide")
                .accessibilityIdentifier(id)
                Divider().opacity(0.5)
                preview()
            }.padding(14)
        }
    }
}
