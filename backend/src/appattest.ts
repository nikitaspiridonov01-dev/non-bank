// App Attest verification.
//
// Proves a `/v1/parse-receipt` request comes from a genuine, unmodified
// instance of the iOS app running on real Apple hardware. Two phases,
// mirroring `ios/.../AppAttestService.swift`:
//
//   1. Attestation (one-time per install): the client attests a Secure
//      Enclave key against a server challenge. We verify the attestation
//      certificate chains to Apple's App Attest Root CA, that the
//      embedded nonce binds our challenge + authenticator data, that the
//      app-id and key-id match, then pin the public key in D1.
//   2. Assertion (every request): the client signs a fresh
//      {timestamp, nonce} blob with the attested key. We verify the
//      signature against the pinned public key and that the Secure
//      Enclave counter strictly increased (replay protection).
//
// Cert-chain validation uses `@peculiar/x509` (WebCrypto-backed, runs in
// Workers). Everything else (CBOR decode, DER ECDSA→raw, authenticator-
// data parsing) is hand-rolled against the fixed binary layouts — those
// are pure parsing, not trust decisions.

import * as x509 from "@peculiar/x509";

x509.cryptoProvider.set(crypto as Crypto);

// Apple App Attestation Root CA (fetched from
// apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem,
// SHA256 fingerprint 1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:
// 4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32). Valid 2020–2045.
const APPLE_APP_ATTEST_ROOT_CA_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

const APP_ATTEST_OID_NONCE = "1.2.840.113635.100.8.2";

// aaguid values in the authenticator data identify the attestation
// environment. `appattest` + 7 zero bytes = production; the ASCII
// string `appattestdevelop` = development (Xcode-signed builds).
const AAGUID_PROD = new Uint8Array([0x61,0x70,0x70,0x61,0x74,0x74,0x65,0x73,0x74,0,0,0,0,0,0,0]);
const AAGUID_DEV = new TextEncoder().encode("appattestdevelop");

/// Tolerance for the per-request client-data timestamp, in seconds.
const ASSERTION_FRESHNESS_SECONDS = 300;
/// TTL for an issued attestation challenge, in seconds.
const CHALLENGE_TTL_SECONDS = 300;

// ─── CBOR (minimal decoder) ───────────────────────────────────────────
//
// Handles only the structures Apple emits: maps with text keys, byte
// strings, arrays, and unsigned ints. Pure parsing — no trust here.

interface CborCursor { buf: Uint8Array; pos: number; }

function cborRead(c: CborCursor): unknown {
  const first = c.buf[c.pos++];
  const major = first >> 5;
  const minor = first & 0x1f;
  const len = cborLength(c, minor);
  switch (major) {
    case 0: return len; // unsigned int
    case 2: { // byte string
      const out = c.buf.subarray(c.pos, c.pos + len);
      c.pos += len;
      return out;
    }
    case 3: { // text string
      const out = new TextDecoder().decode(c.buf.subarray(c.pos, c.pos + len));
      c.pos += len;
      return out;
    }
    case 4: { // array
      const arr: unknown[] = [];
      for (let i = 0; i < len; i++) arr.push(cborRead(c));
      return arr;
    }
    case 5: { // map
      const map: Record<string, unknown> = {};
      for (let i = 0; i < len; i++) {
        const key = cborRead(c);
        map[String(key)] = cborRead(c);
      }
      return map;
    }
    default:
      throw new Error(`unsupported CBOR major type ${major}`);
  }
}

function cborLength(c: CborCursor, minor: number): number {
  if (minor < 24) return minor;
  if (minor === 24) return c.buf[c.pos++];
  if (minor === 25) { const v = (c.buf[c.pos] << 8) | c.buf[c.pos + 1]; c.pos += 2; return v; }
  if (minor === 26) {
    const v = (c.buf[c.pos] * 0x1000000) + (c.buf[c.pos + 1] << 16) + (c.buf[c.pos + 2] << 8) + c.buf[c.pos + 3];
    c.pos += 4; return v;
  }
  throw new Error(`unsupported CBOR length ${minor}`);
}

