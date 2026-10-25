/** Shared persistent identities; keep the manual engine's existing hash scheme. */
export async function traktDigest(text: string) {
  return Array.from(
    new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))),
    (byte) => byte.toString(16).padStart(2, '0')
  ).join('');
}
export const traktBaselineId = (account: string, kind: string, localKey: string) =>
  traktDigest(account + ':' + kind + ':' + localKey);
