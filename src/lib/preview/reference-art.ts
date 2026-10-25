/** Clean artwork windows in the owner's supplied Glance concept. Preview only.
 * Cropping is performed by the image viewport; no interface text/control is used as UI.
 * One locally encoded 334 KB atlas is shared by every window.
 */
export interface ArtWindow {
  x: number;
  y: number;
  width: number;
  height: number;
}
export const referenceAtlas = { src: '/demo/glance-reference-atlas.jpg', width: 852, height: 1846 };
const windows: Record<string, { poster: ArtWindow; scene: ArtWindow }> = {
  frieren: {
    poster: { x: 60, y: 335, width: 193, height: 240 },
    scene: { x: 506, y: 446, width: 287, height: 120 }
  },
  night: {
    poster: { x: 60, y: 711, width: 193, height: 242 },
    scene: { x: 510, y: 795, width: 285, height: 145 }
  },
  severance: {
    poster: { x: 60, y: 1084, width: 193, height: 212 },
    scene: { x: 496, y: 1150, width: 299, height: 135 }
  },
  again: {
    poster: { x: 60, y: 1426, width: 193, height: 177 },
    scene: { x: 510, y: 1480, width: 285, height: 110 }
  }
};
export const referenceArt = (id: string) => windows[id];
export function referencePoster(src: string | null) {
  const match = src?.match(/^\/demo\/(frieren|night|severance|again)\.jpg$/);
  return match ? windows[match[1]!]!.poster : undefined;
}
