import Testing
@testable import TwilDiaryCore

@Test func fieldDraftAdvancesOverUnrelatedRecordChangesWithoutLosingText() {
    var field = VersionedField(value: "Saved notes", version: 3)
    field.draft = "My new notes"
    field.observe(.init(value: "Saved notes", version: 4))
    #expect(field.draft == "My new notes")
    #expect(field.submission == .init(value: "My new notes", version: 4))
    #expect(field.conflict == nil)
}
@Test func fieldDraftNeverSilentlyRebasesOverAnotherEditToTheSameField() {
    var field = VersionedField(value: "Original", version: 3)
    field.draft = "Local draft"
    field.observe(.init(value: "Remote edit", version: 4))
    #expect(field.draft == "Local draft")
    #expect(field.submission == nil)
    #expect(field.conflict == .init(value: "Remote edit", version: 4))
    field.observe(.init(value: "Newest remote edit", version: 5))
    field.observe(.init(value: "Remote edit", version: 4))
    #expect(field.conflict?.version == 5)
    field.keepDraft()
    #expect(field.draft == "Local draft")
    #expect(field.submission == .init(value: "Local draft", version: 5))
    field.observe(.init(value: "A further remote edit", version: 6))
    #expect(field.submission == nil)
}
@Test func fieldConflictCanExplicitlyUseTheSavedValue() {
    var field = VersionedField(value: "Original", version: 1)
    field.draft = "Draft"; field.observe(.init(value: "Saved", version: 2))
    field.useSaved()
    #expect(field.draft == "Saved")
    #expect(!field.isDirty)
    #expect(field.version == 2)
}
@Test func cleanFieldsAndAlreadyMatchingDraftsAdoptTheSavedVersion() {
    var field = VersionedField(value: "Original", version: 1)
    field.observe(.init(value: "New saved value", version: 2))
    #expect(field.draft == "New saved value")
    field.draft = "Saved elsewhere"
    field.observe(.init(value: "Saved elsewhere", version: 3))
    #expect(!field.isDirty)
    #expect(field.conflict == nil)
    #expect(field.version == 3)
}
@Test func confirmedFieldWriteSurvivesFailedRefreshWithoutAnotherSubmission() {
    var field = VersionedField(value: "Original", version: 1)
    field.draft = "Saved draft"
    let submitted = field.submission!
    field.acknowledge(submitted, latest: .init(value: "Original", version: 1))
    #expect(field.draft == "Saved draft")
    #expect(field.awaitingRefresh)
    #expect(field.submission == nil)
    field.observe(.init(value: "Original", version: 1))
    #expect(field.awaitingRefresh)
    field.observe(.init(value: "Saved draft", version: 2))
    #expect(!field.awaitingRefresh)
    #expect(!field.isDirty)
    #expect(field.version == 2)
}
@Test func typingDuringASaveKeepsTheNewerDraftAfterAcknowledgement() {
    var field = VersionedField(value: "Original", version: 1)
    field.draft = "First draft"; let submitted = field.submission!
    field.draft = "More typing"
    field.acknowledge(submitted, latest: .init(value: "First draft", version: 2))
    #expect(field.draft == "More typing")
    #expect(field.submission == .init(value: "More typing", version: 2))
}
@Test func optionalRatingDraftKeepsClearAndFailedEditsDistinct() {
    var field = VersionedField<Double?>(value: 7.5, version: 1)
    field.draft = nil
    field.observe(.init(value: 7.5, version: 2))
    #expect(field.isDirty)
    #expect(field.submission != nil)
    #expect(field.submission?.value == nil)
    #expect(field.submission?.version == 2)
    let submitted = field.submission!
    field.acknowledge(submitted, latest: .init(value: nil, version: 3))
    #expect(!field.isDirty)
    #expect(field.draft == nil)
    field.draft = 8
    field.observe(.init(value: nil, version: 3))
    #expect(field.draft == 8)
    #expect(field.isDirty)
}
@Test func staleFieldSnapshotsCannotMoveTheReviewVersionBackwards() {
    var field = VersionedField(value: "Saved", version: 4)
    field.draft = "Draft"
    field.observe(.init(value: "Older", version: 3))
    #expect(field.draft == "Draft")
    #expect(field.version == 4)
    #expect(field.conflict == nil)
}
