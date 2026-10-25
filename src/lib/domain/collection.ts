import type { DiarySnapshot, MediaTitle } from './types.ts';

const nameKey = (value: string) => value.normalize('NFKC').trim().toLocaleLowerCase('en-US');

export function insertTitle(snapshot: DiarySnapshot, title: MediaTitle) {
  if (!title.id || !title.name.trim() || title.name.trim().length > 300)
    throw new Error('Invalid title identity');
  const existing =
    snapshot.titles.find((t) => t.id === title.id) ??
    snapshot.titles.find(
      (t) =>
        nameKey(t.name) === nameKey(title.name) &&
        t.year === title.year &&
        t.category === title.category
    );
  if (existing?.deletedAt)
    throw new Error('This title is in Trash. Restore it before adding it again.');
  if (existing) return { snapshot, titleId: existing.id, added: false };
  return {
    snapshot: { ...snapshot, titles: [...snapshot.titles, { ...title, name: title.name.trim() }] },
    titleId: title.id,
    added: true
  };
}
