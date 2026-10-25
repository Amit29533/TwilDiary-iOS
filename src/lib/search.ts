import type { SearchMatch } from './metadata.ts';
import type { TitleSummary } from './client/contracts.ts';
export interface SearchTitle {
  id: string;
  name: string;
  year: number | null;
  poster: string | null;
  category: string;
}
export interface DiarySearchPage {
  library: TitleSummary[];
  online: (SearchMatch & { trashId?: string })[];
  nextCursor: string | null;
  page: number;
  totalPages: number;
  onlineError: string;
}
