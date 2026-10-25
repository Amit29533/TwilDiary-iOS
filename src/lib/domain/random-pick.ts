import type { MediaTitle } from './types.ts';

/** Exclude archived titles and avoid immediately repeating the previous pick. */
export function randomPick(
  titles: readonly MediaTitle[],
  previousId?: string,
  random = Math.random
): MediaTitle | null {
  const active = titles.filter((title) => !title.deletedAt);
  const candidates = active.length > 1 ? active.filter((title) => title.id !== previousId) : active;
  if (!candidates.length) return null;
  const sample = random();
  const index = Math.min(
    candidates.length - 1,
    Math.max(0, Math.floor((Number.isFinite(sample) ? sample : 0) * candidates.length))
  );
  return candidates[index]!;
}

export function rapidTap(previous: readonly number[], now: number) {
  const taps = [...previous.filter((instant) => now - instant <= 850 && now >= instant), now];
  return { triggered: taps.length >= 3, taps: taps.length >= 3 ? [] : taps };
}
