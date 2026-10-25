import { error } from '@sveltejs/kit';
import { exploreSection } from '#lib/explore-sections.ts';
import type { PageLoad } from './$types';
export const load: PageLoad = ({ params }) => {
  const section = exploreSection(params.section);
  if (!section) error(404, 'This Explore section does not exist.');
  return { section };
};
