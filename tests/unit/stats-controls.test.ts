import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import {
  diaryStats,
  statsPeriods,
  statsRanges,
  normalizeStatsPeriod
} from '../../src/lib/domain/stats.ts';
import { localDate } from '../../src/lib/domain/history.ts';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';

async function controls() {
  const file = await readFile(
    new URL('../../src/lib/components/StatsDashboard.svelte', import.meta.url),
    'utf8'
  );
  const source = stripTypeScriptTypes(
    file.match(/<script lang="ts">([\s\S]*?)<\/script>/)![1]!.replace(/\s*import\s[\s\S]*?;/g, '')
  );
  let memory!: {
    capture: () => { period: string; year: number | null; selected: number | null };
    restore: (value: unknown) => void;
  };
  let navigate!: (navigation: { type: string; to: { url: URL } }) => void;
  const derived = Object.assign((value: unknown) => value, { by: (get: () => unknown) => get() });
  const controller = runInNewContext(
    source +
      '\n({ choose, read:()=>({period,year,selected}), setYear:(value)=>year=value, select:(value)=>selected=value, setChart:(value)=>chart=value });',
    {
      $state: (value: unknown) => value,
      $derived: derived,
      useDiary: () => ({ snapshot: sampleDiary() }),
      diaryStats,
      normalizeStatsPeriod,
      statsPeriods,
      statsRanges,
      localDate,
      onMount: () => {},
      afterNavigate: (callback: typeof navigate) => {
        navigate = callback;
      },
      rememberView: (
        _id: string,
        capture: typeof memory.capture,
        restore: typeof memory.restore
      ) => {
        memory = { capture, restore };
      }
    }
  );
  return { controller, memory, navigate };
}

test('Stats starts on Today and Home links override remembered periods while back retains them', async () => {
  const { controller, navigate } = await controls();
  assert.equal(controller.read().period, 'today');
  controller.choose('month');
  controller.select(3);
  navigate({
    type: 'goto',
    to: { url: new URL('https://example.test/preview/activity?period=today') }
  });
  assert.equal(controller.read().period, 'today');
  assert.equal(controller.read().selected, null);
  controller.choose('year');
  navigate({
    type: 'popstate',
    to: { url: new URL('https://example.test/preview/activity?period=today') }
  });
  assert.equal(controller.read().period, 'year');
  navigate({
    type: 'goto',
    to: { url: new URL('https://example.test/preview/activity?period=invalid') }
  });
  assert.equal(controller.read().period, 'year');
});

test('the shipped control handler shares one selection, resets bar details, and preserves historical year', async () => {
  const { controller, memory } = await controls();
  const chart = { scrollLeft: 140 };
  controller.setChart(chart);
  controller.setYear(2024);
  for (const value of ['week', 'month', '90d', 'year', 'all', 'today']) {
    controller.select(3);
    controller.choose(value);
    assert.equal(controller.read().period, value);
    assert.equal(controller.read().selected, null);
    assert.equal(controller.read().year, 2024);
    assert.equal(chart.scrollLeft, 0);
    assert.equal(memory.capture().period, value);
    const row = statsRanges.find((range) => range.value === value);
    if (value !== 'today')
      assert.ok(row, 'Every existing quick choice matches the same canonical dropdown state');
  }
});

test('returning Stats pages upgrade saved 7D/30D/1Y states without losing year or expansion state', async () => {
  const { controller, memory } = await controls();
  for (const [before, after] of [
    ['7d', 'week'],
    ['30d', 'month'],
    ['1y', 'year']
  ]) {
    memory.restore({
      period: before,
      year: 2024,
      selected: 2,
      expandedGenres: true,
      progressLimit: 10,
      staleLimit: 4
    });
    assert.equal(controller.read().period, after);
    assert.equal(controller.read().year, 2024);
    assert.equal(
      controller.read().selected,
      null,
      "A migrated range must not select the old range's different date"
    );
  }
  memory.restore({
    period: 'year',
    year: 2024,
    selected: 2,
    expandedGenres: true,
    progressLimit: 10,
    staleLimit: 4
  });
  assert.equal(
    controller.read().selected,
    2,
    'An unchanged calendar view retains its selected month'
  );
});
