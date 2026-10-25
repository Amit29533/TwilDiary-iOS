# Owner iPhone results — native54, 25 October 2026

Reported by the owner after installing the supplied Codemagic-passed54IPA.
Device model was not specified in this report; earlier context states iOS27.
No claim that the remaining provider/offline/accessibility tests passed.

| Checks | Owner result | Follow-up |
| --- | --- | --- |
| T01 (first line called T10) | Header still shudders and switches abruptly; clip1 | Gradual transition with stable toolbar geometry |
| T02 | Normal Back works; root-screen tab swipes fail | Test actual content and Glance card gesture ownership |
| T03 | Solved | Preserve keyboard-safe retained search |
| T04 | Tab scrubbing jumps between destinations; clip2 | Replace custom bar with system Liquid Glass TabView |
| T05/T24 | Episode grid still ugly/breaks layout | Put watch check at thumbnail bottom-right; preserve spoiler/rewatch rules |
| T06 | Notes survives restart; menu scroll jumps | Animate Notes/Files focus including delayed content |
| T07 | Toast works, but too large/ugly | Smaller capsule with accessible touch targets |
| T08–T21 | Watch, rewatch, slider, season, movie, dates, history, covers, pending state, menus, Library, public ratings, Home links and Trash work | Preserve regression coverage; T10toast polish still requested |
| T22/T23 | Artwork/synopsis and edits fine | Preserve layout and data behavior |
| T24 | Spoilers/seasons fine, except episode grid | Grid follow-up above |
| T25 | Information works but lacks requested transparency | Retain artwork tint at large detent and opaque dark opinion cards |
| T26–T31 | Search, import, cast, Surprise, Stats and files fine | Preserve |
| T32 | Glass theme feels slower; flat band around TwilDiary header looks bad | Remove material stripe/duplicated layers and cache preblurred artwork |
| T33 | Authentication works | Preserve |
| T34–T41 | Owner says next results will follow | Pending, do not mark passed |

Two supplied videos (10.34s header,8.87s tabs) were visually inspected using
locally extracted contact sheets. These personal recordings/frames stay in
.local and are not committed. The three screenshots illustrate episode grid,
requested translucent Information appearance and the unwanted header band.

Native57is the prepared response, not yet compiled or accepted. Source changes
must pass Codemagic before ios-native promotion; screenshots and another phone
check are needed for physical transition smoothness. Automatic incoming Trakt
latency remains separately pending; this feedback contains no T34–T41 result.
