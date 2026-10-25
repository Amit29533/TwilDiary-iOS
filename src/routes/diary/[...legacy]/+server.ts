import type { RequestHandler } from '@sveltejs/kit';
export const GET: RequestHandler = ({ url }) => {
  const suffix = url.pathname.slice('/diary'.length);
  const target = !suffix
    ? '/preview/library'
    : suffix === '/glance'
      ? '/preview'
      : '/preview' + suffix;
  return new Response(null, {
    status: 307,
    headers: { Location: target + url.search, 'Cache-Control': 'no-store' }
  });
};
