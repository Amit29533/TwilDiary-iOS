# Appearance

Open **More → Theme** to choose a theme. Changes apply immediately across the app.

| Theme        | Accent   | Material                                                             |
| ------------ | -------- | -------------------------------------------------------------------- |
| Twilight     | Violet   | Original dark surfaces                                               |
| Ocean        | Blue     | Original dark surfaces                                               |
| Jade         | Mint     | Original dark surfaces                                               |
| Rose         | Pink     | Original dark surfaces                                               |
| Amber        | Gold     | Original dark surfaces                                               |
| Liquid Glass | Ice blue | Pure black AMOLED canvas, dark glass controls and silver reflections |

### Design Lab (iPhone app)

**Settings → Appearance → Design Lab** chooses how each part of the app looks, in every theme (owner's request, November 2026). Its starting points are **Original** (the app as it was, the default), **Studio** (every piece of the November redraws of Home, Glance, the title page, the person page and Known for) and **Custom** (anything else). Each area (Home, Glance, Title page, People) has its own page with a two-way choice per piece; **Feel** sets press feel (Bouncy, Firm, Off), where rating badges sit (as is, top, bottom, off), corners (squarer, standard, rounder: posters, and cards in Native) and grey layout switches. Redrawn pieces use the theme's own accent. Code: `ios/App/Design/Studio.swift` (`Studio.on(_:)`, `StudioLab`). Two people-page orderings (lead roles first in Known for, released titles first in Shows and Movies) are Design Lab choices too, because the shared ranking in `PersonSections` matches the web app and its golden tests. Studio was briefly a theme; `DesignLabMigration` moves anyone on it to Native with the Studio preset.

All six themes share the floating capsule navigation layout and a whole-tab selection pill, with matching safe-area clearance for content and Undo messages. Each theme retains its own accent and material treatment. Navigation, filters, progress, primary actions, personal ratings and accent-based charts share theme tokens. Semantic success/error colors, gold community ratings, artwork and genre category colors keep their meaning.

The device-local preference uses only `twildiary.theme.v1`. It does not modify diary data or sync settings. Other tabs on the same origin follow changes. A small allowlisted pre-paint script restores the theme before rendering; the PWA caches this public script for offline startup. Invalid preferences fall back to Twilight. If saving is blocked, the picker reports that the choice applies to the current session.

Liquid Glass uses a pure black AMOLED canvas, dark content surfaces, a floating capsule navigation bar and silver highlights on translucent controls. It takes material inspiration from Apple’s Human Interface Guidelines for [materials](https://developer.apple.com/design/human-interface-guidelines/materials). It keeps artwork sharp and the shared wordmark header opaque. It adds no page-root transforms, navigation delays, motion or extra status-bar spacing. It respects reduced transparency with opaque controls and honors increased contrast. The previously deferred iOS Home Screen header rendering issue remains separate.

## Validation

- Unit tests cover all theme IDs, corrupted/denied storage, dedicated-key writes, the actual pre-paint script and normal-text contrast for accents and filled buttons.
- Production PWA tests check that the startup script is cached and served offline.
- Browser checks at 393 px and 320 px verify the picker fits without horizontal overflow. All six themes were selected, their applied accent and selected state checked, and Liquid Glass was retained after a reload.
- Mobile Glass settings and Home screenshots are in `docs/screenshots/themes-glass-phone.png` and `docs/screenshots/themes-glass-home-phone.png`.

Native iPhone rendering still needs device verification; desktop browser checks cannot establish native WebKit blur behavior.