function decodeCbor(bytes: Uint8Array): unknown {
  return cborRead({ buf: bytes, pos: 0 });
}

// ─── byte helpers ─────────────────────────────────────────────────────

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function bytesToB64(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

async function sha256(...parts: Uint8Array[]): Promise<Uint8Array> {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const joined = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { joined.set(p, off); off += p.length; }
  return new Uint8Array(await crypto.subtle.digest("SHA-256", joined));
}

// ─── stateless HMAC challenge ─────────────────────────────────────────
//
// challenge bytes = random(16) || ts(4 BE) || HMAC-SHA256(secret, random||ts)[:16].
// No storage: verification recomputes the MAC and checks freshness.

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
}

export async function issueChallenge(secret: string, nowSec: number): Promise<string> {
  const rand = crypto.getRandomValues(new Uint8Array(16));
  const ts = new Uint8Array(4);
  new DataView(ts.buffer).setUint32(0, nowSec, false);
  const key = await hmacKey(secret);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, concat(rand, ts))).subarray(0, 16);
  return bytesToB64(concat(rand, ts, mac));
}

async function verifyChallenge(secret: string, challengeB64: string, nowSec: number): Promise<Uint8Array | null> {
  let bytes: Uint8Array;
  try { bytes = b64ToBytes(challengeB64); } catch { return null; }
  if (bytes.length !== 36) return null;
  const rand = bytes.subarray(0, 16);
  const ts = bytes.subarray(16, 20);
  const mac = bytes.subarray(20, 36);
  const key = await hmacKey(secret);
  const expected = new Uint8Array(await crypto.subtle.sign("HMAC", key, concat(rand, ts))).subarray(0, 16);
  if (!bytesEqual(mac, expected)) return null;
  const issuedAt = new DataView(ts.buffer, ts.byteOffset, 4).getUint32(0, false);
  if (nowSec - issuedAt > CHALLENGE_TTL_SECONDS || issuedAt - nowSec > 60) return null;
  return bytes; // the full challenge bytes are what the client hashed
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}

// ─── authenticator data ───────────────────────────────────────────────

interface AuthData {
  rpIdHash: Uint8Array;   // 32
  counter: number;        // 4 BE
  aaguid?: Uint8Array;    // 16, attestation only
  credentialId?: Uint8Array;
}

function parseAuthData(authData: Uint8Array, withCredential: boolean): AuthData {
  const rpIdHash = authData.subarray(0, 32);
  const counter = new DataView(authData.buffer, authData.byteOffset + 33, 4).getUint32(0, false);
  if (!withCredential) return { rpIdHash, counter };
  const aaguid = authData.subarray(37, 53);
  const credIdLen = new DataView(authData.buffer, authData.byteOffset + 53, 2).getUint16(0, false);
  const credentialId = authData.subarray(55, 55 + credIdLen);
  return { rpIdHash, counter, aaguid, credentialId };
}

// Extract the 32-byte nonce from the App Attest credCert extension. The
// value is the fixed DER shape `SEQUENCE { [1] { OCTET STRING(32) } }`;
// we locate the `04 20` (OCTET STRING, length 32) marker.
function nonceFromExtension(extValue: Uint8Array): Uint8Array | null {
  for (let i = 0; i + 34 <= extValue.length; i++) {
    if (extValue[i] === 0x04 && extValue[i + 1] === 0x20) {
      return extValue.subarray(i + 2, i + 34);
    }
  }
  return null;
}

// ─── DER ECDSA signature → raw (r||s) for WebCrypto ───────────────────

function derEcdsaToRaw(der: Uint8Array): Uint8Array {
  // SEQUENCE { INTEGER r, INTEGER s }
  let i = 0;
  if (der[i++] !== 0x30) throw new Error("bad ECDSA DER");
  i++; // seq length (single byte for our sizes)
  if (der[i++] !== 0x02) throw new Error("bad ECDSA DER r");
  let rLen = der[i++];
  let r = der.subarray(i, i + rLen); i += rLen;
  if (der[i++] !== 0x02) throw new Error("bad ECDSA DER s");
  let sLen = der[i++];
  let s = der.subarray(i, i + sLen);
  return concat(leftPad32(stripLeadingZero(r)), leftPad32(stripLeadingZero(s)));
}

