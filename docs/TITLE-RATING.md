# Title rating controls

The main watch progress panel uses a **Rate show** or **Rate movie** button beside Watched today, below the normal watch button. The compact personal rating slider is collapsed initially and slides open when the rating button is tapped; tapping again closes it. Movies and titles awaiting episode metadata also provide the corresponding rating button. The hero rating row and overflow-menu rating links reveal the same control.

The slider runs from 1 to 10 in 0.5-point steps and saves on release. Clear removes only the rating. Notes remain a separate section with an independent save, so editing one cannot overwrite the other. Existing imported decimal scores remain stored until explicitly edited; the slider rounds its draft to the nearest half-point. Existing Trakt export rounding remains unchanged.

Verification: 188 unit/database/runtime tests and 3 compiled service-worker tests passed before the final presentation adjustment. The final presentation passed type checking and a production build. Isolated browser checks confirmed hidden-by-default behavior, open/close, half-point saving, persistence, and no horizontal overflow at 320px and 393px. Owner data was not changed by these UI tests. The deployed control was also checked read-only for min=1, max=10 and step=0.5.

Screenshot: `screenshots/rate-half-point-phone.png` (disposable fixture). Private Cloudflare deployment: `15eb6ee0-3b7e-46ad-83ca-97d0a78bcc63`. No commits or pushes.
