import { sql } from 'drizzle-orm';
import type { CastMember } from '../../domain/types.ts';
import type { DiscoveryItem } from '../../discovery.ts';
import type { PersonDetails } from '../../people.ts';
import {
  check,
  foreignKey,
  index,
  integer,
  primaryKey,
  real,
  sqliteTable,
  text,
  uniqueIndex
} from 'drizzle-orm/sqlite-core';

// One private diary per deployment. No public Data API or client database credentials.
export const titles = sqliteTable(
  'titles',
  {
    id: text('id').primaryKey(),
    name: text('name').notNull(),
    sortName: text('sort_name').notNull(),
    kind: text('kind', { enum: ['movie', 'series'] }).notNull(),
    category: text('category', { enum: ['movie', 'show', 'anime', 'anime-movie'] }).notNull(),
    year: integer('year'),
    overview: text('overview').notNull().default(''),
    posterPath: text('poster_path'),
    backdropPath: text('backdrop_path'),
    runtimeMinutes: integer('runtime_minutes'),
    genres: text('genres', { mode: 'json' }).$type<string[]>().notNull().default([]),
    communityScore: real('community_score'),
    status: text('status', { enum: ['planned', 'watching', 'completed', 'dropped'] })
      .notNull()
      .default('planned'),
    favorite: integer('favorite', { mode: 'boolean' }).notNull().default(false),
    queued: integer('queued', { mode: 'boolean' }).notNull().default(false),
    score: real('score'),
    notes: text('notes').notNull().default(''),
    version: integer('version').notNull().default(1),
    createdAt: text('created_at').notNull(),
    updatedAt: text('updated_at').notNull(),
    deletedAt: text('deleted_at')
  },
  (t) => [
    index('titles_library_order').on(t.deletedAt, t.sortName, t.id),
    index('titles_glance').on(t.deletedAt, t.status, t.sortName, t.id),
    check('titles_name_length', sql`length(${t.name}) BETWEEN 1 AND 300`),
    check(
      'titles_kind_category',
      sql`(${t.kind} = 'movie' AND ${t.category} IN ('movie','anime-movie')) OR (${t.kind} = 'series' AND ${t.category} IN ('show','anime'))`
    ),
    check('titles_status_valid', sql`${t.status} IN ('planned','watching','completed','dropped')`),
    check('titles_score_range', sql`${t.score} IS NULL OR ${t.score} BETWEEN 1 AND 10`),
    check('titles_favorite_boolean', sql`${t.favorite} IN (0,1)`),
    check('titles_notes_length', sql`length(${t.notes}) <= 20000`),
    check('titles_positive_version', sql`${t.version} > 0`)
  ]
);

/** Presentation metadata and a one-time migration ledger; never credentials. */
export const workspaceUi = sqliteTable('workspace_ui', {
  titleId: text('title_id')
    .primaryKey()
    .references(() => titles.id, { onDelete: 'cascade' }),
  poster: text('poster'),
  backdrop: text('backdrop'),
  tags: text('tags', { mode: 'json' }).$type<string[]>().notNull().default([]),
  demo: integer('demo', { mode: 'boolean' }).notNull().default(false)
});
export const workspaceMigrations = sqliteTable('workspace_migrations', {
  id: text('id').primaryKey(),
  token: text('token').notNull(),
  snapshot: text('snapshot').notNull(),
  createdAt: text('created_at').notNull()
});

export const providerIdentities = sqliteTable(
  'provider_identities',
  {
    id: text('id').primaryKey(),
    titleId: text('title_id')
      .notNull()
      .references(() => titles.id, { onDelete: 'cascade' }),
    provider: text('provider', { enum: ['tmdb', 'imdb', 'trakt', 'tvdb'] }).notNull(),
    kind: text('kind', { enum: ['movie', 'series'] }).notNull(),
    externalId: text('external_id').notNull()
  },
  (t) => [
    uniqueIndex('provider_unique_identity').on(t.provider, t.kind, t.externalId),
    index('provider_title').on(t.titleId)
  ]
);

