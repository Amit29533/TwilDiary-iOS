export const themes = [
  {
    id: 'twilight',
    name: 'Twilight',
    description: 'The original violet',
    accent: '#b795f6',
    strong: '#9d76f4',
    light: '#d3bfff',
    rgb: '183 149 246',
    ink: '#21182e',
    canvas: '#000000',
    surface: '#111115'
  },
  {
    id: 'ocean',
    name: 'Ocean',
    description: 'Clear, cool blue',
    accent: '#82b8ff',
    strong: '#498de8',
    light: '#c2ddff',
    rgb: '130 184 255',
    ink: '#102039',
    canvas: '#000000',
    surface: '#111115'
  },
  {
    id: 'jade',
    name: 'Jade',
    description: 'A quiet mint glow',
    accent: '#79d8bc',
    strong: '#36ae8c',
    light: '#b9f1df',
    rgb: '121 216 188',
    ink: '#102820',
    canvas: '#000000',
    surface: '#111115'
  },
  {
    id: 'rose',
    name: 'Rose',
    description: 'Soft pink after dark',
    accent: '#f4a2c6',
    strong: '#d66d9f',
    light: '#ffd5e7',
    rgb: '244 162 198',
    ink: '#321622',
    canvas: '#000000',
    surface: '#111115'
  },
  {
    id: 'amber',
    name: 'Amber',
    description: 'Warm cinema gold',
    accent: '#edbe73',
    strong: '#ca8e36',
    light: '#ffe1b3',
    rgb: '237 190 115',
    ink: '#2c2010',
    canvas: '#000000',
    surface: '#111115'
  },
  {
    id: 'glass',
    name: 'Liquid Glass',
    description: 'Liquid light on pure black',
    accent: '#c4e5ff',
    strong: '#87bde8',
    light: '#e5f3ff',
    rgb: '196 229 255',
    ink: '#132332',
    canvas: '#000000',
    surface: '#101013eb'
  }
] as const;

export type ThemeId = (typeof themes)[number]['id'];
export const THEME_KEY = 'twildiary.theme.v1';
export const DEFAULT_THEME: ThemeId = 'twilight';

export function themeId(value: unknown): ThemeId {
  return themes.some((theme) => theme.id === value) ? (value as ThemeId) : DEFAULT_THEME;
}
export function readTheme(storage: Pick<Storage, 'getItem'>): ThemeId {
  try {
    return themeId(storage.getItem(THEME_KEY));
  } catch {
    return DEFAULT_THEME;
  }
}
export function writeTheme(storage: Pick<Storage, 'setItem'>, id: ThemeId): boolean {
  try {
    storage.setItem(THEME_KEY, themeId(id));
    return true;
  } catch {
    return false;
  }
}
