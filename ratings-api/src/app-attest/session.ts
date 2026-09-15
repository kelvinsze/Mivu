import { SignJWT, jwtVerify } from 'jose';
import { Env } from '../types/env';

const encoder = new TextEncoder();
const tokenLifetime = 15 * 60;

function secret(env: Env): Uint8Array {
  if (!env.APP_ATTEST_JWT_SECRET || env.APP_ATTEST_JWT_SECRET.length < 32) {
    throw new Error('APP_ATTEST_JWT_SECRET must be configured with at least 32 characters');
  }
  return encoder.encode(env.APP_ATTEST_JWT_SECRET);
}

export async function issueSessionToken(env: Env, keyId: string, attestedEnv: 'prod' | 'dev'): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ keyId, appEnv: attestedEnv, scope: 'ratings:read' })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setIssuedAt(now).setExpirationTime(now + tokenLifetime)
    .setIssuer('mivu-ratings-api').setAudience('mivu-ios')
    .sign(secret(env));
}

export async function verifySessionToken(env: Env, token: string): Promise<{ keyId: string; appEnv: 'prod' | 'dev' }> {
  const { payload } = await jwtVerify(token, secret(env), { issuer: 'mivu-ratings-api', audience: 'mivu-ios' });
  if (typeof payload.keyId !== 'string' || (payload.appEnv !== 'prod' && payload.appEnv !== 'dev') || payload.scope !== 'ratings:read') {
    throw new Error('Invalid App Attest session claims');
  }
  return { keyId: payload.keyId, appEnv: payload.appEnv };
}