function stripLeadingZero(b: Uint8Array): Uint8Array {
  let start = 0;
  while (start < b.length - 1 && b[start] === 0) start++;
  return b.subarray(start);
}

function leftPad32(b: Uint8Array): Uint8Array {
  if (b.length >= 32) return b.subarray(b.length - 32);
  const out = new Uint8Array(32);
  out.set(b, 32 - b.length);
  return out;
}

// ─── attestation verification ─────────────────────────────────────────

export interface AttestEnv {
  appId: string;          // "<TeamID>.<BundleID>"
  expectDev: boolean;     // staging accepts the dev aaguid
}

export interface AttestResult {
  ok: boolean;
  reason?: string;
  publicKeyB64?: string;  // raw uncompressed P-256 point, base64
}

export async function verifyAttestation(
  params: { keyId: string; attestationB64: string; challengeB64: string },
  secret: string,
  attEnv: AttestEnv,
  nowSec: number,
): Promise<AttestResult> {
  const challengeBytes = await verifyChallenge(secret, params.challengeB64, nowSec);
  if (!challengeBytes) return { ok: false, reason: "bad_challenge" };

  let att: Record<string, unknown>;
  try {
    att = decodeCbor(b64ToBytes(params.attestationB64)) as Record<string, unknown>;
  } catch {
    return { ok: false, reason: "bad_cbor" };
  }
  if (att.fmt !== "apple-appattest") return { ok: false, reason: "bad_fmt" };
  const attStmt = att.attStmt as Record<string, unknown>;
  const authData = att.authData as Uint8Array;
  const x5c = attStmt.x5c as Uint8Array[];
  if (!Array.isArray(x5c) || x5c.length < 2) return { ok: false, reason: "no_x5c" };

  // 1. Cert chain: credCert ← intermediate ← Apple root.
  let credCert: x509.X509Certificate;
  try {
    credCert = new x509.X509Certificate(x5c[0]);
    const intermediate = new x509.X509Certificate(x5c[1]);
    const root = new x509.X509Certificate(APPLE_APP_ATTEST_ROOT_CA_PEM);
    const now = new Date(nowSec * 1000);
    const chainOk =
      (await credCert.verify({ publicKey: intermediate.publicKey, signatureOnly: true })) &&
      (await intermediate.verify({ publicKey: root.publicKey, signatureOnly: true })) &&
      credCert.notBefore <= now && now <= credCert.notAfter &&
      intermediate.notBefore <= now && now <= intermediate.notAfter;
    if (!chainOk) return { ok: false, reason: "bad_chain" };
  } catch {
    return { ok: false, reason: "chain_error" };
  }

  // 2. Nonce: SHA256(authData || SHA256(challenge)) must equal the nonce
  //    embedded in the credCert extension.
  const clientDataHash = await sha256(challengeBytes);
  const expectedNonce = await sha256(authData, clientDataHash);
  const ext = credCert.getExtension(APP_ATTEST_OID_NONCE);
  if (!ext) return { ok: false, reason: "no_nonce_ext" };
  const certNonce = nonceFromExtension(new Uint8Array(ext.value));
  if (!certNonce || !bytesEqual(certNonce, expectedNonce)) return { ok: false, reason: "nonce_mismatch" };

  // 3. authData checks.
  const parsed = parseAuthData(authData, true);
  const appIdHash = await sha256(new TextEncoder().encode(attEnv.appId));
  if (!bytesEqual(parsed.rpIdHash, appIdHash)) return { ok: false, reason: "app_id_mismatch" };
  if (parsed.counter !== 0) return { ok: false, reason: "counter_not_zero" };
  const aaguidOk = attEnv.expectDev
    ? (bytesEqual(parsed.aaguid!, AAGUID_DEV) || bytesEqual(parsed.aaguid!, AAGUID_PROD))
    : bytesEqual(parsed.aaguid!, AAGUID_PROD);
  if (!aaguidOk) return { ok: false, reason: "aaguid_mismatch" };
  const keyIdBytes = b64ToBytes(params.keyId);
  if (!bytesEqual(parsed.credentialId!, keyIdBytes)) return { ok: false, reason: "key_id_mismatch" };

  // 4. Extract + return the attested public key (raw uncompressed point)
  //    for assertion verification later.
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", await credCert.publicKey.export()));
  return { ok: true, publicKeyB64: bytesToB64(raw) };
}

