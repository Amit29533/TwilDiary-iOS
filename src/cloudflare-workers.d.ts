declare module 'cloudflare:workers' {
  export const env: import('./lib/server/api.ts').ServerBindings;
}
