import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';
import { importX509, jwtVerify } from 'jose';
import { CognitoJwtVerifier } from 'aws-jwt-verify';

export const hash = v => createHash('sha256').update(v).digest('hex');
export const randomToken = () => randomBytes(32).toString('base64url');
export class ApiError extends Error {
  constructor(statusCode, code) { super(code); this.statusCode = statusCode; this.code = code; }
}
export const requireThat = (condition, status = 401, code = 'UNAUTHORIZED') => {
  if (!condition) throw new ApiError(status, code);
};
export function bearer(request) {
  const header = request.headers.authorization || '';
  requireThat(/^Bearer [A-Za-z0-9._~-]{20,8192}$/.test(header));
  return header.slice(7);
}

export async function productionVerifiers(config) {
  const keys = await Promise.all(config.attestationCertificates.map(c => importX509(c, 'RS256')));
  const cognito = CognitoJwtVerifier.create({ userPoolId: config.userPoolId, clientId: config.clientId, tokenUse: 'access' });
  return {
    admin: async token => {
      const claims = await cognito.verify(token);
      requireThat(claims.sub === config.adminSub, 403, 'FORBIDDEN');
      return claims;
    },
    attest: async token => {
      for (const key of keys) {
        try {
          const { payload } = await jwtVerify(token, key, {
            algorithms: ['RS256'], issuer: 'urn:roku:cloud-services:device-attestation',
            requiredClaims: ['exp', 'nbf', 'x-roku-attestation-data'], clockTolerance: 10,
          });
          return payload['x-roku-attestation-data'];
        } catch { /* Try only our configured trust keys, never a token-supplied URL. */ }
      }
      throw new ApiError(401, 'INVALID_ATTESTATION');
    },
  };
}

export class Auth {
  constructor(config, verifiers, now = Date.now) {
    this.config = config; this.verifiers = verifiers; this.now = now;
    this.challenges = new Map(); this.sessions = new Map();
  }
  installation(token) {
    const digest = Buffer.from(hash(token), 'hex');
    const device = this.config.devices.find(d => timingSafeEqual(digest, Buffer.from(d.secretHash, 'hex')));
    requireThat(device?.enabled);
    return device;
  }
  challenge(token) {
    const device = this.installation(token);
    const challengeId = randomToken(), nonce = randomBytes(16).toString('hex');
    this.challenges.set(device.id, { challengeId, nonce, expiresAt: this.now() + 60000 });
    return { challengeId, nonce, expiresIn: 60 };
  }
  async session(token, { challengeId, attestation, appSessionId }) {
    const device = this.installation(token);
    const challenge = this.challenges.get(device.id);
    requireThat(challenge && challenge.challengeId === challengeId && challenge.expiresAt > this.now());
    const data = await this.verifiers.attest(attestation);
    requireThat(data && typeof data === 'object', 401, 'INVALID_ATTESTATION');
    requireThat(data.nonce === challenge.nonce && data.developerId === device.developerId && data.channelId === device.channelId);
    // Consume after async verification, atomically: two simultaneous submissions cannot win.
    requireThat(this.challenges.get(device.id) === challenge && challenge.expiresAt > this.now());
    this.installation(token);
    this.challenges.delete(device.id);
    const sessionToken = randomToken();
    const expiresAt = this.now() + 15 * 60000;
    // A new application process fences old requests; renewal permits a short overlap.
    for (const [key, s] of this.sessions) {
      if (s.expiresAt <= this.now() || (s.deviceId === device.id && s.appSessionId !== appSessionId)) this.sessions.delete(key);
    }
    const sameDevice = [...this.sessions].filter(([, s]) => s.deviceId === device.id);
    for (const [key] of sameDevice.slice(0, Math.max(0, sameDevice.length - 1))) this.sessions.delete(key);
    this.sessions.set(hash(sessionToken), { deviceId: device.id, appSessionId, expiresAt, secretHash: device.secretHash });
    return { sessionToken, expiresIn: 900, deviceId: device.id };
  }
  device(token) {
    const session = this.sessions.get(hash(token));
    const device = session && this.config.devices.find(d => d.id === session.deviceId);
    requireThat(session && session.expiresAt > this.now() && device?.enabled && session.secretHash === device.secretHash);
    return session;
  }
}
