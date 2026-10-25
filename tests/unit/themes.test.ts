import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { themes, themeId, readTheme, writeTheme, THEME_KEY } from '../../src/lib/domain/themes.ts';

test('only known appearance IDs are restored; corrupt or denied storage is harmless', () => {
  for (const theme of themes) {
    assert.equal(themeId(theme.id), theme.id);
    assert.equal(readTheme({ getItem: () => theme.id }), theme.id);
  }
  for (const value of [null, undefined, '', '__proto__', 'constructor', '<style>', {}, 1])
    assert.equal(themeId(value), 'twilight');
  assert.equal(
    readTheme({
      getItem() {
        throw new Error('denied');
      }
    }),
    'twilight'
  );
});

test('saving appearance touches only its dedicated key and tolerates blocked storage', () => {
  const calls: string[][] = [];
  assert.equal(
    writeTheme(
      {
        setItem(key, value) {
          calls.push([key, value]);
        }
      },
      'glass'
    ),
    true
  );
  assert.deepEqual(calls, [[THEME_KEY, 'glass']]);
  assert.equal(
    writeTheme(
      {
        setItem() {
          throw new Error('quota');
        }
      },
      'ocean'
    ),
    false
  );
});

const boot = readFileSync(new URL('../../static/theme-init.js', import.meta.url), 'utf8');
function bootTheme(saved: unknown, denied = false) {
  const dataset: Record<string, string> = {};
  runInNewContext(boot, {
    document: { documentElement: { dataset } },
    localStorage: {
      getItem(key: string) {
        assert.equal(key, THEME_KEY);
        if (denied) throw new Error('denied');
        return saved;
      }
    }
  });
  return dataset.theme;
}
test('the actual pre-paint script restores every theme before app initialization', () => {
  for (const theme of themes) assert.equal(bootTheme(theme.id), theme.id);
  assert.equal(bootTheme('__proto__'), 'twilight');
  assert.equal(bootTheme(null), 'twilight');
  assert.equal(bootTheme('glass', true), 'twilight');
});

function luminance(color: string) {
  const rgb = [1, 3, 5]
    .map((index) => parseInt(color.slice(index, index + 2), 16) / 255)
    .map((value) => (value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4));
  return rgb[0]! * 0.2126 + rgb[1]! * 0.7152 + rgb[2]! * 0.0722;
}
function contrast(a: string, b: string) {
  const values = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (values[0]! + 0.05) / (values[1]! + 0.05);
}
test('theme accents and button lettering meet normal-text contrast on their intended colors', () => {
  for (const theme of themes) {
    assert.ok(contrast(theme.accent, theme.canvas) >= 4.5, theme.id + ' accent on canvas');
    assert.ok(contrast(theme.ink, theme.accent) >= 4.5, theme.id + ' button label');
    assert.ok(contrast(theme.ink, theme.strong) >= 4.5, theme.id + ' gradient button label');
  }
});
