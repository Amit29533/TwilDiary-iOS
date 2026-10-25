# Navigation, touch feedback & Stats

All six themes share the floating capsule mobile navigation shape, active tab pill and content/Undo clearance. Glass keeps its own reflective material, while other themes use their own accents. No route depth, swipe snapshot or scroll restoration policy changes were made.

Mouse hover decoration is restricted to hover-capable devices with fine pointers. Buttons opt out of native appearance. A root input-modality tracker suppresses pointer-only focus rings immediately, without blurring controls, moving focus or using a timeout. Tab, arrows, Enter and Space restore keyboard focus visibility. Native editable-field focus and selected control values remain intact. Unit tests cover immediate mode changes and listener teardown.

Stats fixes:

- Liquid Glass primary-action styling now targets actual action buttons. It no longer matches the positive-comparison paragraph. The comparison class also has a dedicated name.
- The month chart previously needed 392 px inside a 324 px viewport; the only two active days were outside the viewport. Flexible dense bars now fit month/90-day groups, keep nonzero bars visible and use explicit positioned fills for stable heights.
- The range picker has rounded inset segments, and its existing calendar/range mappings are unchanged. Native period and year selectors remain on one row.

Browser checks cover month bar bounds, selection/calendar synchronization, keyboard focus after pointer input, all six theme navigation geometries, and narrow screens. Browser verification does not reproduce every native iOS touch behavior; owner diary data is not altered by these checks.

Search focus is a single border on the field, with no offset ring or outer shadow to clip underneath the fixed header. The search dialog uses the same contained focus treatment. Glass controls, search surfaces and navigation share a 28 px frosted backdrop with matching saturation and luminosity; native selector popovers retain their iOS system material. Reduced transparency disables that backdrop and uses opaque surfaces.
