// Apply the saved appearance before styles paint. Keep the allowlist in sync with themes.ts.
(() => {
  const ids = ['twilight', 'ocean', 'jade', 'rose', 'amber', 'glass'];
  let id = 'twilight';
  try {
    const saved = localStorage.getItem('twildiary.theme.v1');
    if (ids.includes(saved)) id = saved;
  } catch {
    /* Appearance still works when device storage is blocked. */
  }
  document.documentElement.dataset.theme = id;
})();