export const seasons = sqliteTable(
  'seasons',
  {
    id: text('id').primaryKey(),
    titleId: text('title_id')
      .notNull()
      .references(() => titles.id, { onDelete: 'cascade' }),
    number: integer('number').notNull(),
    name: text('name').notNull(),
    expectedEpisodes: integer('expected_episodes'),
    metadataLoadedAt: text('metadata_loaded_at'),
    metadataVersion: integer('metadata_version').notNull().default(1)
  },
  (t) => [
    uniqueIndex('seasons_coordinates').on(t.titleId, t.number),
    uniqueIndex('seasons_parent_identity').on(t.id, t.titleId),
    check('season_number_range', sql`${t.number} BETWEEN 0 AND 999`),
    check(
      'season_episode_count',
      sql`${t.expectedEpisodes} IS NULL OR ${t.expectedEpisodes} BETWEEN 0 AND 5000`
    )
  ]
);

export const episodes = sqliteTable(
  'episodes',
  {
    id: text('id').primaryKey(),
    titleId: text('title_id')
      .notNull()
      .references(() => titles.id, { onDelete: 'cascade' }),
    seasonId: text('season_id').notNull(),
    number: integer('number').notNull(),
    name: text('name').notNull().default(''),
    overview: text('overview').notNull().default(''),
    airedOn: text('aired_on'),
    skipped: integer('skipped', { mode: 'boolean' }).notNull().default(false),
    tmdbId: integer('tmdb_id'),
    stillPath: text('still_path'),
    traktId: integer('trakt_id'),
    communityScore: real('community_score')
  },
  (t) => [
    uniqueIndex('episodes_coordinates').on(t.seasonId, t.number),
    uniqueIndex('episodes_parent_identity').on(t.id, t.titleId),
    index('episodes_title').on(t.titleId, t.seasonId, t.number),
    foreignKey({
      columns: [t.seasonId, t.titleId],
      foreignColumns: [seasons.id, seasons.titleId]
    }).onDelete('cascade'),
    check('episode_number_range', sql`${t.number} BETWEEN 1 AND 5000`),
    check('episode_skipped_boolean', sql`${t.skipped} IN (0,1)`)
  ]
);

/** Public provider credits, cached independently of personal library fields. */
export const metadataCredits = sqliteTable('metadata_credits', {
  key: text('key').primaryKey(),
  cast: text('cast', { mode: 'json' }).$type<CastMember[]>().notNull(),
  fetchedAt: text('fetched_at').notNull()
});

/** Public recommendations only; library membership is derived from the current workspace. */
export const metadataRecommendations = sqliteTable('metadata_recommendations', {
  key: text('key').primaryKey(),
  items: text('items', { mode: 'json' }).$type<DiscoveryItem[]>().notNull(),
  fetchedAt: text('fetched_at').notNull()
});

export const metadataPeople = sqliteTable('metadata_people', {
  id: integer('id').primaryKey(),
  details: text('details', { mode: 'json' }).$type<PersonDetails>().notNull(),
  fetchedAt: text('fetched_at').notNull()
});

