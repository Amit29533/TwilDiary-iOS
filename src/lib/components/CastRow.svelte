<script module lang="ts">
  import type { CastMember } from '#lib/domain/types.ts';
  const creditsCache = new Map<string, { cast: CastMember[]; expires: number }>();
</script>

<script lang="ts">
  import UserRound from '@lucide/svelte/icons/user-round';
  import { requestJson, errorMessage } from '#lib/client/api.ts';
  import { tmdbImage } from '#lib/metadata.ts';
  import { page } from '$app/state';
  let {
    id,
    mediaType,
    titleName = ''
  }: { id?: number | null; mediaType: 'movie' | 'tv'; titleName?: string } = $props();
  let cast = $state<CastMember[]>([]),
    loading = $state(false),
    error = $state(''),
    retry = $state(0);
  let broken = $state<number[]>([]);
  $effect(() => {
    const providerId = id;
    const type = mediaType;
    retry;
    cast = [];
    error = '';
    broken = [];
    loading = false;
    if (!providerId) return;
    const key = `${type}:${providerId}`;
    const cached = creditsCache.get(key);
    if (cached && cached.expires > Date.now()) {
      cast = cached.cast;
      return;
    }
    const controller = new AbortController();
    loading = true;
    void requestJson<{ cast: CastMember[] }>(
      '/api/metadata/cast?' + new URLSearchParams({ type, id: String(providerId) }),
      { signal: controller.signal }
    )
      .then((result) => {
        if (controller.signal.aborted) return;
        cast = result.cast;
        if (creditsCache.size >= 64) creditsCache.delete(creditsCache.keys().next().value!);
        creditsCache.set(key, { cast: result.cast, expires: Date.now() + 15 * 60000 });
      })
      .catch((cause) => {
        if (!controller.signal.aborted) error = errorMessage(cause);
      })
      .finally(() => {
        if (!controller.signal.aborted) loading = false;
      });
    return () => controller.abort();
  });
</script>

{#if id && (loading || error || cast.length)}
  <section class="cast-section" aria-label="Cast">
    <div class="section-heading"><h2>Cast</h2></div>
    {#if loading}
      <div class="cast-track" aria-label="Loading cast" aria-busy="true">
        {#each [1, 2, 3] as item (item)}<div class="cast-member skeleton" aria-hidden="true">
            <span class="portrait"></span><span class="skeleton-name"></span>
          </div>{/each}
      </div>
    {:else if error}
      <div class="cast-error">
        <span>Cast couldn’t load.</span><button class="text-link" onclick={() => retry++}
          >Retry</button
        >
      </div>
    {:else}
      <ul class="cast-track" aria-label="Actors and characters">
        {#each cast as actor (actor.id)}
          <li class="cast-member">
            <a
              class="cast-link"
              href={'/preview/person/' +
                actor.id +
                '?' +
                new URLSearchParams({
                  from: page.url.pathname,
                  title: titleName,
                  role: actor.character
                })}
              aria-label="About {actor.name}"
            >
              <span class="portrait">
                {#if tmdbImage(actor.profilePath, 'w185') && !broken.includes(actor.id)}
                  <img
                    src={tmdbImage(actor.profilePath, 'w185')!}
                    alt=""
                    width="96"
                    height="96"
                    loading="lazy"
                    decoding="async"
                    onerror={() => (broken = [...broken, actor.id])}
                  />
                {:else}<UserRound size={30} strokeWidth={1.3} />{/if}
              </span>
              <strong title={actor.name}>{actor.name}</strong>
              {#if actor.character}<span class="character" title={actor.character}
                  >{actor.character}</span
                >{/if}
            </a>
          </li>
        {/each}
      </ul>
    {/if}
  </section>
{/if}

<style>
  .cast-section {
    margin-top: 10px;
    min-width: 0;
    grid-column: 1 / -1;
  }
  .section-heading {
    margin: 0 0 14px;
  }
  .cast-track {
    display: flex;
    gap: var(--poster-gap);
    max-width: 100%;
    overflow-x: auto;
    overscroll-behavior-x: contain;
    scroll-snap-type: x proximity;
    padding: 0 0 12px;
    margin: 0;
    list-style: none;
    scrollbar-width: thin;
  }
  .cast-member {
    flex: 0 0 var(--poster-width);
    min-width: 0;
    text-align: center;
    scroll-snap-align: start;
  }
  .cast-link {
    display: block;
    border-radius: 12px;
  }
  .cast-link,
  .cast-link img {
    -webkit-touch-callout: none;
    -webkit-user-select: none;
    user-select: none;
    -webkit-user-drag: none;
  }
  .cast-link .portrait {
    transition:
      transform 180ms ease,
      border-color 180ms ease;
  }
  @media (hover: hover) and (pointer: fine) {
    .cast-link:hover .portrait {
      border-color: var(--accent);
    }
  }
  .cast-link:active .portrait {
    transform: scale(0.94);
  }
  @media (prefers-reduced-motion: reduce) {
    .cast-link .portrait {
      transition: none;
    }
  }
  .portrait {
    display: grid;
    place-items: center;
    width: min(96px, 100%);
    aspect-ratio: 1;
    border-radius: 50%;
    overflow: hidden;
    margin: 0 auto 10px;
    background: linear-gradient(145deg, #272431, #141319);
    border: 1px solid #ffffff16;
    color: var(--muted);
  }
  img {
    width: 100%;
    height: 100%;
    display: block;
    object-fit: cover;
    object-position: center 25%;
  }
  strong,
  .character {
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    overflow: hidden;
    overflow-wrap: anywhere;
    line-height: 1.35;
  }
  strong {
    font-size: 0.875rem;
    font-weight: 550;
  }
  .character {
    color: var(--muted);
    font-size: 0.8125rem;
    margin-top: 5px;
  }
  .cast-error {
    display: flex;
    align-items: center;
    gap: 12px;
    font-size: 0.8125rem;
    color: var(--muted);
  }
  .skeleton .portrait,
  .skeleton-name {
    background: var(--surface-2);
    animation: breathe 1.2s ease-in-out infinite alternate;
  }
  .skeleton-name {
    display: block;
    width: 70%;
    height: 12px;
    margin: auto;
    border-radius: 4px;
  }
  @keyframes breathe {
    to {
      opacity: 0.4;
    }
  }
  @media (max-width: 600px) {
    .portrait {
      width: min(88px, 100%);
    }
    .cast-track {
      scrollbar-width: none;
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .skeleton .portrait,
    .skeleton-name {
      animation: none;
    }
  }
</style>
