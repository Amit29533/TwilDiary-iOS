import type { DiarySnapshot } from '../domain/types.ts';

const DATABASE = 'twil-v2-design-preview';
export interface PreviewState {
  snapshot: DiarySnapshot | null;
  revision: number;
}
export class PreviewConflict extends Error {
  constructor() {
    super(
      'This workspace changed in another tab. The latest version has been loaded; please retry your change.'
    );
  }
}

async function open(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE, 1);
    request.onupgradeneeded = () => request.result.createObjectStore('workspace');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error('Preview storage unavailable'));
    request.onblocked = () => reject(new Error('Another preview tab is blocking storage'));
  });
}
function snapshotValue(data: unknown): DiarySnapshot | null {
  if (data === undefined || data === null) return null;
  if (
    typeof data !== 'object' ||
    !('schemaVersion' in data) ||
    data.schemaVersion !== 1 ||
    !['titles', 'episodes', 'events', 'locations', 'skippedEpisodeIds'].every((key) =>
      Array.isArray((data as Record<string, unknown>)[key])
    )
  )
    throw new Error('Saved preview is not compatible');
  return data as DiarySnapshot;
}
export async function readPreview(): Promise<PreviewState> {
  const db = await open();
  try {
    return await new Promise((resolve, reject) => {
      const transaction = db.transaction('workspace');
      const store = transaction.objectStore('workspace');
      const data = store.get('sample');
      const revision = store.get('revision');
      transaction.oncomplete = () => {
        try {
          resolve({ snapshot: snapshotValue(data.result), revision: revision.result ?? 0 });
        } catch (error) {
          reject(error);
        }
      };
      transaction.onabort = () => reject(transaction.error ?? new Error('Preview read failed'));
      transaction.onerror = () => reject(transaction.error ?? new Error('Preview read failed'));
    });
  } finally {
    db.close();
  }
}
/** Compare and save inside one serial IndexedDB transaction: no silent cross-tab data loss. */
export async function writePreview(
  snapshot: DiarySnapshot,
  expectedRevision: number
): Promise<number> {
  const db = await open();
  try {
    return await new Promise((resolve, reject) => {
      const transaction = db.transaction('workspace', 'readwrite');
      const store = transaction.objectStore('workspace');
      let conflict = false;
      const request = store.get('revision');
      request.onsuccess = () => {
        if ((request.result ?? 0) !== expectedRevision) {
          conflict = true;
          transaction.abort();
          return;
        }
        store.put(snapshot, 'sample');
        store.put(expectedRevision + 1, 'revision');
      };
      transaction.oncomplete = () => resolve(expectedRevision + 1);
      transaction.onabort = () =>
        reject(
          conflict ? new PreviewConflict() : (transaction.error ?? new Error('Preview save failed'))
        );
      transaction.onerror = () => reject(transaction.error ?? new Error('Preview save failed'));
    });
  } finally {
    db.close();
  }
}
export async function readSpoilerPreference(): Promise<boolean> {
  const db = await open();
  try {
    return await new Promise((resolve, reject) => {
      const request = db.transaction('workspace').objectStore('workspace').get('hideSpoilers');
      request.onsuccess = () => resolve(request.result !== false);
      request.onerror = () => reject(request.error);
    });
  } finally {
    db.close();
  }
}
export async function writeSpoilerPreference(value: boolean): Promise<void> {
  const db = await open();
  try {
    await new Promise<void>((resolve, reject) => {
      const transaction = db.transaction('workspace', 'readwrite');
      transaction.objectStore('workspace').put(value, 'hideSpoilers');
      transaction.oncomplete = () => resolve();
      transaction.onabort = () => reject(transaction.error ?? new Error('Preference save failed'));
      transaction.onerror = () => reject(transaction.error ?? new Error('Preference save failed'));
    });
  } finally {
    db.close();
  }
}
