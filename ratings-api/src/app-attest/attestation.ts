// Adapted from the MIT-licensed App Attest Workers reference by Nav Patel:
// https://gist.github.com/patelnav/8b4e6eddc48ac11e99e28a895accc881

/**
 * Apple App Attest — attestation object verification.
 *
 * Reference: https://developer.apple.com/documentation/devicecheck/validating_apps_that_connect_to_your_server
 *
 * Steps implemented:
 *  1. Decode CBOR attestation object → { fmt, attStmt: { x5c, receipt }, authData }
 *  2. Validate x5c chain up to the Apple App Attest Root CA
 *  3. Verify nonce: SHA256(authData ∥ clientDataHash) matches OID 1.2.840.113635.100.8.2 extension
 *  4. Verify public key in leaf cert matches the SHA256 hash embedded in credentialId
 *  5. Verify authData.rpIdHash == SHA256(teamId.bundleId)
 *  6. Verify authData.counter == 0
 *  7. Verify authData.aaguid is one of the two known App Attest values
 *  8. Verify authData.credentialId == keyId (base64url)
 *  9. Return extracted public key (raw SPKI bytes) and env ("prod"|"dev")
 */

import { decode as cborDecode } from 'cbor-x';
import { X509Certificate, X509ChainBuilder } from '@peculiar/x509';
import { APPLE_APP_ATTEST_ROOT_CA_PEM, pemToDer } from './apple-root';

// AAGUIDs for App Attest (16 bytes, ASCII-padded)
// "appattest" + 7 null bytes  →  prod
// "appattestdevelop"          →  dev
const AAGUID_PROD = 'appattest\x00\x00\x00\x00\x00\x00\x00';
const AAGUID_DEV  = 'appattestdevelop';

function aaguidToString(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map(b => String.fromCharCode(b))
    .join('');
}

/**
 * Decode base64url → Uint8Array
 */
export function fromBase64url(s: string): Uint8Array {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/');
  const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
  const bin = atob(padded);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf;
}

export function fromBase64(s: string): Uint8Array {
  const padded = s + '='.repeat((4 - (s.length % 4)) % 4);
  const bin = atob(padded);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf;
}

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  const digest = await crypto.subtle.digest('SHA-256', data.buffer as ArrayBuffer);
  return new Uint8Array(digest);
}

function concat(...arrays: Uint8Array[]): Uint8Array {
  const total = arrays.reduce((n, a) => n + a.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const a of arrays) {
    out.set(a, offset);
    offset += a.length;
  }
  return out;
}

function equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/**
 * Parse the authenticatorData blob.
 * Layout (per WebAuthn spec):
 *   [0..31]  rpIdHash (32 bytes)
 *   [32]     flags (1 byte)
 *   [33..36] signCount (4 bytes big-endian)
 *   [37..52] aaguid (16 bytes)
 *   [53..54] credentialIdLength (2 bytes big-endian)
 *   [55..]   credentialId (credentialIdLength bytes)
 */
interface AuthData {
  rpIdHash: Uint8Array;
  flags: number;
  counter: number;
  aaguid: Uint8Array;
  credentialId: Uint8Array;
  raw: Uint8Array;
}

function parseAuthData(buf: Uint8Array): AuthData {
  if (buf.length < 55) throw new Error('authData too short');
  const view = new DataView(buf.buffer, buf.byteOffset);
  const rpIdHash = buf.slice(0, 32);
  const flags = buf[32];
  const counter = view.getUint32(33, false); // big-endian
  const aaguid = buf.slice(37, 53);
  const credentialIdLength = view.getUint16(53, false);
  if (buf.length < 55 + credentialIdLength) throw new Error('authData truncated');
  const credentialId = buf.slice(55, 55 + credentialIdLength);
  return { rpIdHash, flags, counter, aaguid, credentialId, raw: buf };
}

/**
 * Extract the nonce from the leaf certificate's OID 1.2.840.113635.100.8.2 extension.
 *
 * The extension value is DER-encoded as:
 *   SEQUENCE {
 *     [1] EXPLICIT OCTET STRING { <32-byte nonce> }
 *   }
 * We parse this minimally rather than pulling in a full ASN.1 library.
 */
