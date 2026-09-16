import { Hono } from 'hono';
import { Env } from '../types/env';
import { createErrorResponse, createJsonResponse } from '../utils/response';
import { issueSessionToken } from '../app-attest/session';

export const appAttestRoutes = new Hono<{ Bindings: Env }>();
const ttl = 5 * 60;
const b64url = (bytes: Uint8Array) => { let s = ''; for (const b of bytes) s += String.fromCharCode(b); return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); };

function config(env: Env): { team: string; bundle: string } {
  if (!env.APP_ATTEST_TEAM_ID || !env.APP_ATTEST_BUNDLE_ID) throw new Error('App Attest identifiers are not configured');
  return { team: env.APP_ATTEST_TEAM_ID, bundle: env.APP_ATTEST_BUNDLE_ID };
}

async function consumeChallenge(env: Env, id: string, purpose: string): Promise<Uint8Array> {
  const now = Math.floor(Date.now() / 1000);
  const row = await env.DB.prepare('DELETE FROM app_attest_challenges WHERE id = ? AND purpose = ? AND expires_at > ? RETURNING challenge_b64').bind(id, purpose, now).first<{ challenge_b64: string }>();
  if (!row) throw new Error('Challenge is invalid, expired, or already used');
  const b64 = row.challenge_b64.replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(b64 + '='.repeat((4 - b64.length % 4) % 4));
  return Uint8Array.from(bin, (char) => char.charCodeAt(0));
}

appAttestRoutes.post('/v1/app-attest/challenge', async (c) => {
  let purpose: 'attestation' | 'assertion' = 'attestation';
  try { const body = await c.req.json<{ purpose?: string }>(); if (body.purpose === 'assertion') purpose = 'assertion'; } catch { /* empty body is an attestation challenge */ }
  const idBytes = crypto.getRandomValues(new Uint8Array(16));
  const challenge = crypto.getRandomValues(new Uint8Array(32));
  const id = b64url(idBytes);
  await c.env.DB.prepare('INSERT INTO app_attest_challenges (id, purpose, challenge_b64, expires_at) VALUES (?, ?, ?, ?)').bind(id, purpose, b64url(challenge), Math.floor(Date.now() / 1000) + ttl).run();
  return createJsonResponse({ challengeId: id, challenge: b64url(challenge), expiresIn: ttl });
});

appAttestRoutes.post('/v1/app-attest/attest', async (c) => {
  try {
    const body = await c.req.json<{ challengeId?: string; keyId?: string; attestation?: string }>();
    if (!body.challengeId || !body.keyId || !body.attestation) return createErrorResponse('INVALID_REQUEST', 'challengeId, keyId and attestation are required', 400);
    const challenge = await consumeChallenge(c.env, body.challengeId, 'attestation');
    const ids = config(c.env);
    const { verifyAttestation } = await import('../app-attest/attestation');
    const result = await verifyAttestation(body.attestation, body.keyId, challenge, ids.team, ids.bundle);
    if (c.env.ENVIRONMENT === 'production' && result.env === 'dev') {
      return createErrorResponse('FORBIDDEN', 'Development attestations are not permitted in production', 403);
    }
    const now = Math.floor(Date.now() / 1000);
    await c.env.DB.prepare('INSERT INTO app_attest_keys (key_id, public_key_spki, assertion_counter, environment, created_at, last_used_at) VALUES (?, ?, 0, ?, ?, ?)').bind(body.keyId, result.pubkeySpki, result.env, now, now).run();
    return createJsonResponse({ registered: true });
  } catch (error) { return createErrorResponse('APP_ATTEST_FAILED', error instanceof Error ? error.message : 'App Attest registration failed', 401); }
});

appAttestRoutes.post('/v1/app-attest/assert', async (c) => {
  try {
    const body = await c.req.json<{ challengeId?: string; keyId?: string; assertion?: string }>();
    if (!body.challengeId || !body.keyId || !body.assertion) return createErrorResponse('INVALID_REQUEST', 'challengeId, keyId and assertion are required', 400);
    const challenge = await consumeChallenge(c.env, body.challengeId, 'assertion');
    const ids = config(c.env);
    const { verifyAssertion } = await import('../app-attest/assertion');
    const result = await verifyAssertion(body.assertion, body.keyId, challenge, c.env.DB, ids.team, ids.bundle);
    return createJsonResponse({ token: await issueSessionToken(c.env, body.keyId, result.env), expiresIn: 900 });
  } catch (error) { return createErrorResponse('APP_ATTEST_FAILED', error instanceof Error ? error.message : 'App Attest assertion failed', 401); }
});
