<script lang="ts">
  import { backLink } from '#lib/client/navigation.ts';
  import { rememberView } from '#lib/client/remember-view.svelte.ts';
  import { page } from '$app/state';
  import ArrowLeft from '@lucide/svelte/icons/arrow-left';
  import UserRound from '@lucide/svelte/icons/user-round';
  import { requestJson, errorMessage } from '#lib/client/api.ts';
  import { useDiary } from '#lib/client/diary-context.ts';
  import { personSections, personFilmographyPath, type PersonDetails } from '#lib/people.ts';
  import { cachedPerson, rememberPerson } from '#lib/client/person-cache.ts';
  import { tmdbImage } from '#lib/metadata.ts';
  import MetadataShelf from '#lib/components/MetadataShelf.svelte';
  import BrandMark from '#lib/components/BrandMark.svelte';
  const diary = useDiary();
  let person = $state<PersonDetails | null>(null),
    error = $state(''),
    retry = $state(0),
    expanded = $state(false),
    photoFailed = $state(false),
    heroFailed = $state(false);
  const sections = $derived(person ? personSections(person, diary.snapshot) : null);
  const hero = $derived(
    person?.profilePath ??
      sections?.knownFor.find((item) => item.backdropPath)?.backdropPath ??
      null
  );
  const back = $derived(
    /^\/preview\/(?:title\/[^/?#]+|discover\/(?:movie|tv)\/\d+)$/.test(
      page.url.searchParams.get('from') ?? ''
    )
      ? page.url.searchParams.get('from')!
      : '/preview'
  );
  const sourceTitle = $derived((page.url.searchParams.get('title') ?? '').slice(0, 300));
  const sourceRole = $derived((page.url.searchParams.get('role') ?? '').slice(0, 300));
  const firstCredit = $derived(
    person?.credits
      .filter(
        (item) =>
          item.mediaType === 'movie' &&
          item.year !== null &&
          item.year >= Number(person?.birthday?.slice(0, 4) ?? 0) &&
          item.year <= new Date().getFullYear()
      )
      .toSorted((a, b) => a.year! - b.year!)[0]
  );
  function formatDate(date: string) {
    return new Intl.DateTimeFormat('en-GB', {
      day: 'numeric',
      month: 'long',
      year: 'numeric',
      timeZone: 'UTC'
    }).format(new Date(date + 'T00:00:00Z'));
  }
  $effect(() => {
    const id = page.params.id ?? '';
    retry;
    person = null;
    error = '';
    expanded = false;
    photoFailed = false;
    heroFailed = false;
    const cached = cachedPerson(id);
    if (cached) {
      person = cached;
      return;
    }
    const controller = new AbortController();
    void requestJson<{ person: PersonDetails }>(
      '/api/metadata/person?' + new URLSearchParams({ id }),
      { signal: controller.signal }
    )
      .then((result) => {
        if (controller.signal.aborted) return;
        person = result.person;
        rememberPerson(result.person);
      })
      .catch((cause) => {
        if (!controller.signal.aborted) error = errorMessage(cause);
      });
    return () => controller.abort();
  });
  rememberView(
    'person-view',
    () => ({ expanded }),
    (saved) => {
      expanded = saved.expanded;
    }
  );
</script>

<svelte:head
  ><title>{person ? person.name + ' · TwilDiary' : 'Person · TwilDiary'}</title></svelte:head
>

<div class="person-page">
  <div class="person-toolbar">
    <a
      class="icon-button back"
      href={back}
      onclick={(event) => backLink(event)}
      data-sveltekit-replacestate
      aria-label="Back to title"><ArrowLeft size={24} /></a
    >
  </div>
  {#if person && sections}
    <header class="person-header">
      <div class="hero" aria-hidden="true">
        {#if hero && !heroFailed}<img
            src={tmdbImage(hero, 'w780')!}
            alt=""
            onerror={() => (heroFailed = true)}
            fetchpriority="high"
          />{/if}
      </div>
      <div class="identity">
        <div class="portrait">
          {#if person.profilePath && !photoFailed}<img
              src={tmdbImage(person.profilePath)!}
              alt={person.name}
              onerror={() => (photoFailed = true)}
            />{:else}<UserRound size={40} />{/if}
        </div>
        <div class="name">
          <h1>{person.name}</h1>
          {#if person.birthday}<p>
              Born {formatDate(person.birthday)}
            </p>{/if}{#if person.birthplace}<p>{person.birthplace}</p>{/if}
        </div>
      </div>
    </header>
    <div class="person-content">
      {#if sourceRole && sourceTitle}<a
          class="source-role"
          href={back}
          onclick={(event) => backLink(event)}
          data-sveltekit-replacestate>{sourceRole} in {sourceTitle}</a
        >{/if}
      {#if person.biography}<section class="bio" aria-label="Biography">
          <p class:collapsed={!expanded}>{person.biography}</p>
          <button class="text-link" aria-expanded={expanded} onclick={() => (expanded = !expanded)}
            >{expanded ? 'Less' : 'More'}</button
          >
        </section>{/if}

      <section class="facts">
        <div class="section-heading"><h2>Facts &amp; trivia</h2></div>
        <dl>
          {#if person.department}<div>
              <dt>Known for</dt>
              <dd>{person.department}</dd>
            </div>{/if}
          {#if person.birthplace}<div>
              <dt>Birthplace</dt>
              <dd>{person.birthplace}</dd>
            </div>{/if}
          {#if person.deathday}<div>
              <dt>Died</dt>
              <dd>{formatDate(person.deathday)}</dd>
            </div>{/if}
          {#if person.aliases.length}<div>
              <dt>Also known as</dt>
              <dd>{person.aliases.join(' · ')}</dd>
            </div>{/if}
          {#if firstCredit}<div>
              <dt>Earliest listed movie</dt>
              <dd>{firstCredit.name} · {firstCredit.year}</dd>
            </div>{/if}
          <div>
            <dt>Listed credits</dt>
            <dd>{sections.movies.length} movies · {sections.shows.length} shows</dd>
          </div>
        </dl>
      </section>
      <section aria-label="On your server">
        <div class="section-heading">
          <h2>On your server</h2>
          <a href={personFilmographyPath(person.id, 'credits', true)}>View more</a>
        </div>
        {#if sections.localShows.length}<div class="section-heading">
            <h3>Shows</h3>
            <a href={personFilmographyPath(person.id, 'shows', true)}>View more</a>
          </div>
          <MetadataShelf
            items={sections.localShows.slice(0, 12)}
            label="Shows on your disks"
            roles
          />{/if}
        {#if sections.localMovies.length}<div class="section-heading">
            <h3>Movies</h3>
            <a href={personFilmographyPath(person.id, 'movies', true)}>View more</a>
          </div>
          <MetadataShelf
            items={sections.localMovies.slice(0, 12)}
            label="Movies on your disks"
            roles
          />{/if}
        {#if !sections.localShows.length && !sections.localMovies.length}<p class="muted">
            None of these titles are on your disks yet.
          </p>{/if}
      </section>
      {#if sections.knownFor.length}<section>
          <div class="section-heading">
            <h2>Known for</h2>
            <a href={personFilmographyPath(person.id, 'known-for')}>View more</a>
          </div>
          <MetadataShelf
            items={sections.knownFor}
            label="Popular titles featuring this person"
            roles
          />
        </section>{/if}
      {#if sections.shows.length}<section>
          <div class="section-heading">
            <h2>Shows <span>{sections.shows.length}</span></h2>
            <a href={personFilmographyPath(person.id, 'shows')}>View more</a>
          </div>
          <MetadataShelf items={sections.shows.slice(0, 12)} label="Show credits" roles />
        </section>{/if}
      {#if sections.movies.length}<section>
          <div class="section-heading">
            <h2>Movies <span>{sections.movies.length}</span></h2>
            <a href={personFilmographyPath(person.id, 'movies')}>View more</a>
          </div>
          <MetadataShelf items={sections.movies.slice(0, 12)} label="Movie credits" roles />
        </section>{/if}

      <p class="attribution">
        Biography, credits and artwork: <a
          href="https://www.themoviedb.org/person/{person.id}"
          target="_blank"
          rel="noreferrer">TMDB</a
        >
      </p>
    </div>
  {:else if error}<div class="person-status" role="alert">
      <p>{error}</p>
      <button class="button" onclick={() => retry++}>Retry</button>
    </div>
  {:else}<div class="person-status" role="status" aria-label="Loading person">
      <BrandMark size={40} loading />
    </div>{/if}
</div>

<style>
  .person-page {
    --person-toolbar-height: 80px;
    position: relative;
    min-width: 0;
  }
  .person-toolbar {
    position: sticky;
    top: 0;
    z-index: 20;
    height: var(--person-toolbar-height);
    margin-bottom: calc(-1 * var(--person-toolbar-height));
    padding-top: 18px;
    pointer-events: none;
  }
  .back {
    pointer-events: auto;
    width: 44px;
    height: 44px;
    border-radius: 50%;
    background: #131416cc;
    border: 1px solid #ffffff25;
    backdrop-filter: blur(12px);
  }
  .person-header {
    position: relative;
    padding-top: 220px;
  }
  .hero {
    position: absolute;
    inset: 0 0 auto;
    height: 340px;
    border-radius: 18px 18px 0 0;
    overflow: hidden;
    background: radial-gradient(ellipse at top, #51426980, transparent 80%);
  }
  .hero::after {
    content: '';
    position: absolute;
    inset: 0;
    background: linear-gradient(0deg, var(--bg) 0%, #0007 45%, #0002);
  }
  .hero img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    object-position: center 25%;
  }
  .identity {
    position: relative;
    display: flex;
    align-items: end;
    gap: 18px;
    padding: 0 20px 14px;
  }
  .portrait {
    width: 108px;
    aspect-ratio: 1;
    border-radius: 50%;
    flex-shrink: 0;
    overflow: hidden;
    display: grid;
    place-items: center;
    background: var(--surface-2);
    border: 2px solid #ffffff24;
  }
  .portrait img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    object-position: center 20%;
  }
  .name {
    min-width: 0;
  }
  h1 {
    margin-bottom: 8px;
    font-size: clamp(1.7rem, 4vw, 2.7rem);
  }
  .name p {
    margin: 2px 0;
    color: var(--muted);
    font-size: 0.9375rem;
    line-height: 1.35;
  }
  .person-content {
    position: relative;
    padding: 20px 0 0;
  }
  .source-role {
    color: var(--accent);
    display: block;
    margin-bottom: 14px;
    font-size: 0.9375rem;
  }
  .bio p {
    color: var(--muted);
    white-space: pre-line;
    margin-bottom: 4px;
    line-height: 1.6;
  }
  .collapsed {
    display: -webkit-box;
    -webkit-line-clamp: 4;
    line-clamp: 4;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }
  section {
    margin-bottom: 28px;
    min-width: 0;
  }
  .section-heading {
    margin-bottom: 14px;
  }
  .section-heading h2 {
    font-size: 1.25rem;
  }
  h3 {
    font-size: 0.9375rem;
    color: var(--muted);
    font-weight: 500;
    margin: 12px 0;
  }
  h2 span {
    margin-left: 8px;
    font-size: 0.875rem;
    color: var(--muted);
    font-weight: 400;
  }
  .muted,
  .attribution {
    font-size: 0.8125rem;
    color: var(--muted);
  }
  dl {
    margin: 0;
    border: 1px solid #ffffff14;
    border-radius: 14px;
    padding: 4px 16px;
    background: #ffffff04;
  }
  dl div {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 2fr);
    gap: 16px;
    padding: 12px 0;
  }
  dl div + div {
    border-top: 1px solid #ffffff0c;
  }
  dt {
    color: var(--muted);
    font-size: 0.8125rem;
  }
  dd {
    margin: 0;
    font-size: 0.875rem;
    overflow-wrap: anywhere;
  }
  .attribution a {
    color: var(--accent);
  }
  .person-status {
    min-height: 60dvh;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 16px;
  }
  @media (max-width: 760px) {
    .person-page {
      --person-toolbar-height: calc(68px + env(safe-area-inset-top, 0px));
      margin-top: -12px;
    }
    .hero {
      left: -14px;
      right: -14px;
      border-radius: 0;
      height: 310px;
    }
    .person-header {
      padding-top: 205px;
    }
    .person-toolbar {
      padding-top: calc(12px + env(safe-area-inset-top, 0px));
    }
    .identity {
      gap: 14px;
      padding: 0 0 10px;
      align-items: center;
    }
    .portrait {
      width: 80px;
    }
    h1 {
      font-size: 1.65rem;
    }
    .name p {
      font-size: 0.8125rem;
    }
    .person-content {
      padding-top: 18px;
    }
  }
</style>
