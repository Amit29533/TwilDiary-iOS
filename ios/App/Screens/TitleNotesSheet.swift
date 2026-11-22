import SwiftUI
import TwilDiaryCore

/// "My Note" on its own, for Glance's card menu: opens at once as a sheet over Glance, without
/// pushing the whole title page (episodes, cast, related titles) underneath, which made it stutter.
/// Saves exactly as the title page's notes do: the version you edited, with a conflict choice when
/// the notes changed elsewhere. A dirty draft can't be swiped away by accident.
struct TitleNotesSheet: View {
    let titleID: String
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var notesField = VersionedField(value: "", version: nil)
    @State private var loaded = false
    @State private var newTagText = ""
    var body: some View {
        NavigationStack {
            if let title = store.title(titleID) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title.name).font(.system(size: 15)).foregroundStyle(.secondary)
                    DisclosureGroup("Collections") {
                        InlineFlowLayout {
                            ForEach(title.tags ?? [], id: \.self) { tag in
                                Button { Task { await store.patch(title, values: ["tags": (title.tags ?? []).filter { $0 != tag }]) } } label: {
                                    Label(tag, systemImage: "xmark.circle").font(.caption)
                                }.buttonStyle(.plain).disabled(store.writesBlocked)
                            }
                        }
                        HStack {
                            TextField("Add collection tag", text: $newTagText).accessibilityIdentifier("title-new-tag")
                            Button("Add") {
                                let value = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !value.isEmpty, value.utf16.count <= 60, !(title.tags ?? []).contains(value), (title.tags ?? []).count < 20 else { return }
                                Task { if await store.patch(title, values: ["tags": (title.tags ?? []) + [value]]) { newTagText = "" } }
                            }.disabled(store.writesBlocked || newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }.font(.subheadline).padding(.horizontal, 14)
                    NotesEditor(text: $notesField.draft, accent: theme.accent)
                    if notesField.conflict != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Notes changed elsewhere. Your draft is kept. Choose which version to use before saving.").font(.footnote).foregroundStyle(.secondary)
                            HStack { Button("Use saved") { notesField.useSaved() }; Button("Keep my draft") { notesField.keepDraft() } }
                                .buttonStyle(.glass).buttonBorderShape(.capsule)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12)
                    .navigationTitle("My Note").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { Task { await save(); if !notesField.isDirty { dismiss() } } }
                                .accessibilityLabel("Save notes")
                                .disabled(store.writesBlocked || !notesField.isDirty || notesField.submission == nil || notesField.draft.utf16.count > 20_000)
                        }
                    }
                    .onChange(of: title.version) { _, _ in notesField.observe(.init(value: title.notes, version: title.version)) }
            } else {
                ContentUnavailableView("Title unavailable", systemImage: "film")
            }
        }
        .onAppear {
            guard !loaded, let title = store.title(titleID) else { return }
            loaded = true
            notesField = VersionedField(value: title.notes, version: title.version)
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible).interactiveDismissDisabled(notesField.isDirty)
    }
    private func save() async {
        guard let current = store.title(titleID), notesField.draft.utf16.count <= 20_000 else { return }
        notesField.observe(.init(value: current.notes, version: current.version))
        guard let submitted = notesField.submission else { return }
        let acknowledged = await store.patch(current, values: ["notes": submitted.value], expectedVersion: submitted.version)
        guard let saved = store.title(titleID) else { return }
        let snapshot = VersionedField<String>.Snapshot(value: saved.notes, version: saved.version)
        if acknowledged { notesField.acknowledge(submitted, latest: snapshot) } else { notesField.observe(snapshot) }
    }
}
