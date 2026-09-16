// Adapted from the MIT-licensed App Attest Workers reference by Nav Patel:
// https://gist.github.com/patelnav/8b4e6eddc48ac11e99e28a895accc881

/**
 * Apple App Attest — assertion object verification.
 *
 * Reference: https://developer.apple.com/documentation/devicecheck/validating_apps_that_connect_to_your_server
 *
 * Steps:
 *  1. clientData = SHA256(raw 32-byte challenge bytes retrieved from D1)
 *     (The iOS side receives challenge as base64url, decodes to bytes, then hashes those bytes.)
 *  2. Decode CBOR assertionObject → { signature: Uint8Array, authenticatorData: Uint8Array }
 *  3. Compute nonce = SHA256(authenticatorData ∥ clientData)
 *  4. Look up stored public key in D1 by keyId
 *  5. Verify ECDSA P-256 signature of nonce using stored pubkey
 *  6. Verify rpIdHash in authenticatorData
 *  7. Atomic counter increment: UPDATE … WHERE counter < newCounter
 *  8. Return keyId + env (from stored row) for JWT minting
 */

import { decode as cborDecode } from 'cbor-x';
import { AsnParser } from '@peculiar/asn1-schema';
import { ECDSASigValue } from '@peculiar/asn1-ecc';
import { fromBase64, fromBase64url } from './attestation';

function concat(...arrays: Uint8Array[]): Uint8Array {
  const total = arrays.reduce((n, a) => n + a.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const a of arrays) { out.set(a, offset); offset += a.length; }
  return out;
}

function equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  const buf = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
  return new Uint8Array(await crypto.subtle.digest('SHA-256', buf));
}

/**
 * Convert a DER-encoded ECDSA signature (Apple's format) to IEEE P1363 raw r||s
 * (WebCrypto's expected format). For P-256, output is always 64 bytes.
 *
 * Mirrors @simplewebauthn/server's `unwrapEC2Signature`.
 */
function derEcdsaToRaw(der: Uint8Array, componentSize = 32): Uint8Array {
  const parsed = AsnParser.parse(der, ECDSASigValue);
  const r = normaliseComponent(new Uint8Array(parsed.r), componentSize);
  const s = normaliseComponent(new Uint8Array(parsed.s), componentSize);
  const raw = new Uint8Array(componentSize * 2);
  raw.set(r, 0);
  raw.set(s, componentSize);
  return raw;
}

function normaliseComponent(bytes: Uint8Array, componentLength: number): Uint8Array {
  if (bytes.length === componentLength) return bytes;
  if (bytes.length < componentLength) {
    const out = new Uint8Array(componentLength);
    out.set(bytes, componentLength - bytes.length);
    return out;
  }
  if (
    bytes.length === componentLength + 1 &&
    bytes[0] === 0x00 &&
    (bytes[1] & 0x80) === 0x80
  ) {
    return bytes.subarray(1);
  }
  throw new Error(
    `Invalid ECDSA component length ${bytes.length}, expected ${componentLength}`,
  );
}

interface AttestedKeyRow {
  key_id: string;
  public_key_spki: ArrayBuffer;
  assertion_counter: number;
  environment: string;
}

/**
 * Verify an App Attest assertion and atomically advance the stored counter.
 *
 * @param assertionBase64    base64-encoded assertion object from iOS
 * @param keyId              identifier used to look up stored key in D1
 * @param rawChallengeBytes  the raw 32-byte challenge retrieved from D1 (never from request)
 * @param db                 D1 database binding
 * @param teamId             Apple team ID
 * @param bundleId           app bundle ID
 * @returns env ('prod'|'dev') for JWT payload
 */
export async function verifyAssertion(
  assertionBase64: string,
  keyId: string,
  rawChallengeBytes: Uint8Array,
  db: D1Database,
  teamId: string,
  bundleId: string,
): Promise<{ env: 'prod' | 'dev' }> {
  // 1. clientDataHash = SHA256(raw 32-byte challenge bytes from D1) — no double-hash
  const clientData = await sha256(rawChallengeBytes);

  // 2. Decode CBOR assertion object
  const assertionDer = fromBase64(assertionBase64);
  const assertObj = cborDecode(assertionDer) as {
    signature: Uint8Array;
    authenticatorData: Uint8Array;
  };

  if (!assertObj.signature || !assertObj.authenticatorData) {
    throw new Error('Invalid assertion object: missing signature or authenticatorData');
  }

  const signature = new Uint8Array(assertObj.signature);
  const authData = new Uint8Array(assertObj.authenticatorData);

  // Parse counter from authenticatorData (same layout as attestation)
  if (authData.length < 37) throw new Error('authenticatorData too short');
  const rpIdHashBytes = authData.slice(0, 32);
  const view = new DataView(authData.buffer, authData.byteOffset);
  const newCounter = view.getUint32(33, false); // big-endian

  // 3. Compute nonce
  const nonce = await sha256(concat(authData, clientData));

  // 4. Look up stored key
  const row = await db
    .prepare('SELECT key_id, public_key_spki, assertion_counter, environment FROM app_attest_keys WHERE key_id = ?')
    .bind(keyId)
    .first<AttestedKeyRow>();

  if (!row) throw new Error('Unknown keyId — device not attested');

  // 5. Verify ECDSA P-256 signature
  // stored pubkey is raw SPKI bytes (SubjectPublicKeyInfo DER).
  // D1 BLOB may come back as ArrayBuffer (91 bytes) or a Uint8Array view into a larger
  // backing buffer; the previous `.buffer` extraction returned the full backing store
  // and broke SubtleCrypto's SPKI parser. Pass a properly-bounded Uint8Array — workerd
  // accepts any BufferSource.
  const pubkeyU8: Uint8Array = row.public_key_spki instanceof Uint8Array
    ? row.public_key_spki
    : new Uint8Array(row.public_key_spki as ArrayBuffer);

  const cryptoKey = await crypto.subtle.importKey(
    'spki',
    pubkeyU8,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['verify'],
  );

  // Apple ships DER-encoded ECDSA signatures; WebCrypto expects IEEE P1363 raw r||s.
  const signatureRaw = derEcdsaToRaw(signature, 32);

  const valid = await crypto.subtle.verify(
    { name: 'ECDSA', hash: { name: 'SHA-256' } },
    cryptoKey,
    signatureRaw,
    nonce,
  );

  if (!valid) throw new Error('Assertion signature verification failed');

  // 6. Verify rpIdHash
  const rpId = `${teamId}.${bundleId}`;
  const expectedRpIdHash = await sha256(new TextEncoder().encode(rpId));
  if (!equal(expectedRpIdHash, rpIdHashBytes)) {
    throw new Error('rpIdHash mismatch in assertion');
  }

  // 7. Atomic counter advancement — rejects replay attacks
  if (newCounter <= row.assertion_counter) {
    throw new Error(`Counter not advancing: stored=${row.assertion_counter}, received=${newCounter}`);
  }

  const now = Math.floor(Date.now() / 1000);
  const update = await db
    .prepare(
      'UPDATE app_attest_keys SET assertion_counter = ?, last_used_at = ? WHERE key_id = ? AND assertion_counter < ?',
    )
    .bind(newCounter, now, keyId, newCounter)
    .run();

  if (!update.success || update.meta.changes === 0) {
    throw new Error('Counter update conflict — possible replay attack');
  }

  const env = row.environment === 'dev' ? 'dev' : 'prod';
  return { env };
}
