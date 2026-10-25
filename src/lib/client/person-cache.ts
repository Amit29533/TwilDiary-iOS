import type { PersonDetails } from '../people.ts';

// Public provider metadata only. Sharing the same bounded cache keeps the full
// grid available before Kit restores scroll when returning from a title.
const people = new Map<string, { person: PersonDetails; expires: number }>();
export function cachedPerson(id: string) {
  const cached = people.get(id);
  if (!cached) return null;
  if (cached.expires <= Date.now()) {
    people.delete(id);
    return null;
  }
  return cached.person;
}
export function rememberPerson(person: PersonDetails) {
  const id = String(person.id);
  people.delete(id);
  if (people.size >= 32) people.delete(people.keys().next().value!);
  people.set(id, { person, expires: Date.now() + 15 * 60000 });
}
