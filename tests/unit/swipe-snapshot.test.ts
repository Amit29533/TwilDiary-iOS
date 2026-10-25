import { test } from 'node:test';
import assert from 'node:assert/strict';
import { preserveSwipeSnapshot } from '../../src/lib/client/swipe-snapshot.ts';

test('iPhone and both iPad user agents keep departing history entries eligible for native snapshots', () => {
  for (const agent of [
    {
      userAgent:
        'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Version/26.0 Mobile Safari/604.1',
      maxTouchPoints: 5
    },
    {
      userAgent:
        'Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile Safari/604.1',
      maxTouchPoints: 5
    },
    {
      userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) AppleWebKit/605.1.15 Version/26.0 Safari/605.1.15',
      maxTouchPoints: 5
    },
    {
      userAgent:
        'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 CriOS/140.0 Mobile Safari/604.1',
      maxTouchPoints: 5
    }
  ]) {
    const session = { scrollRestoration: 'manual' as ScrollRestoration };
    preserveSwipeSnapshot(agent, session);
    assert.equal(session.scrollRestoration, 'auto');
    // Subsequent navigation remains idempotent; no history entry or scroll mutation.
    preserveSwipeSnapshot(agent, session);
    assert.deepEqual(session, { scrollRestoration: 'auto' });
  }
});

test('other browsers retain the framework scroll restoration mode', () => {
  for (const agent of [
    {
      userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) AppleWebKit/605.1.15 Version/26.0 Safari/605.1.15',
      maxTouchPoints: 0
    },
    {
      userAgent:
        'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 Chrome/140.0 Mobile Safari/537.36',
      maxTouchPoints: 5
    },
    {
      userAgent:
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/140.0 Safari/537.36',
      maxTouchPoints: 0
    },
    {
      userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0) Gecko/1.0 AlternativeEngine/1.0',
      maxTouchPoints: 5
    }
  ]) {
    const session = { scrollRestoration: 'manual' as ScrollRestoration };
    preserveSwipeSnapshot(agent, session);
    assert.equal(session.scrollRestoration, 'manual');
  }
});
