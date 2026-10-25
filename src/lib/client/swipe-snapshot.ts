/** iOS WebKit omits the swipe preview for manual history entries at a different scroll offset. */
export function preserveSwipeSnapshot(
  agent: { userAgent: string; maxTouchPoints: number },
  session: Pick<History, 'scrollRestoration'>
) {
  const ios =
    /iPad|iPhone|iPod/.test(agent.userAgent) ||
    (/Macintosh/.test(agent.userAgent) && agent.maxTouchPoints > 1);
  if (!ios || !/AppleWebKit/.test(agent.userAgent)) return;
  // Set this before Kit pushes/replaces: the departing entry keeps its preview
  // eligibility and the next entry inherits it. Kit still restores its saved
  // scroll position after committing the destination; no custom scroll handler.
  session.scrollRestoration = 'auto';
}