// ─── assertion verification ───────────────────────────────────────────

export interface AssertionResult {
  ok: boolean;
  reason?: string;
  newCounter?: number;
}

export async function verifyAssertion(
  params: {
    keyId: string;
    assertionB64: string;
    clientDataB64: string;
    storedPublicKeyB64: string;
    storedCounter: number;
  },
  attEnv: AttestEnv,
  nowSec: number,
): Promise<AssertionResult> {
  // Client data: {"t": <unix>, "n": "<nonce>"}; check freshness.
  let clientData: Uint8Array;
  try { clientData = b64ToBytes(params.clientDataB64); } catch { return { ok: false, reason: "bad_client_data" }; }
  let t: number;
  try { t = (JSON.parse(new TextDecoder().decode(clientData)) as { t: number }).t; } catch { return { ok: false, reason: "bad_client_json" }; }
  if (typeof t !== "number" || Math.abs(nowSec - t) > ASSERTION_FRESHNESS_SECONDS) {
    return { ok: false, reason: "stale" };
  }

  let assertion: Record<string, unknown>;
  try { assertion = decodeCbor(b64ToBytes(params.assertionB64)) as Record<string, unknown>; }
  catch { return { ok: false, reason: "bad_cbor" }; }
  const signatureDer = assertion.signature as Uint8Array;
  const authData = assertion.authenticatorData as Uint8Array;
  if (!signatureDer || !authData) return { ok: false, reason: "bad_assertion" };

  // rpIdHash + counter checks.
  const parsed = parseAuthData(authData, false);
  const appIdHash = await sha256(new TextEncoder().encode(attEnv.appId));
  if (!bytesEqual(parsed.rpIdHash, appIdHash)) return { ok: false, reason: "app_id_mismatch" };
  if (parsed.counter <= params.storedCounter) return { ok: false, reason: "replay" };

  // Signature: WebCrypto ECDSA-SHA256 over (authData || clientDataHash)
  // re-derives nonce = SHA256(authData || clientDataHash) internally and
  // verifies, matching what the Secure Enclave signed.
  const clientDataHash = await sha256(clientData);
  const pubKey = await crypto.subtle.importKey(
    "raw", b64ToBytes(params.storedPublicKeyB64),
    { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"],
  );
  let sigRaw: Uint8Array;
  try { sigRaw = derEcdsaToRaw(signatureDer); } catch { return { ok: false, reason: "bad_sig_der" }; }
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, pubKey, sigRaw, concat(authData, clientDataHash),
  );
  if (!valid) return { ok: false, reason: "bad_signature" };

  return { ok: true, newCounter: parsed.counter };
}

// ─── D1 key store ─────────────────────────────────────────────────────

export interface StoredKey { public_key: string; counter: number; }

export async function getStoredKey(db: D1Database, keyId: string): Promise<StoredKey | null> {
  return db.prepare("SELECT public_key, counter FROM attest_keys WHERE key_id = ?1")
    .bind(keyId).first<StoredKey>();
}

export async function storeKey(db: D1Database, keyId: string, publicKeyB64: string, env: string, nowSec: number): Promise<void> {
  await db.prepare(
    `INSERT INTO attest_keys (key_id, public_key, counter, env, created_at, last_used_at)
     VALUES (?1, ?2, 0, ?3, ?4, ?4)
     ON CONFLICT(key_id) DO UPDATE SET public_key = ?2, counter = 0, last_used_at = ?4`,
  ).bind(keyId, publicKeyB64, env, nowSec).run();
}

export async function bumpCounter(db: D1Database, keyId: string, newCounter: number, nowSec: number): Promise<void> {
  await db.prepare("UPDATE attest_keys SET counter = ?2, last_used_at = ?3 WHERE key_id = ?1")
    .bind(keyId, newCounter, nowSec).run();
}