export const watchEvents = sqliteTable(
  'watch_events',
  {
    id: text('id').primaryKey(),
    operationId: text('operation_id').notNull(),
    titleId: text('title_id')
      .notNull()
      .references(() => titles.id, { onDelete: 'cascade' }),
    episodeId: text('episode_id'),
    watchedAt: text('watched_at'),
    recordedAt: text('recorded_at').notNull(),
    revokedAt: text('revoked_at'),
    version: integer('version').notNull().default(1),
    origin: text('origin', { enum: ['manual', 'import', 'trakt'] }).notNull(),
    remoteHistoryId: text('remote_history_id')
  },
  (t) => [
    uniqueIndex('watch_operation_id').on(t.operationId),
    uniqueIndex('watch_remote_history').on(t.origin, t.remoteHistoryId),
    index('watch_remote_lookup').on(t.remoteHistoryId),
    index('watch_title_progress').on(t.titleId, t.revokedAt, t.episodeId),
    index('watch_activity').on(t.revokedAt, t.recordedAt, t.id),
    index('watch_movie_latest')
      .on(t.titleId, t.recordedAt, t.id)
      .where(sql`${t.revokedAt} IS NULL AND ${t.episodeId} IS NULL`),
    foreignKey({
      columns: [t.episodeId, t.titleId],
      foreignColumns: [episodes.id, episodes.titleId]
    }).onDelete('cascade'),
    check('watch_origin_valid', sql`${t.origin} IN ('manual','import','trakt')`),
    check('watch_positive_version', sql`${t.version}>0`)
  ]
);

// Record no-op watches too: retrying one after an unwatch must not recreate history.
export const watchOperations = sqliteTable(
  'watch_operations',
  {
    operationId: text('operation_id').primaryKey(),
    titleId: text('title_id')
      .notNull()
      .references(() => titles.id, { onDelete: 'cascade' }),
    episodeId: text('episode_id'),
    watchedAt: text('watched_at'),
    rewatch: integer('rewatch', { mode: 'boolean' }).notNull(),
    resultEventId: text('result_event_id')
      .notNull()
      .references(() => watchEvents.id, { onDelete: 'cascade' }),
    createdAt: text('created_at').notNull()
  },
  (t) => [
    foreignKey({
      columns: [t.episodeId, t.titleId],
      foreignColumns: [episodes.id, episodes.titleId]
    }).onDelete('cascade'),
    check('watch_operation_rewatch_boolean', sql`${t.rewatch} IN (0,1)`),
    // Cascading deletes of a title, watch or episode must not scan every receipt.
    index('watch_operations_title').on(t.titleId),
    index('watch_operations_result').on(t.resultEventId),
    index('watch_operations_episode').on(t.episodeId, t.titleId)
  ]
);

export const scannerDevices = sqliteTable('scanner_devices', {
  id: text('id').primaryKey(),
  name: text('name').notNull(),
  credentialHash: text('credential_hash').notNull(),
  createdAt: text('created_at').notNull(),
  revokedAt: text('revoked_at')
});

export const fileLocations = sqliteTable(
  'file_locations',
  {
    id: text('id').primaryKey(),
    titleId: text('title_id')
      .notNull()
      .references(() => titles.id, { onDelete: 'cascade' }),
    deviceId: text('device_id')
      .notNull()
      .references(() => scannerDevices.id),
    volumeId: text('volume_id').notNull(),
    driveLetter: text('drive_letter').notNull(),
    root: text('root').notNull(),
    relativePath: text('relative_path').notNull(),
    seasonId: text('season_id'),
    fileCount: integer('file_count').notNull().default(0),
    sizeBytes: integer('size_bytes'),
    evidence: text('evidence', { enum: ['present', 'missing', 'unavailable', 'unverified'] })
      .notNull()
      .default('unverified'),
    checkedAt: text('checked_at')
  },
  (t) => [
    uniqueIndex('location_identity').on(t.deviceId, t.volumeId, t.root, t.relativePath),
    index('location_title').on(t.titleId, t.evidence),
    foreignKey({ columns: [t.seasonId, t.titleId], foreignColumns: [seasons.id, seasons.titleId] }),
    check('location_count_positive', sql`${t.fileCount} >= 0`),
    check('location_size_positive', sql`${t.sizeBytes} IS NULL OR ${t.sizeBytes} >= 0`),
    check(
      'location_evidence_valid',
      sql`${t.evidence} IN ('present','missing','unavailable','unverified')`
    )
  ]
);

