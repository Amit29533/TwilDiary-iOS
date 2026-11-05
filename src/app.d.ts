import type { D1Database, ExecutionContext, CfProperties } from '@cloudflare/workers-types';

declare global {
  namespace App {
    interface PageState {
      twilDepth?: number;
    }
    interface Locals {
      owner?: { subject: string; email: string; method?: string };
      bindings?: Platform['env'];
      tmdbTransport?: typeof fetch;
    }
    interface Platform {
      env: {
        DB?: D1Database;
        LOCAL_DIARY?: string;
        LOCAL_LAN_HOST?: string;
        LOCAL_LAN_ENABLED?: string;
        ACCESS_TEAM_DOMAIN?: string;
        ACCESS_AUDIENCE?: string;
        ACCESS_OWNER_EMAIL?: string;
        DIARY_ACCESS_TOKEN?: string;
        DIARY_OWNER_EMAIL?: string;
        DIARY_OWNER_PASSCODE?: string;
        DIARY_AUTH_SECRET?: string;
        TMDB_ACCESS_TOKEN?: string;
        TRAKT_CLIENT_ID?: string;
        TRAKT_TOKEN_KEY?: string;
        TRAKT_REDIRECT_URI?: string;
        TRAKT_PERSONAL_ACCESS_TOKEN?: string;
        MDBLIST_API_KEY?: string;
        SIMKL_CLIENT_ID?: string;
        MDBLIST_CLIENT_ID?: string;
        CF_ANALYTICS_TOKEN?: string;
        CF_ACCOUNT_ID?: string;
      };
      context?: ExecutionContext;
      cf?: CfProperties;
    }
  }
}
export {};