function extractNonceFromCert(cert: X509Certificate): Uint8Array {
  // OID 1.2.840.113635.100.8.2 in hex: 2a864886fa6364080102
  const OID_NONCE = '1.2.840.113635.100.8.2';

  const ext = cert.getExtension(OID_NONCE);
  if (!ext) throw new Error('Missing nonce extension in leaf cert');

  // ext.value is the raw DER bytes of the extension value (already unwrapped from OCTET STRING wrapper)
  const raw: Uint8Array = ext instanceof Uint8Array
    ? ext
    : new Uint8Array((ext as { value: ArrayBuffer }).value);

  // Parse: SEQUENCE { [1] { OCTET STRING { <nonce> } } }
  // We walk the minimal DER structure to get to the 32-byte nonce.
  let i = 0;
  function readTlv(): { tag: number; value: Uint8Array } {
    const tag = raw[i++];
    let len = raw[i++];
    if (len & 0x80) {
      const nb = len & 0x7f;
      len = 0;
      for (let j = 0; j < nb; j++) len = (len << 8) | raw[i++];
    }
    const value = raw.slice(i, i + len);
    i += len;
    return { tag, value };
  }

  // Outer SEQUENCE (tag 0x30)
  const outer = readTlv();
  if (outer.tag !== 0x30) throw new Error('Expected SEQUENCE in nonce extension');

  // Inner context [1] (tag 0xa1)
  let j = 0;
  const outerRaw = outer.value;
  function readInner(): { tag: number; value: Uint8Array } {
    const tag = outerRaw[j++];
    let len = outerRaw[j++];
    if (len & 0x80) {
      const nb = len & 0x7f;
      len = 0;
      for (let k = 0; k < nb; k++) len = (len << 8) | outerRaw[j++];
    }
    const value = outerRaw.slice(j, j + len);
    j += len;
    return { tag, value };
  }

  const ctx = readInner();
  if (ctx.tag !== 0xa1) throw new Error('Expected [1] context in nonce extension');

  // OCTET STRING (tag 0x04) inside [1]
  let k = 0;
  const ctxRaw = ctx.value;
  const octTag = ctxRaw[k++];
  if (octTag !== 0x04) throw new Error('Expected OCTET STRING in nonce extension');
  let octLen = ctxRaw[k++];
  if (octLen & 0x80) {
    const nb = octLen & 0x7f;
    octLen = 0;
    for (let m = 0; m < nb; m++) octLen = (octLen << 8) | ctxRaw[k++];
  }
  const nonce = ctxRaw.slice(k, k + octLen);
  if (nonce.length !== 32) throw new Error(`Nonce must be 32 bytes, got ${nonce.length}`);
  return nonce;
}

/**
 * Validate that x5c chain terminates at the Apple App Attest Root CA.
 * Returns the leaf X509Certificate.
 */
async function validateChain(x5c: Uint8Array[]): Promise<X509Certificate> {
  if (x5c.length < 2) throw new Error('x5c chain too short');

  const certs = x5c.map(der => new X509Certificate(der.buffer as ArrayBuffer));
  const leaf = certs[0];

  // Build a chain ending at the embedded root
  const rootDer = pemToDer(APPLE_APP_ATTEST_ROOT_CA_PEM);
  const root = new X509Certificate(rootDer.buffer as ArrayBuffer);

  const builder = new X509ChainBuilder({
    certificates: [...certs.slice(1), root],
  });

  const chain = await builder.build(leaf);
  // chain[last] should be self-signed root
  if (chain.length < 2) throw new Error('Could not build certificate chain to root');

  // Verify the chain terminates at our known root
  const chainRoot = chain[chain.length - 1];
  if (!equal(new Uint8Array(chainRoot.rawData), new Uint8Array(root.rawData))) {
    throw new Error('Certificate chain does not terminate at Apple App Attest Root CA');
  }

  return leaf;
}

export interface AttestationResult {
  /** Raw SPKI bytes of the attested P-256 public key */
  pubkeySpki: Uint8Array;
  /** 'prod' for appattest, 'dev' for appattestdevelop */
  env: 'prod' | 'dev';
}

