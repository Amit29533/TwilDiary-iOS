import { error } from '@sveltejs/kit';
import type { PageLoad } from './$types';
import type { FilmographyKind } from '#lib/people.ts';
export const load: PageLoad = ({ params }) => {
  if (
    !/^\d{1,10}$/.test(params.id) ||
    Number(params.id) < 1 ||
    !['shows', 'movies', 'known-for', 'credits'].includes(params.section)
  )
    error(404, 'Filmography not found');
  return { kind: params.section as FilmographyKind };
};
