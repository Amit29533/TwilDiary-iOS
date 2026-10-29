import SwiftUI
import TwilDiaryCore

struct HistoryView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("historyGrid") private var grid = false
    @State private var filters: HistoryQuery
    @State private var showRange: Bool
    @State private var limit = 12
    @State private var showSearch = false
    @State private var dateSelection: HistoryDateSelection?
    init(initialDay: Date? = nil, initialUnknown: Bool = false) {
        let day = initialDay.map { DiaryDate.day($0) } ?? ""
        _filters = State(initialValue: HistoryQuery(from: initialUnknown ? "" : day, to: initialUnknown ? "" : day, unknownOnly: initialUnknown))
        _showRange = State(initialValue: initialDay != nil || initialUnknown)
    }
    var body: some View {
        let entries = store.historyEntries(filters)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                    HStack(spacing: 10) {
                        Text("Your watch history").font(.system(size: 19, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(entries.count) \(entries.count == 1 ? "watch" : "watches")").font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4).background(theme.accent.opacity(0.1), in: Capsule()).accessibilityIdentifier("history-count")
                        CollectionLayoutToggle(grid: $grid, collection: "history")
                        Button { showRange.toggle() } label: { DiaryIcon(name: "sliders-horizontal", size: 18).frame(width: 44, height: 44) }
                            .buttonStyle(.plain).foregroundStyle(showRange || filters.filtered ? theme.accent : .secondary)
                            .accessibilityLabel("Date filters").accessibilityAddTraits(showRange ? .isSelected : [])
                    }
                    SearchField(placeholder: "Filter watch history…", text: $filters.query, label: "Filter watch history")
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(HistoryPreset.allCases) { preset in
                                Button { filters.select(preset, now: store.now) } label: {
                                    HStack(spacing: 5) {
                                        if filters.selects(preset, now: store.now) { DiaryIcon(name: "check", size: 13) }
                                        Text(preset.label)
                                    }.font(.system(size: 13, weight: .semibold)).padding(.horizontal, 13).frame(minHeight: 38)
                                        .foregroundStyle(filters.selects(preset, now: store.now) ? theme.ink : Color.primary)
                                        .background(filters.selects(preset, now: store.now) ? theme.accent : theme.accent.opacity(0.08), in: Capsule())
                                        .overlay(Capsule().strokeBorder(theme.accent.opacity(filters.selects(preset, now: store.now) ? 1 : 0.2)))
                                }.buttonStyle(.plain).accessibilityAddTraits(filters.selects(preset, now: store.now) ? .isSelected : [])
                            }
                        }
                    }.scrollIndicators(.hidden)
                    if showRange {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) { dateField(.from); dateField(.to) }.disabled(filters.unknownOnly)
                            Toggle("Unknown dates only", isOn: $filters.unknownOnly).font(.system(size: 13)).onChange(of: filters.unknownOnly) { _, selected in if selected { filters.from = ""; filters.to = "" } }
                        }.diaryPanel(padding: 12, radius: 14)
                    }
                    if filters.invalidRange { Text("The start date must come before the end date.").font(.system(size: 13)).foregroundStyle(.red) }
                    if filters.filtered {
                        HStack { Text("Showing \(entries.count) of " + store.activeEventCount.counted("watch", "watches")).font(.system(size: 13)).foregroundStyle(.secondary); Spacer(minLength: 0); Button("Clear filters") { filters = HistoryQuery() }.font(.system(size: 13, weight: .semibold)) }
                    }
                    if entries.isEmpty {
                        DiaryEmptyState(title: "No watches found", description: "Try another title or date range. Unknown dates are excluded from date ranges.")
                    } else {
                        CollectionLayout(grid: grid, spacing: 8) {
                            ForEach(entries.prefix(limit)) { entry in
                                NavigationLink(value: entry.title.id) { HistoryRow(entry: entry, grid: grid) }.buttonStyle(.plain).accessibilityIdentifier("history-event-" + entry.id)
                            }
                        }
                    }
                    if limit < entries.count {
                        Button { limit += 12 } label: { Text("Show more watches (\(entries.count - limit))").font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: 44) }.buttonStyle(.glass).accessibilityIdentifier("history-load-more")
                    }
                    HStack(alignment: .top, spacing: 6) { DiaryIcon(name: "clock-3", size: 13); Text("Unknown dates stay unknown. Dates are never guessed.").font(.system(size: 12)) }.foregroundStyle(.secondary)
                }.padding(14).padding(.bottom, 100)
            }.refreshable { await store.refresh() }
        }.diaryScreenBackground().diaryPageNavigation("Recently watched", searchIdentifier: "search-history") { showSearch.toggle() }
            .onChange(of: filters) { _, _ in limit = 12 }
            .sheet(item: $dateSelection) { selection in
                HistoryCalendarSheet(selection: selection) { day in
                    if selection.field == .from { filters.from = day } else { filters.to = day }
                }
            }
    }
    private func dateField(_ field: HistoryDateSelection.Field) -> some View {
        let day = field == .from ? filters.from : filters.to
        return VStack(alignment: .leading, spacing: 6) {
            Text(field.label).font(.system(size: 12)).foregroundStyle(.secondary)
            Button { dateSelection = HistoryDateSelection(field: field, initial: HistoryQuery.localDay(day) ?? store.now) } label: {
                HStack(spacing: 6) { Text(day.isEmpty ? "Choose date" : day).font(.system(size: 13)).lineLimit(1); Spacer(minLength: 0); DiaryIcon(name: "calendar-days", size: 16) }.frame(minHeight: 44).padding(.horizontal, 10)
            }.buttonStyle(.plain).background { DiaryControlSurface(shape: RoundedRectangle(cornerRadius: 10), field: true) }.accessibilityLabel(field.label).accessibilityValue(day.isEmpty ? "Any date" : day)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HistoryDateSelection: Identifiable {
    enum Field: String { case from, to; var label: String { rawValue.capitalized } }
    var id: Field { field }
    let field: Field
    let initial: Date
}
private struct HistoryCalendarSheet: View {
    let selection: HistoryDateSelection
    let onSet: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    init(selection: HistoryDateSelection, onSet: @escaping (String) -> Void) {
        self.selection = selection; self.onSet = onSet; _date = State(initialValue: selection.initial)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    DatePicker(selection.field.label, selection: $date, displayedComponents: .date).datePickerStyle(.graphical)
                    Button("Clear date") { onSet(""); dismiss() }.frame(minHeight: 44)
                }.padding(16)
            }.navigationTitle(selection.field.label).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Set date") { onSet(DiaryDate.day(date)); dismiss() } }
                }
        }.presentationDetents([.medium, .large])
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    var grid = false
    private var layout: AnyLayout { grid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 10)) }
    var body: some View {
        layout {
            Artwork(path: entry.title.poster, title: entry.title.name, initialsOnly: false).frame(width: grid ? nil : 60, height: grid ? 170 : 90).frame(maxWidth: grid ? .infinity : nil).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.title.name).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true).shadow(color: .black.opacity(0.53), radius: 4, y: 1)
                InlineFlowLayout {
                    Text(entry.episode.map { "S\($0.season) E\($0.number)" } ?? "Movie").foregroundStyle(Color(webHex: "#c5c0cf"))
                    if entry.rewatched { HStack(spacing: 4) { DiaryIcon(name: "rotate-ccw", size: 12); Text("Rewatched") }.foregroundStyle(.tint) }
                }.font(.system(size: 13)).padding(.vertical, 3)
                Spacer(minLength: 0)
                Text(DiaryDate.parse(entry.event.watchedAt).map { $0.formatted(.dateTime.month(.abbreviated).day().year()) } ?? "Watch date unknown").font(.system(size: 12)).foregroundStyle(Color(webHex: "#a09aa9")).padding(.top, 10)
            }.frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading).padding(.vertical, 3)
            if !grid { DiaryIcon(name: "chevron-right", size: 17).foregroundStyle(Color(webHex: "#a09aa9")) }
        }.padding(7).foregroundStyle(Color(webHex: "#f3f0f7"))
            .background {
                ZStack {
                    Color(webHex: "#111115")
                    if let path = backdrop { Artwork(path: path).opacity(0.7) }
                    LinearGradient(stops: [.init(color: Color(webHex: "#0b0c10f2"), location: 0), .init(color: Color(webHex: "#0b0c10e6"), location: 0.38), .init(color: Color(webHex: "#0b0c10b3"), location: 1)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [Color(webHex: "#05060980"), .clear], startPoint: .bottom, endPoint: .top)
                }.allowsHitTesting(false)
            }.clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.13)))
            .contentShape(Rectangle())
    }
    private var backdrop: String? { ["again", "night", "severance"].contains(entry.title.id) ? "scene:" + entry.title.id : entry.title.backdrop }
}
