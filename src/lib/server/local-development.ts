/** Explicit opt-in for this PC only; callers must pass compile-time dev and the socket address. */
export function localDevelopmentAllowed(
  dev: boolean,
  enabled: string | undefined,
  url: URL,
  address: string
) {
  return (
    dev &&
    enabled === '1' &&
    ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) &&
    ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(address)
  );
}

export interface LocalNetworkConfig {
  LOCAL_DIARY?: string;
  LOCAL_LAN_HOST?: string;
  LOCAL_LAN_ENABLED?: string;
}
export function privateIPv4(value: string) {
  const parts = value.replace(/^::ffff:/, '').split('.');
  if (parts.length !== 4 || parts.some((part) => !/^\d{1,3}$/.test(part) || +part > 255))
    return false;
  const [a, b] = parts.map(Number);
  return a === 10 || (a === 172 && b! >= 16 && b! <= 31) || (a === 192 && b === 168);
}
/** Explicit local Wi-Fi testing only; never an authentication bypass in production. */
export function localNetworkAllowed(
  dev: boolean,
  config: LocalNetworkConfig,
  url: URL,
  address: string
) {
  if (
    !dev ||
    config.LOCAL_DIARY !== '1' ||
    config.LOCAL_LAN_ENABLED !== '1' ||
    !privateIPv4(address) ||
    !config.LOCAL_LAN_HOST ||
    !privateIPv4(config.LOCAL_LAN_HOST) ||
    url.hostname !== config.LOCAL_LAN_HOST ||
    url.port !== '5180' ||
    url.protocol !== 'http:'
  )
    return false;
  return true;
}
