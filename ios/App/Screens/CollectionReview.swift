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
            EdgeToEdgeScroll {
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
                    } label: { Text(store.busy ? "Saving…" : review.change == .purge ? "Delete permanently" : "Confirm").font(.subheadline.bold()).frame(maxWidth: .infinity).frame(minHeight: 50) }.buttonStyle(.diaryPrimary).disabled(store.writesBlocked).accessibilityIdentifier("confirm-collection")
                }.padding(20)
            }.navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.busy) } }
        }.interactiveDismissDisabled(store.busy).presentationDetents([.medium, .large])
    }
}
