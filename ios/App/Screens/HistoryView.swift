import SwiftUI
import TwilDiaryCore

struct HistoryView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("historyGrid") private var grid = false
    @State private var filters: HistoryQuery
    @State private var showRange: Bool
    @State private var limit = 12
    @State private var dateSelection: HistoryDateSelection?
    init(initialDay: Date? = nil, initialUnknown: Bool = false, initialQuery: String = "") {
        let day = initialDay.map { DiaryDate.day($0) } ?? ""
        _filters = State(initialValue: HistoryQuery(query: initialQuery, from: initialUnknown ? "" : day, to: initialUnknown ? "" : day, unknownOnly: initialUnknown))
        _showRange = State(initialValue: initialDay != nil || initialUnknown)
    }
    var body: some View {
        let entries = store.historyEntries(filters)
        VStack(spacing: 0) {
            EdgeToEdgeScroll {
                // Design (board 12): the title with its count, the layout button, date chips, then
                // the watches grouped by day.
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your watch history").font(.system(size: 26, weight: .bold)).tracking(-0.4).foregroundStyle(HomeStyle.primary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Text("\(Text(entries.count.formatted()).foregroundStyle(HomeStyle.chipText).fontWeight(.bold)) \(entries.count == 1 ? "watch" : "watches")")
                                .font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).accessibilityIdentifier("history-count")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        CollectionLayoutToggle(grid: $grid, collection: "history")
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(HistoryPreset.allCases) { preset in
                                let on = !showRange && !filters.unknownOnly && filters.selects(preset, now: store.now)
                                chip(preset.label, on: on) { showRange = false; filters.select(preset, now: store.now) }
                            }
                            chip("Custom", on: showRange && !filters.unknownOnly) { showRange.toggle(); if showRange { filters.unknownOnly = false } }
                                .accessibilityLabel("Date filters")
                            chip("Unknown dates", on: filters.unknownOnly) {
                                filters.unknownOnly.toggle()
                                if filters.unknownOnly { filters.from = ""; filters.to = ""; showRange = false }
                            }
                        }.padding(.horizontal, 14)
                    }.scrollIndicators(.hidden).padding(.horizontal, -14)
                    if showRange {
                        HStack(spacing: 12) { dateField(.from); dateField(.to) }.padding(12).modifier(SettingsCard())
                    }
                    if filters.invalidRange { Text("The start date must come before the end date.").font(.system(size: 13)).foregroundStyle(.red) }
                    if filters.filtered {
                        HStack { Text("Showing \(entries.count) of " + store.activeEventCount.counted("watch", "watches")).font(.system(size: 13)).foregroundStyle(.secondary); Spacer(minLength: 0); Button("Clear filters") { filters = HistoryQuery() }.font(.system(size: 13, weight: .semibold)) }
                    }
                    if entries.isEmpty {
                        DiaryEmptyState(title: "No watches found", description: "Try another title or date range. Unknown dates are excluded from date ranges.")
                    } else if grid && !typeSize.isAccessibilitySize {
                        CollectionLayout(grid: true, spacing: 12) {
                            ForEach(entries.prefix(limit)) { entry in
                                NavigationLink(value: entry.title.id) { HistoryRow(entry: entry, grid: true) }.buttonStyle(.plain).accessibilityIdentifier("history-event-" + entry.id)
                            }
                        }
                    } else {
                        ForEach(HistoryDay.group(Array(entries.prefix(limit)))) { day in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(day.label).font(.system(size: 17, weight: .bold)).foregroundStyle(HomeStyle.primary)
                                    Spacer(minLength: 8)
                                    Text(day.entries.count.counted("watch", "watches")).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                                }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                                VStack(spacing: 0) {
                                    ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
                                        if index > 0 { SettingsDivider() }
                                        NavigationLink(value: entry.title.id) { HistoryDayRow(entry: entry) }.buttonStyle(.plain)
                                            .accessibilityIdentifier("history-event-" + entry.id)
                                    }
                                }.modifier(SettingsCard())
                            }
                        }
                    }
                    if limit < entries.count { ScrollLoadTrigger(token: limit, loading: false) { limit += 12 } }
                    HStack(alignment: .top, spacing: 6) { DiaryIcon(name: "clock-3", size: 13); Text("Unknown dates stay unknown. Dates are never guessed.").font(.system(size: 12)) }.foregroundStyle(.secondary)
                }.padding(14).padding(.bottom, 100)
            }.refreshable { await store.refresh() }
        }.diaryScreenBackground().diaryPageNavigation("Recently watched")
            .onChange(of: filters) { _, _ in limit = 12 }
            .sheet(item: $dateSelection) { selection in
                HistoryCalendarSheet(selection: selection) { day in
                    if selection.field == .from { filters.from = day } else { filters.to = day }
                }
            }
    }
    /// The design's date chip: the accent tint with a tick when chosen, a dark outline otherwise.
    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                Text(label)
            }.font(.system(size: 14, weight: .semibold)).lineLimit(1).padding(.horizontal, 15).frame(height: 38)
                .foregroundStyle(on ? HomeStyle.chipText : HomeStyle.primary)
                .background(on ? HomeStyle.chip : HomeStyle.round, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? .clear : HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                .frame(minHeight: 44).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
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
            EdgeToEdgeScroll {
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

/// The watches of one day, newest day first ("Fri, 6 Nov"); undated ones come last.
struct HistoryDay: Identifiable {
    let id: String
    let label: String
    let entries: [HistoryEntry]
    static func group(_ entries: [HistoryEntry]) -> [HistoryDay] {
        var order: [String] = [], byDay: [String: [HistoryEntry]] = [:], labels: [String: String] = [:]
        for entry in entries {
            let date = DiaryDate.parse(entry.event.watchedAt)
            let key = date.map { DiaryDate.day($0) } ?? "unknown"
            if byDay[key] == nil {
                order.append(key)
                labels[key] = date.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) } ?? "Date unknown"
            }
            byDay[key, default: []].append(entry)
        }
        return order.map { HistoryDay(id: $0, label: labels[$0] ?? $0, entries: byDay[$0] ?? []) }
    }
}

/// One watch in a day's card: a 16:9 still, the title, and the episode in the accent.
struct HistoryDayRow: View {
    let entry: HistoryEntry
    var body: some View {
        let model = HomeEpisodeCardModel(history: entry)
        HStack(spacing: 14) {
            Artwork(path: model.artwork, title: model.name, initialsOnly: false)
                .frame(width: 80, height: 46).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(model.episode).font(.system(size: 12, weight: .bold)).foregroundStyle(HomeStyle.chipText)
                    if model.isRewatch { Text("Rewatched").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary) }
                }.lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let date = model.date { Text(date.formatted(date: .omitted, time: .shortened)).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
        }.padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
            .accessibilityElement(children: .combine).accessibilityLabel(model.accessibilityLabel)
    }
}

/// One watch in History: the same compact composition as Home's activity, as a card in grid
/// mode and as a row (landscape thumbnail, title, episode, date beside them) in list mode.
struct HistoryRow: View {
    let entry: HistoryEntry
    var grid = false
    var body: some View {
        if grid { WatchActivityCard(model: HomeEpisodeCardModel(history: entry)) }
        else { HomeEpisodeCard(model: HomeEpisodeCardModel(history: entry), cards: false) }
    }
}
