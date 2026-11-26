import SwiftUI
import TwilDiaryCore

/// The views of a film, or of one episode, each with its date ("No date" for one logged without):
/// tap one to move it to another day. Offered while the diary's service keeps every play
/// (`DiaryStore.canChangeWatchDates`).
struct WatchDatesSheet: View {
    let titleID: String
    var episodeID: String? = nil
    let heading: String
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Newest first; any without a date last.
    private var views: [WatchEvent] {
        store.titleScope(titleID).activeEvents.filter { $0.titleId == titleID && $0.episodeId == episodeID }
            .sorted { ($0.watchedAt ?? "", $0.id) > ($1.watchedAt ?? "", $1.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(views) { event in
                    NavigationLink { WatchDateEditor(event: event) } label: {
                        Text(Self.label(event)).foregroundStyle(event.watchedAt == nil ? Color.secondary : Color.primary)
                    }.accessibilityIdentifier("watch-dates-" + event.id)
                }
            }
            .overlay { if views.isEmpty { Text("No views").foregroundStyle(.secondary) } }
            .navigationTitle(heading).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }

    static func label(_ event: WatchEvent) -> String {
        DiaryDate.parse(event.watchedAt).map { $0.formatted(.dateTime.day().month(.abbreviated).year()) } ?? "No date"
    }
}

/// One view's day, changed: Save sends it (the new play first, then the old one off).
struct WatchDateEditor: View {
    let event: WatchEvent
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var day: Date
    @State private var saving = false

    init(event: WatchEvent) {
        self.event = event
        _day = State(initialValue: DiaryDate.parse(event.watchedAt) ?? .now)
    }

    /// The same day it already has: nothing to save.
    private var unchanged: Bool {
        guard let current = DiaryDate.parse(event.watchedAt) else { return false }
        return DiaryDate.calendar().isDate(day, inSameDayAs: current)
    }

    var body: some View {
        EdgeToEdgeScroll {
            DatePicker("Watch date", selection: $day, in: ...store.now, displayedComponents: .date).datePickerStyle(.graphical).padding(16)
        }
        .navigationTitle("Watch date").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() }
                else {
                    Button("Save") { save() }.disabled(unchanged || store.writesBlocked).accessibilityIdentifier("watch-date-save")
                }
            }
        }
    }

    private func save() {
        saving = true
        let instant = Self.instant(day, now: store.now)
        Task {
            let done = await store.changeWatchDate(event, to: instant)
            saving = false
            if done { dismiss() }
        }
    }

    /// A chosen day as the moment logged: now for today, else midday that day (as a watch logged
    /// with a date always has been).
    static func instant(_ day: Date, now: Date) -> Date {
        let calendar = DiaryDate.calendar()
        return calendar.isDate(day, inSameDayAs: now) ? now : calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }
}
