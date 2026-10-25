# Status and progress — 23 October 2026

Interactive status changes now update real watch history through `/api/progress/status`. Previously the selector only patched the label, while sliders read watched events, so Planned/Completed could disagree with the displayed progress.

- **Completed:** log one viewing for an unwatched movie, or fill missing watches across every regular season of a show. Keep existing watch dates and rewatches. Shows load season metadata first; incomplete metadata, unreleased episodes and unknown air dates block completion before any history change. Specials do not block regular-season completion.
- **Planned:** the owner explicitly chose to reset progress to zero, including rewatches. Watch events are revoked rather than deleted. Undo restores the previous status and original dated/undated watches.
- **Watching / Dropped:** preserve existing progress.
- **Slider / episode controls:** derive status from actual history. Zero active watches returns Watching/Completed titles to Planned; partial history is Watching; complete regular seasons or any active movie viewing are Completed. Removing the latest movie viewing preserves older viewings, as previously requested, so its slider stays at 100% while an older viewing remains.

The title selectors, Library bulk actions and Add-as-Completed flow share the command. Queue remains independent. The title panel passes the selected watch date for new completion records; Library bulk completion uses the current time. Empty metadata cannot fabricate episode history.

Each command saves a durable receipt, history updates and title statuses in a single D1 batch. Reusing an operation identity returns its receipt without repeating the action. Undo is also retry-safe and checks the original post-change versions and watch set, preventing it from discarding newer edits or rewatches. A final catalog check prevents concurrent metadata refreshes from leaving new regular episodes unwatched under Completed. UI state changes only after confirmation; sliders discard stale drag drafts and the native selector retains confirmed state on failure.

Migration `0012_material_sebastian_shaw.sql` adds the receipt table and a purge trigger that removes receipts containing a permanently deleted title. It does not rewrite existing titles or watch history. Old inconsistent records are not silently backfilled; changing their status through the UI applies the new rule. Low-level title patching and provider synchronization retain their separate purposes and do not implicitly rewrite history.

Tests cover movie and multi-season completion, reset/Undo, preserved dates, repeated/lost responses, bulk reviewed versions, database rollback, concurrent rewatches, concurrent episode insertion, anonymous access and receipt cleanup. All writes used disposable fixtures; no owner title or Trakt history was modified for verification.
