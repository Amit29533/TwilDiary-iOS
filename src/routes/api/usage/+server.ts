import type { RequestHandler } from '@sveltejs/kit';
import { bindings, ownerApi } from '#lib/server/api.ts';
import { cloudflareUsage, usageRange } from '#lib/server/cloudflare-usage.ts';

/** Settings → Cloudflare. Reads Cloudflare's analytics only; no database connection. */
export const GET: RequestHandler = (event) =>
  ownerApi(event, () =>
    cloudflareUsage(
      bindings(event).CF_ANALYTICS_TOKEN,
      bindings(event).CF_ACCOUNT_ID,
      usageRange(event.url.searchParams)
    )
  );
