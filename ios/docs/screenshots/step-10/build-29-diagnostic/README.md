# Build 29 scoped diagnostics

Source ed2db3f, run 40113092136, iPhone 17 Pro/iOS26.5. Overall run FAILED: Core56 and compilation pass, zero warnings; early UI8/10. Native units/full UI/extra-phone/IPA stages skipped. This is not accepted release or full parity evidence.

These unmodified synthetic screenshots belong to individually passed cases:
- glance-notes-after-metadata.png: testGlanceNotesWaitForLateCastAndRelatedLayoutThenKeepEditorVisible, including real editor bounds, typing, saving and reopening after delayed fixture metadata.
- compact-surprise.png: testRandomPickKeepsPlannedScopeAndLogoRerollsWithoutRepeating, including strict compact rendered surface bounds, backdrop tap staying open, up/down swipe dismissal, planned-only scope, reroll and Open.

Known remaining checks: wait for each Done transition across every settings destination; use a genuinely slow held short edge gesture to test cancellation instead of a fast completing flick. Full grid/all-phone synopsis coverage is still pending. See PROGRESS.md and DEVICE-CHECKS.md.
