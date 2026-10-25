# Compact poster sizing — 22 October 2026

The supplied Jelly screenshot establishes the new browsing density: three portrait covers across a phone, in a 2:3 ratio, with modest gaps, rounded corners and one-line titles. This supersedes the earlier wide 0.88-ratio collection cards.

Shared tokens in `src/tokens.css` now control poster ratio, width, gap, corners and title size. Library, Home collections, genre shelves, Explore discovery and personal recommendation rows share these tokens. Primary title-page covers use the same portrait geometry. Existing small inline thumbnails remain compact within their rows and hero cards. Glance explicitly retains its original 94px phone / 110px desktop / 80px narrow-phone poster widths and 4:5 card-cover ratio, as requested in the follow-up.

At 393px viewport width, browsing covers measure about 113.77 × 170.66px. At 320px they measure 89.33 × 134px. All three columns fit without page-level horizontal overflow; horizontal shelves intentionally scroll. Desktop browsing covers are 144 × 216px. Genre shelves no longer compute a separate poster width in JavaScript, avoiding an initial fallback-size jump and keeping their geometry aligned with the main grid.

Rating badges were tightened to fit beside status indicators on narrow covers. Titles use ellipsis while retaining their full accessible text. The standard phone content gutter is 14px. Title-page margins and safe-area toolbar spacing were adjusted to preserve alignment with that gutter.

Verification: zero Svelte/TypeScript errors or warnings, successful Cloudflare build, three compiled service-worker tests passed, and browser geometry/visual checks at 320px and 393px. The actual hosted Explore grid and recommendation row were also checked at desktop width and share 144 × 216px covers. These are Chromium viewport checks, not physical Safari certification. Screenshot: `screenshots/compact-posters-phone.png`.

Deployed to the new private Cloudflare host, version `ec50d10b-b2f3-44ac-ab86-1f90f68e85f8`. No commits or pushes.