export const scanRuns = sqliteTable(
  'scan_runs',
  {
    id: text('id').primaryKey(),
    deviceId: text('device_id')
      .notNull()
      .references(() => scannerDevices.id),
    startedAt: text('started_at').notNull(),
    completedAt: text('completed_at'),
    coverage: text('coverage', { mode: 'json' })
      .$type<{ volumeId: string; root: string; complete: boolean }[]>()
      .notNull(),
    status: text('status', { enum: ['receiving', 'complete', 'partial', 'failed'] }).notNull()
  },
  (t) => [index('scans_device').on(t.deviceId, t.startedAt)]
);

export const syncJobs = sqliteTable(
  'sync_jobs',
  {
    id: text('id').primaryKey(),
    dedupeKey: text('dedupe_key').notNull(),
    provider: text('provider').notNull(),
    kind: text('kind').notNull(),
    payload: text('payload', { mode: 'json' }).$type<Record<string, unknown>>().notNull(),
    state: text('state', { enum: ['pending', 'leased', 'complete', 'failed'] })
      .notNull()
      .default('pending'),
    attempts: integer('attempts').notNull().default(0),
    availableAt: text('available_at').notNull(),
    leaseUntil: text('lease_until'),
    lastError: text('last_error')
  },
  (t) => [
    uniqueIndex('sync_dedupe').on(t.dedupeKey),
    index('sync_due').on(t.state, t.availableAt, t.id)
  ]
);

/** Scanner candidates stay outside titles until an owner explicitly resolves them. */
export const unmatchedScans = sqliteTable(
  'unmatched_scans',
  {
    id: text('id').primaryKey(),
    deviceId: text('device_id')
      .notNull()
      .references(() => scannerDevices.id),
    volumeId: text('volume_id').notNull(),
    driveLetter: text('drive_letter').notNull(),
    root: text('root').notNull(),
    relativePath: text('relative_path').notNull(),
    name: text('name').notNull(),
    seasonNumber: integer('season_number'),
    fileCount: integer('file_count').notNull(),
    sizeBytes: integer('size_bytes'),
    checkedAt: text('checked_at').notNull(),
    version: integer('version').notNull().default(1),
    state: text('state', { enum: ['pending', 'matched'] })
      .notNull()
      .default('pending'),
    matchedTitleId: text('matched_title_id').references(() => titles.id, { onDelete: 'set null' })
  },
  (t) => [
    uniqueIndex('unmatched_location_identity').on(t.deviceId, t.volumeId, t.root, t.relativePath),
    index('unmatched_pending').on(t.state, t.id),
    index('unmatched_matched_title').on(t.matchedTitleId),
    check('unmatched_valid_count', sql`${t.fileCount} >= 0`),
    check('unmatched_valid_version', sql`${t.version} > 0`),
    check('unmatched_valid_state', sql`${t.state} IN ('pending','matched')`)
  ]
);

/** Server-only OAuth material is encrypted with a Worker secret, never serialized to a page. */
export const traktConnections = sqliteTable('trakt_connections', {
  id: text('id').primaryKey(),
  accountId: text('account_id'),
  username: text('username'),
  clientId: text('client_id').notNull(),
  ciphertext: text('ciphertext'),
  expiresAt: integer('expires_at'),
  state: text('state', { enum: ['connected', 'reauth', 'disconnected'] }).notNull(),
  version: integer('version').notNull().default(1),
  lease: text('lease'),
  leaseUntil: integer('lease_until'),
  updatedAt: text('updated_at').notNull(),
  lastSyncAt: text('last_sync_at')
});
export const traktOauthSessions = sqliteTable('trakt_oauth_sessions', {
  id: text('id').primaryKey(),
  owner: text('owner').notNull(),
  verifier: text('verifier').notNull(),
  redirectUri: text('redirect_uri').notNull(),
  expiresAt: integer('expires_at').notNull()
});

