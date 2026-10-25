import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';
import {
  applyScanEvidence,
  availability,
  locationPath,
  serverAvailability
} from '../../src/lib/domain/locations.ts';
const location = sampleDiary().locations[0]!;
const scan = {
  deviceId: location.deviceId,
  volumeId: location.volumeId,
  root: location.root,
  complete: true,
  connected: true,
  seenLocationIds: [] as string[],
  checkedAt: '2026-10-21T12:00:00Z'
};
test('only a complete matching root scan confirms missing', () => {
  assert.equal(applyScanEvidence(location, scan).evidence, 'missing');
  assert.equal(applyScanEvidence(location, { ...scan, complete: false }), location);
  assert.equal(applyScanEvidence(location, { ...scan, root: 'E:\\Different' }), location);
  assert.equal(applyScanEvidence(location, { ...scan, volumeId: 'different' }), location);
  assert.equal(applyScanEvidence(location, { ...scan, deviceId: 'other' }), location);
});
test('disconnect preserves last known path, count and checked date', () => {
  const offline = applyScanEvidence(location, { ...scan, connected: false });
  assert.equal(offline.evidence, 'unavailable');
  assert.equal(offline.checkedAt, location.checkedAt);
  assert.equal(offline.relativePath, location.relativePath);
  assert.equal(availability([offline]), 'unknown');
});
test('seen evidence is positive even when a scan is partial', () => {
  assert.equal(
    applyScanEvidence(location, { ...scan, complete: false, seenLocationIds: [location.id] })
      .evidence,
    'present'
  );
});
test('one available copy wins; missing plus unverified stays unknown', () => {
  assert.equal(availability([]), 'unknown');
  assert.equal(availability([{ ...location, evidence: 'missing' }]), 'missing');
  assert.equal(
    availability([
      { ...location, evidence: 'missing' },
      { ...location, evidence: 'unverified' }
    ]),
    'unknown'
  );
  assert.equal(availability([{ ...location, evidence: 'unavailable' }, location]), 'present');
});
test('path joining normalizes separators without losing drive identity', () => {
  assert.equal(
    locationPath({ ...location, root: 'E:/Media Server/', relativePath: '/Anime/Frieren' }),
    'E:\\Media Server\\Anime\\Frieren'
  );
});

test('server availability names every confirmed drive once, across seasons', () => {
  const locations = [
    { ...location, id: 'e1', driveLetter: 'E:', season: 1, evidence: 'present' as const },
    { ...location, id: 'd', driveLetter: 'd:', season: 2, evidence: 'present' as const },
    { ...location, id: 'e2', driveLetter: ' E: ', season: 3, evidence: 'present' as const },
    { ...location, id: 'f', driveLetter: 'F:', evidence: 'missing' as const },
    { ...location, id: 'g', driveLetter: 'G:', evidence: 'unavailable' as const }
  ];
  const original = structuredClone(locations);
  assert.deepEqual(serverAvailability(locations), {
    available: true,
    drives: ['D', 'E'],
    label: 'Available on Server: Drive D / Drive E'
  });
  assert.deepEqual(locations, original);
});

test('server availability never advertises missing, offline or unverified copies as available', () => {
  assert.deepEqual(serverAvailability([]), {
    available: false,
    drives: [],
    label: 'Not Available on Server'
  });
  for (const evidence of ['missing', 'unavailable', 'unverified'] as const)
    assert.equal(serverAvailability([{ ...location, evidence }]).label, 'Not Available on Server');
  assert.equal(
    serverAvailability([{ ...location, evidence: 'present', driveLetter: '' }]).label,
    'Available on Server'
  );
});
