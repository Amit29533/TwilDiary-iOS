import type { FileLocation, WatchStatus } from './types.ts';

/** Owner-specified drive shortcuts; these labels never imply a completed scan. */
export const homeDisks = [
  { key: 'drive:E:', label: 'E: Toshiba (4TB)' },
  { key: 'drive:F:', label: 'F: Legion (1TB)' },
  { key: 'drive:G:', label: 'G: Seagate (1TB)' }
] as const;
export const driveLabel = (key: string) => homeDisks.find((disk) => disk.key === key)?.label;

/** Disconnected/uncertain copies require verification rather than another download. */
export function needsDownload(status: WatchStatus, locations: readonly FileLocation[]): boolean {
  return (
    (status === 'planned' || status === 'watching') &&
    (locations.length === 0 || locations.every((location) => location.evidence === 'missing'))
  );
}

/** Device + volume is stable when a Windows drive letter changes. */
export const diskKey = (location: Pick<FileLocation, 'deviceId' | 'volumeId'>) =>
  JSON.stringify([location.deviceId, location.volumeId]);
export interface DiskSummary {
  key: string;
  deviceName: string;
  letters: string[];
  titleCount: number;
  folders: number;
  present: number;
  unavailable: number;
  missing: number;
  unverified: number;
  checkedAt: string | null;
}
export function summarizeDisks(locations: readonly FileLocation[]): DiskSummary[] {
  const groups = new Map<string, DiskSummary>();
  const titleIds = new Map<string, Set<string>>();
  for (const location of locations) {
    const key = diskKey(location);
    let disk = groups.get(key);
    if (!disk) {
      disk = {
        key,
        deviceName: location.deviceName,
        letters: [],
        titleCount: 0,
        folders: 0,
        present: 0,
        unavailable: 0,
        missing: 0,
        unverified: 0,
        checkedAt: null
      };
      groups.set(key, disk);
      titleIds.set(key, new Set());
    }
    if (!disk.letters.includes(location.driveLetter)) disk.letters.push(location.driveLetter);
    titleIds.get(key)!.add(location.titleId);
    disk.titleCount = titleIds.get(key)!.size;
    disk.folders++;
    disk[location.evidence]++;
    if (location.checkedAt && (!disk.checkedAt || location.checkedAt > disk.checkedAt))
      disk.checkedAt = location.checkedAt;
  }
  return [...groups.values()].sort(
    (a, b) =>
      a.deviceName.localeCompare(b.deviceName) ||
      a.letters.join().localeCompare(b.letters.join()) ||
      a.key.localeCompare(b.key)
  );
}
export function diskEvidence(disk: DiskSummary) {
  if (disk.present) return `${disk.present} confirmed folder${disk.present === 1 ? '' : 's'}`;
  if (disk.unavailable === disk.folders) return 'Disconnected · mappings kept';
  if (disk.missing === disk.folders) return 'Files confirmed missing';
  return 'Availability not confirmed';
}
export function titlesOnDisk(locations: readonly FileLocation[], selected: string): Set<string> {
  return new Set(
    locations
      .filter(
        (location) =>
          selected === 'mapped' ||
          diskKey(location) === selected ||
          (/^drive:[A-Z]:$/.test(selected) &&
            location.driveLetter.toUpperCase() === selected.slice(6))
      )
      .map((location) => location.titleId)
  );
}

export function availability(
  locations: readonly FileLocation[]
): 'present' | 'missing' | 'unknown' {
  if (locations.some((l) => l.evidence === 'present')) return 'present';
  if (locations.length && locations.every((l) => l.evidence === 'missing')) return 'missing';
  return 'unknown';
}

/** Title-level server availability uses confirmed copies across all mapped seasons. */
export function serverAvailability(locations: readonly FileLocation[]) {
  const present = locations.filter((location) => location.evidence === 'present');
  const drives = [
    ...new Set(
      present
        .map((location) => location.driveLetter.trim().replace(/:$/, '').toUpperCase())
        .filter(Boolean)
    )
  ].sort();
  const available = present.length > 0;
  return {
    available,
    drives,
    label: available
      ? 'Available on Server' +
        (drives.length ? ': ' + drives.map((drive) => `Drive ${drive}`).join(' / ') : '')
      : 'Not Available on Server'
  };
}

export function locationPath(location: FileLocation): string {
  const root = location.root.replaceAll('/', '\\').replace(/\\+$/, '');
  return root + '\\' + location.relativePath.replaceAll('/', '\\').replace(/^\\+/, '');
}

/** Only a complete, authorized scan of this exact root may confirm absence. */
export function applyScanEvidence(
  location: FileLocation,
  scan: {
    deviceId: string;
    volumeId: string;
    root: string;
    complete: boolean;
    connected: boolean;
    seenLocationIds: readonly string[];
    checkedAt: string;
  }
): FileLocation {
  const normalize = (s: string) => s.replaceAll('/', '\\').replace(/\\+$/, '').toLowerCase();
  if (
    scan.deviceId !== location.deviceId ||
    scan.volumeId !== location.volumeId ||
    normalize(scan.root) !== normalize(location.root)
  )
    return location;
  if (!scan.connected) return { ...location, evidence: 'unavailable' };
  if (scan.seenLocationIds.includes(location.id))
    return { ...location, evidence: 'present', checkedAt: scan.checkedAt };
  if (!scan.complete) return location;
  return { ...location, evidence: 'missing', checkedAt: scan.checkedAt };
}