/**
 * Verify an App Attest attestation object.
 *
 * @param attestationBase64  base64-encoded (standard) attestation object from iOS
 * @param keyId              the key identifier from SecKeyAttestation (base64url)
 * @param challengeBytes     the raw 32-byte challenge that was sent to the device
 * @param teamId             Apple team ID (e.g. "866MN8FJSP")
 * @param bundleId           app bundle ID (e.g. "co.timeywimey.app")
 */
export async function verifyAttestation(
  attestationBase64: string,
  keyId: string,
  challengeBytes: Uint8Array,
  teamId: string,
  bundleId: string,
): Promise<AttestationResult> {
  // 1. Decode CBOR
  const attestationDer = fromBase64(attestationBase64);
  // cbor-x decode returns a plain JS object
  const attestObj = cborDecode(attestationDer) as {
    fmt: string;
    attStmt: { x5c: Uint8Array[]; receipt: Uint8Array };
    authData: Uint8Array;
  };

  if (attestObj.fmt !== 'apple-appattest') {
    throw new Error(`Unexpected attestation format: ${attestObj.fmt}`);
  }

  const { x5c, receipt } = attestObj.attStmt;
  const authDataRaw = attestObj.authData;

  if (!x5c || !Array.isArray(x5c) || x5c.length === 0) {
    throw new Error('Missing x5c in attestation statement');
  }
  if (!authDataRaw) throw new Error('Missing authData');
  void receipt; // stored by Apple for DCAppAttest receipt validation (out of scope for MVP)

  // 2. Validate x5c chain up to Apple Root CA
  const leafCert = await validateChain(x5c.map(v => new Uint8Array(v)));

  // 3. Compute clientDataHash = SHA256(challenge) and verify nonce
  const clientDataHash = await sha256(challengeBytes);
  const authDataBytes = new Uint8Array(authDataRaw);
  const expectedNonce = await sha256(concat(authDataBytes, clientDataHash));

  const certNonce = extractNonceFromCert(leafCert);
  if (!equal(expectedNonce, certNonce)) {
    throw new Error('Nonce mismatch: attestation does not cover this challenge');
  }

  // 4. Verify public key matches credentialId hash.
  // Apple hashes the ANSI X9.63 uncompressed EC point (65 bytes: 0x04 || X || Y),
  // NOT the full SPKI DER. We still keep the SPKI for D1 storage + subtle.importKey.
  const spki = new Uint8Array(leafCert.publicKey.rawData);
  const ecCryptoKey = await crypto.subtle.importKey(
    'spki',
    spki.buffer as ArrayBuffer,
    { name: 'ECDSA', namedCurve: 'P-256' },
    true,
    ['verify'],
  );
  const rawEcPoint = new Uint8Array(await crypto.subtle.exportKey('raw', ecCryptoKey) as ArrayBuffer);
  const rawEcPointHash = await sha256(rawEcPoint);
  const parsedAuth = parseAuthData(authDataBytes);

  if (!equal(rawEcPointHash, parsedAuth.credentialId)) {
    throw new Error('Credential ID does not match public key hash');
  }

  // 5. Verify rpIdHash
  const rpId = `${teamId}.${bundleId}`;
  const expectedRpIdHash = await sha256(new TextEncoder().encode(rpId));
  if (!equal(expectedRpIdHash, parsedAuth.rpIdHash)) {
    throw new Error('rpIdHash mismatch');
  }

  // 6. Verify counter == 0
  if (parsedAuth.counter !== 0) {
    throw new Error(`Counter must be 0 for fresh attestation, got ${parsedAuth.counter}`);
  }

  // 7. Verify aaguid
  const aaguidStr = aaguidToString(parsedAuth.aaguid);
  let env: 'prod' | 'dev';
  if (aaguidStr === AAGUID_PROD) {
    env = 'prod';
  } else if (aaguidStr === AAGUID_DEV) {
    env = 'dev';
  } else {
    throw new Error(`Unknown aaguid: ${Array.from(parsedAuth.aaguid).map(b => b.toString(16).padStart(2,'0')).join('')}`);
  }

  // 8. Verify credentialId == keyId
  // iOS returns keyId as base64 of SHA256(raw EC uncompressed point) = credentialId in authData.
  const expectedCredentialId = fromBase64url(keyId);
  if (!equal(expectedCredentialId, parsedAuth.credentialId)) {
    throw new Error('keyId does not match credentialId in authData');
  }

  return { pubkeySpki: spki, env };
}
