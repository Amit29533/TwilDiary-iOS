import type { DiarySnapshot, MediaTitle } from '../domain/types.ts';

/** Fictional personal state. Never imported into the owner's workspace. */
export function sampleDiary(): DiarySnapshot {
  const definitions = [
    [
      'frieren',
      'Frieren: Beyond Journey’s End',
      'anime',
      2023,
      'frieren',
      ['Adventure', 'Fantasy'],
      'An elven mage retraces a journey, discovering what the time she shared with her companions really meant.',
      28,
      12
    ],
    [
      'night',
      'Call of the Night',
      'anime',
      2022,
      'night',
      ['Romance', 'Supernatural'],
      'A sleepless teenager finds a different kind of life in the quiet streets after dark.',
      13,
      5
    ],
    [
      'severance',
      'Severance',
      'show',
      2022,
      'severance',
      ['Drama', 'Mystery'],
      'The employees of Lumon divide their work and personal memories. The boundary begins to unravel.',
      9,
      3
    ],
    [
      'again',
      '18 Again',
      'show',
      2020,
      'again',
      ['Drama', 'Romance'],
      'A father gets an unexpected chance to see his family’s life from a new perspective.',
      16,
      8
    ]
  ] as const;
  const titles: MediaTitle[] = definitions.map(
    ([id, name, category, year, art, genres, overview]) => ({
      id,
      name,
      category,
      year,
      overview,
      poster: `/demo/${art}.jpg`,
      genres: [...genres],
      runtimeMinutes: category === 'anime' ? 24 : 50,
      status: 'watching',
      favorite: id === 'frieren',
      score: null,
      notes: '',
      tags: []
    })
  );
  titles.push(
    {
      id: 'quiet-orbit',
      name: 'A Quiet Orbit',
      category: 'movie',
      year: 2025,
      overview: 'A sample movie for trying the diary. This is fictional preview content.',
      poster: null,
      genres: ['Science fiction', 'Drama'],
      runtimeMinutes: 112,
      status: 'planned',
      favorite: false,
      score: null,
      notes: '',
      tags: ['Weekend']
    },
    {
      id: 'after-rain',
      name: 'After the Rain',
      category: 'anime-movie',
      year: 2024,
      overview: 'A fictional sample title for exploring your library.',
      poster: null,
      genres: ['Animation', 'Romance'],
      runtimeMinutes: 96,
      status: 'completed',
      favorite: true,
      score: 9,
      notes: 'A sample note. Your own diary starts empty.',
      tags: ['Comfort watches']
    }
  );
  const episodes = definitions.flatMap(([id, , , , , , , count]) =>
    Array.from({ length: count }, (_, i) => ({
      id: `${id}-s1e${i + 1}`,
      titleId: id,
      season: 1,
      number: i + 1,
      name: `Sample chapter ${i + 1}`,
      overview: 'Sample episode information for testing spoiler controls.',
      airedOn: '2024-01-01'
    }))
  );
  const events = definitions.flatMap(([id, , , , , , , , watched]) =>
    Array.from({ length: watched }, (_, i) => ({
      id: `sample-${id}-${i + 1}`,
      operationId: `sample-${id}-${i + 1}`,
      titleId: id,
      episodeId: `${id}-s1e${i + 1}`,
      watchedAt: null,
      recordedAt: '2026-10-21T00:00:00Z',
      revokedAt: null,
      origin: 'sample' as const
    }))
  );
  return {
    schemaVersion: 1,
    titles,
    episodes,
    events,
    skippedEpisodeIds: [],
    locations: [
      {
        id: 'loc-frieren',
        titleId: 'frieren',
        deviceId: 'sample-pc',
        deviceName: 'Windows PC',
        volumeId: 'sample-volume-e',
        driveLetter: 'E:',
        root: 'E:\\Media Server',
        relativePath: 'Anime\\Frieren\\Season 01',
        season: 1,
        fileCount: 28,
        sizeBytes: 22_400_000_000,
        evidence: 'present',
        checkedAt: '2026-10-21T00:00:00Z'
      },
      {
        id: 'loc-night',
        titleId: 'night',
        deviceId: 'sample-pc',
        deviceName: 'Windows PC',
        volumeId: 'sample-volume-e',
        driveLetter: 'E:',
        root: 'E:\\Media Server',
        relativePath: 'Anime\\Call of the Night\\Season 01',
        season: 1,
        fileCount: 13,
        sizeBytes: 6_500_000_000,
        evidence: 'present',
        checkedAt: '2026-10-21T00:00:00Z'
      },
      {
        id: 'loc-severance',
        titleId: 'severance',
        deviceId: 'sample-pc',
        deviceName: 'Windows PC',
        volumeId: 'sample-volume-f',
        driveLetter: 'F:',
        root: 'F:\\Media Server',
        relativePath: 'Shows\\Severance\\Season 01',
        season: 1,
        fileCount: 9,
        sizeBytes: 9_000_000_000,
        evidence: 'unavailable',
        checkedAt: '2026-10-20T00:00:00Z'
      }
    ]
  };
}