/** Opt-in scheduled incoming watches; never an outgoing/full-sync configuration. */
export const traktIncoming = sqliteTable(
  'trakt_incoming',
  {
    id: text('id').primaryKey(),
    accountId: text('account_id').notNull(),
    clientId: text('client_id').notNull(),
    enabled: integer('enabled', { mode: 'boolean' }).notNull().default(false),
    generation: integer('generation').notNull().default(1),
    lease: text('lease'),
    leaseUntil: integer('lease_until'),
    nextAt: integer('next_at').notNull().default(0),
    failures: integer('failures').notNull().default(0),
    activity: text('activity'),
    scanActivity: text('scan_activity'),
    scanStart: text('scan_start'),
    scanEnd: text('scan_end'),
    page: integer('page').notNull().default(1),
    checkedAt: text('checked_at'),
    importedAt: text('imported_at'),
    error: text('error'),
    budgetDay: text('budget_day').notNull().default(''),
    budgetUsed: integer('budget_used').notNull().default(0)
  },
  (t) => [
    check('incoming_singleton', sql`${t.id}='trakt'`),
    check('incoming_enabled', sql`${t.enabled} IN (0,1)`),
    check('incoming_page_range', sql`${t.page} BETWEEN 1 AND 201`)
  ]
);

/** Retained acknowledgements survive local history/Trash purge to prevent revival. */
export const traktIncomingRemoved = sqliteTable(
  'trakt_incoming_removed',
  {
    kind: text('kind').notNull(),
    externalId: text('external_id').notNull()
  },
  (t) => [primaryKey({ columns: [t.kind, t.externalId] })]
);

