export interface UnmatchedScan {
  id: string;
  version: number;
  deviceId: string;
  deviceName: string;
  volumeId: string;
  driveLetter: string;
  root: string;
  relativePath: string;
  name: string;
  seasonNumber: number | null;
  fileCount: number;
  sizeBytes: number | null;
  checkedAt: string;
}
