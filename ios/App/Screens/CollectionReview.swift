import SwiftUI
import TwilDiaryCore

struct CollectionReview: Identifiable {
    let id = UUID()
    let titles: [MediaTitle]
    let change: CollectionChange
}

struct CollectionReviewView: View {
    let review: CollectionReview
    var onSaved: () -> Void = { }
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(review.change.heading).font(.title2.bold())
                    Text(review.change.explanation).font(.subheadline).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(review.titles.count) \(review.titles.count == 1 ? "title" : "titles") selected").font(.subheadline.bold())
                        ForEach(Array(review.titles.prefix(4))) { Text($0.name).font(.subheadline) }
                        if review.titles.count > 4 { Text("and \(review.titles.count - 4) more").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).diaryPanel()
                    if let failure { Text(failure).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("collection-error") }
                    Button(role: review.change.destructive ? .destructive : nil) {
                        Task {
                            if await store.manage(review.titles, change: review.change) { onSaved(); dismiss() }
                            else { failure = store.error ?? "Wait for the current change to finish." }
                        }
                    } label: { Text(store.busy ? "Saving…" : review.change == .purge ? "Delete permanently" : "Confirm").font(.subheadline.bold()).frame(maxWidth: .infinity).frame(minHeight: 50) }.buttonStyle(.borderedProminent).disabled(store.writesBlocked).accessibilityIdentifier("confirm-collection")
                }.padding(20)
            }.navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.busy) } }
        }.interactiveDismissDisabled(store.busy).presentationDetents([.medium, .large])
    }
}

struct CollectionSelectionPanel: View {
    let titles: [MediaTitle]
    @Binding var selected: Set<String>
    var archived = false
    let onReview: (CollectionChange) -> Void
    @Environment(DiaryStore.self) private var store
    @State private var action = "watching"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("\(selected.count) selected").font(.subheadline.bold()); Spacer(); Button(titles.count > CollectionRequest.limit ? "Select first 60" : "Select shown") { selected = Set(titles.prefix(CollectionRequest.limit).map(\.id)) }; Button("Clear") { selected = [] }.disabled(selected.isEmpty) }.font(.caption)
            Text("Selection applies to the titles shown here. Up to 60 at a time.").font(.caption).foregroundStyle(.secondary)
            if archived {
                HStack { Button("Restore") { onReview(.restore) }; Button("Delete", role: .destructive) { onReview(.purge) } }.buttonStyle(.bordered).disabled(selected.isEmpty)
            } else {
                HStack {
                    Picker("Selection action", selection: $action) {
                        Text("Queue").tag("queue"); Text("Remove from Queue").tag("unqueue")
                        ForEach(["planned", "watching", "completed", "dropped"], id: \.self) { Text($0.capitalized).tag($0) }
                    }.pickerStyle(.menu).accessibilityIdentifier("collection-action")
                    Button("Apply", systemImage: "checkmark") { onReview(action == "queue" || action == "unqueue" ? .queue(action == "queue") : .status(action)) }.labelStyle(.iconOnly).accessibilityLabel("Apply selection action").disabled(selected.isEmpty)
                    Spacer(minLength: 0)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading) { actions }
                }.buttonStyle(.bordered).font(.caption).disabled(selected.isEmpty)
            }
        }.diaryPanel().disabled(store.busy)
    }
    @ViewBuilder private var actions: some View {
        Button("Favorite", systemImage: "heart") { onReview(.favorite(true)) }
        Button("Remove favorites", systemImage: "heart.slash") { onReview(.favorite(false)) }.labelStyle(.iconOnly)
        Button("Trash", systemImage: "trash", role: .destructive) { onReview(.trash) }
    }
}
