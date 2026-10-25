import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from 'jose';

export interface AccessConfiguration {
  issuer: string;
  audience: string;
  ownerEmail: string;
}

export class AccessFailure extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export function createAccessVerifier(config: AccessConfiguration, getKey?: JWTVerifyGetKey) {
  const issuer = config.issuer.replace(/\/$/, '');
  if (
    !/^https:\/\/[a-z0-9][a-z0-9-]*\.cloudflareaccess\.com$/.test(issuer) ||
    !config.audience ||
    !config.ownerEmail.includes('@')
  ) {
    throw new AccessFailure(503, 'Private access is not configured');
  }
  const jwks = getKey ?? createRemoteJWKSet(new URL(issuer + '/cdn-cgi/access/certs'));
  return async (request: Request) => {
    const assertion = request.headers.get('Cf-Access-Jwt-Assertion');
    if (!assertion) throw new AccessFailure(401, 'Sign in through Cloudflare Access');
    try {
      const { payload } = await jwtVerify(assertion, jwks, {
        issuer,
        audience: config.audience,
        algorithms: ['RS256'],
        requiredClaims: ['exp', 'iat', 'sub']
      });
      if (
        typeof payload.sub !== 'string' ||
        !payload.sub.trim() ||
        payload.type !== 'app' ||
        typeof payload.email !== 'string' ||
        payload.email.toLowerCase() !== config.ownerEmail.toLowerCase()
      ) {
        throw new Error('Wrong owner');
      }
      return { subject: payload.sub, email: payload.email };
    } catch {
      throw new AccessFailure(403, 'Access could not be verified');
    }
  };
}

export function assertSameOriginWrite(request: Request): void {
  if (['GET', 'HEAD', 'OPTIONS'].includes(request.method)) return;
  if (request.headers.get('Origin') !== new URL(request.url).origin) {
    throw new AccessFailure(403, 'Use the diary to submit changes');
  }
}
