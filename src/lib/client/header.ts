export const HEADER_ACTIONS = 'twil-header-actions';
export interface HeaderActions {
  onsearch?: (() => void) | undefined;
  onadd?: (() => void) | undefined;
  searchOpen: boolean;
  count?: string;
}
export interface HeaderController {
  actions: HeaderActions | null;
}
