<script lang="ts">
  import { untrack } from 'svelte';
  import { page } from '$app/state';
  import { rememberView } from '#lib/client/remember-view.svelte.ts';
  import { goto } from '#lib/client/navigation.ts';
  import TitleScreen from '#lib/screens/TitleScreen.svelte';
  import BrandMark from '#lib/components/BrandMark.svelte';
  import { requestJson, errorMessage } from '#lib/client/api.ts';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { tmdbImage, type MetadataBrowse, type MetadataSeason } from '#lib/metadata.ts';
  import type { MediaTitle, Episode } from '#lib/domain/types.ts';
  import type { SavedTitle } from '#lib/client/contracts.ts';
  import { celebrate } from '#lib/client/celebrate.ts';
  const diary = useDiary();
  let details = $state<MetadataBrowse | null>(null),
    rows = $state<Episode[]>([]),
    error = $state(''),
    seasonError = $state(''),
    seasonLoading = $state(false),
    addError = $state(''),
    busy = $state(false),
    retry = $state(0),
    loading = $state(false);
  let selected = -1,
    generation = 0;
  let loadedIdentity = '';
  let seasonController: AbortController | undefined;
  let lastReveal = false;
  const seasonCache = new Map<number, { rows: Episode[]; revealed: boolean }>();
  const identity = $derived(page.params.type + ':' + page.params.id);
  const title = $derived<MediaTitle | null>(
    details
      ? {
          id: 'online-' + identity,
          name: details.details.name,
          year: details.details.year,
          category: details.details.suggestedCategory,
          overview: details.details.overview,
          poster: tmdbImage(details.details.posterPath),
          backdrop: tmdbImage(details.details.backdropPath, 'w780'),
          communityScore: details.details.communityScore,
          tmdbId: details.details.id,
          genres: details.details.genres,
          runtimeMinutes: details.details.runtimeMinutes,
          status: 'planned',
          favorite: false,
          score: null,
          notes: '',
          tags: [],
          seasons: details.details.seasons.map((s) => ({ ...s, metadataLoadedAt: null }))
        }
      : null
  );
  const catalog = $derived(
    title ? { title, episodes: rows, trashed: details?.libraryTitle?.trashed ?? false } : null
  );
  $effect(() => {
    identity;
    retry;
    if (untrack(() => loadedIdentity === identity && !!details && !retry)) return;
    const controller = new AbortController();
    generation++;
    details = null;
    rows = [];
    error = '';
    seasonError = '';
    seasonLoading = false;
    addError = '';
    seasonCache.clear();
    loading = true;
    selected = -1;
    void requestJson<MetadataBrowse>(
      '/api/metadata/browse?' +
        new URLSearchParams({ type: page.params.type ?? '', id: page.params.id ?? '' }),
      { signal: controller.signal }
    )
      .then(async (value) => {
        if (controller.signal.aborted) return;
        if (value.libraryTitle && !value.libraryTitle.trashed) {
          await diary.refresh();
          if (!controller.signal.aborted)
            await goto('/preview/title/' + encodeURIComponent(value.libraryTitle.id), {
              replace: true
            });
          return;
        }
        details = value;
        loadedIdentity = identity;
        const season =
          value.details.seasons.find((s) => s.number > 0)?.number ??
          value.details.seasons[0]?.number;
        if (season !== undefined) void loadSeason(season);
      })
      .catch((cause) => {
        if (!controller.signal.aborted) error = errorMessage(cause);
      })
      .finally(() => {
        if (!controller.signal.aborted) loading = false;
      });
    return () => {
      controller.abort();
      seasonController?.abort();
    };
  });
  async function loadSeason(number: number, reveal = false, force = false) {
    const shouldReveal = reveal || !diary.hideSpoilers;
    if (number < 0 || (selected === number && !force && (!shouldReveal || lastReveal))) return;
    const current = ++generation;
    const previous = selected;
    selected = number;
    lastReveal = shouldReveal;
    seasonController?.abort();
    const cached = seasonCache.get(number);
    if (!force && cached && (cached.revealed || !shouldReveal)) {
      rows = cached.rows;
      seasonError = '';
      seasonLoading = false;
      return;
    }
    if (previous !== number) rows = cached?.rows ?? [];
    const controller = new AbortController();
    seasonController = controller;
    seasonError = '';
    seasonLoading = true;
    try {
      const result = await requestJson<MetadataSeason>(
        '/api/metadata/season?' +
          new URLSearchParams({
            type: page.params.type ?? '',
            id: page.params.id ?? '',
            season: String(number),
            reveal: shouldReveal ? '1' : '0'
          }),
        { signal: controller.signal }
      );
      if (current !== generation || controller.signal.aborted) return;
      rows = result.items.map((e) => ({
        id: 'online-s' + number + 'e' + e.number,
        titleId: 'online-' + identity,
        season: number,
        number: e.number,
        name: e.name,
        overview: e.overview,
        airedOn: e.airedOn,
        still: tmdbImage(e.stillPath),
        communityScore: e.communityScore ?? null
      }));
      seasonCache.set(number, { rows, revealed: shouldReveal });
    } catch (cause) {
      if (current === generation && !controller.signal.aborted) {
        seasonError = errorMessage(cause);
      }
    } finally {
      if (current === generation && !controller.signal.aborted) seasonLoading = false;
    }
  }
  async function add() {
    if (!details || busy) return;
    busy = true;
    addError = '';
    const current = identity;
    try {
      const saved = await requestJson<{ title: SavedTitle }>('/api/metadata/import', {
        method: 'POST',
        body: JSON.stringify({
          mediaType: details.details.mediaType,
          tmdbId: details.details.id,
          category: details.details.suggestedCategory,
          status: 'planned',
          score: null
        })
      });
      celebrate();
      await diary.refresh();
      if (current === identity)
        await goto('/preview/title/' + encodeURIComponent(saved.title.id), { replace: true });
    } catch (cause) {
      if (current === identity) addError = errorMessage(cause);
    } finally {
      busy = false;
    }
  }
  rememberView(
    'catalog-view',
    () => ({ details, rows, selected, lastReveal, loadedIdentity, seasons: [...seasonCache] }),
    (saved) => {
      details = saved.details;
      rows = saved.rows;
      selected = saved.selected;
      lastReveal = saved.lastReveal;
      loadedIdentity = saved.loadedIdentity;
      seasonCache.clear();
      for (const [number, cached] of saved.seasons) seasonCache.set(number, cached);
    }
  );
</script>

{#if loading}<div class="loading" role="status">
    <BrandMark size={30} loading />Loading title…
  </div>{/if}
{#if error}<div class="notice" role="alert">
    <p>{error}</p>
    <button class="button" onclick={() => retry++}>Retry</button>
  </div>{/if}
{#if catalog}<TitleScreen
    {catalog}
    onadd={add}
    adding={busy}
    {addError}
    episodeError={seasonError}
    episodeLoading={seasonLoading}
    onretryseason={() => void loadSeason(selected, lastReveal, true)}
    onseason={(number) => void loadSeason(number)}
    onreveal={() => void loadSeason(selected, true)}
  />{/if}

<style>
  .loading {
    min-height: 35vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 14px;
    color: var(--secondary);
  }
</style>