export const traktIncomingHistory = sqliteTable(
  'trakt_incoming_history',
  {
    accountId: text('account_id').notNull(),
    remoteId: text('remote_id').notNull(),
    payload: text('payload').notNull(),
    state: text('state', { enum: ['pending', 'complete', 'review'] })
      .notNull()
      .default('pending'),
    nextAt: integer('next_at').notNull().default(0),
    priority: integer('priority').notNull().default(0),
    reason: text('reason'),
    createdAt: text('created_at').notNull()
  },
  (t) => [
    primaryKey({ columns: [t.accountId, t.remoteId] }),
    index('trakt_incoming_due').on(t.accountId, t.state, t.nextAt, t.priority, t.remoteId),
    check('incoming_history_state', sql`${t.state} IN ('pending','complete','review')`)
  ]
);
export const traktSyncRuns = sqliteTable(
  'trakt_sync_runs',
  {
    id: text('id').primaryKey(),
    accountId: text('account_id').notNull(),
    state: text('state', {
      enum: ['building', 'review', 'applying', 'complete', 'failed', 'cancelled']
    }).notNull(),
    stage: text('stage').notNull(),
    page: integer('page').notNull().default(1),
    createdAt: text('created_at').notNull(),
    updatedAt: text('updated_at').notNull(),
    lease: text('lease'),
    leaseUntil: integer('lease_until'),
    error: text('error'),
    ratingMode: text('rating_mode').notNull(),
    progress: integer('progress').notNull().default(0),
    planAfter: text('plan_after')
  },
  (t) => [
    index('trakt_runs_recent').on(t.createdAt, t.id),
    index('trakt_runs_account_created').on(t.accountId, t.createdAt, t.id),
    uniqueIndex('trakt_one_active_run')
      .on(t.accountId)
      .where(sql`${t.state} IN ('building','review','applying')`)
  ]
);
export const traktRemoteItems = sqliteTable(
  'trakt_remote_items',
  {
    id: text('id').primaryKey(),
    runId: text('run_id')
      .notNull()
      .references(() => traktSyncRuns.id, { onDelete: 'cascade' }),
    kind: text('kind').notNull(),
    remoteKey: text('remote_key').notNull(),
    payload: text('payload', { mode: 'json' }).$type<Record<string, unknown>>().notNull()
  },
  (t) => [
    uniqueIndex('trakt_remote_run_key').on(t.runId, t.kind, t.remoteKey),
    index('trakt_remote_plan_order')
      .on(t.runId, t.id)
      .where(sql`kind!='activities'`),
    // Planning's "was this watchlist title already watched on Trakt" check within one run.
    index('trakt_remote_history_tmdb')
      .on(t.runId, sql`json_extract(payload,'$.tmdbId')`)
      .where(sql`kind='history'`)
  ]
);
export const traktSyncBaselines = sqliteTable(
  'trakt_sync_baselines',
  {
    id: text('id').primaryKey(),
    accountId: text('account_id').notNull(),
    kind: text('kind').notNull(),
    localKey: text('local_key').notNull(),
    remoteKey: text('remote_key'),
    localValue: text('local_value'),
    remoteValue: text('remote_value'),
    updatedAt: text('updated_at').notNull()
  },
  (t) => [
    uniqueIndex('trakt_baseline_local').on(t.accountId, t.kind, t.localKey),
    index('trakt_baseline_remote').on(t.accountId, t.kind, t.remoteKey)
  ]
);
export const traktSyncChanges = sqliteTable(
  'trakt_sync_changes',
  {
    id: text('id').primaryKey(),
    runId: text('run_id')
      .notNull()
      .references(() => traktSyncRuns.id, { onDelete: 'cascade' }),
    kind: text('kind').notNull(),
    direction: text('direction', { enum: ['pull', 'push', 'link', 'conflict'] }).notNull(),
    name: text('name').notNull(),
    detail: text('detail').notNull(),
    payload: text('payload', { mode: 'json' }).$type<Record<string, unknown>>().notNull(),
    review: integer('review', { mode: 'boolean' }).notNull().default(false),
    state: text('state', { enum: ['pending', 'applied', 'skipped', 'failed', 'uncertain'] })
      .notNull()
      .default('pending'),
    error: text('error')
  },
  (t) => [
    index('trakt_changes_run').on(t.runId, t.state, t.id),
    index('trakt_changes_ready_pick')
      .on(
        t.runId,
        sql`CASE WHEN kind='history' AND direction='pull' THEN 0 WHEN direction='link' THEN 1 WHEN kind='rating' THEN 2 ELSE 3 END`,
        t.id
      )
      .where(sql`state='pending' AND review=0`),
    // Unconfirmed sends are rare; this keeps their guard lookups off a full-table scan.
    index('trakt_changes_unconfirmed')
      .on(sql`json_extract(payload,'$.localEventId')`)
      .where(sql`kind='history' AND json_extract(payload,'$.sentUnconfirmed')=1`),
    // Planning's "already proposed for this local play" check within one run.
    index('trakt_changes_local_event')
      .on(t.runId, sql`json_extract(payload,'$.localEventId')`)
      .where(sql`kind='history'`)
  ]
);

/** Trigger-maintained aggregates; never updated outside proposal transactions. */
export const traktSyncChangeCounts = sqliteTable(
  'trakt_sync_change_counts',
  {
    runId: text('run_id')
      .notNull()
      .references(() => traktSyncRuns.id, { onDelete: 'cascade' }),
    state: text('state').notNull(),
    review: integer('review', { mode: 'boolean' }).notNull(),
    direction: text('direction').notNull(),
    amount: integer('amount').notNull().default(0)
  },
  (t) => [
    primaryKey({ columns: [t.runId, t.state, t.review, t.direction] }),
    check('trakt_count_nonnegative', sql`${t.amount} >= 0`)
  ]
);

/** Durable receipts keep a status/progress change and its Undo safe to retry. */
export const progressOperations = sqliteTable('progress_operations', {
  id: text('id').primaryKey(),
  attempt: text('attempt').notNull(),
  input: text('input').notNull(),
  payload: text('payload').notNull(),
  createdAt: text('created_at').notNull()
});
