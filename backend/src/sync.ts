// Server-mediated split-transaction sync — shared D1 helpers.
//
// Phase 0: friend pairing. The route handler (attestation gate + per-IP
// quota + request parsing) lives in `index.ts`; the pure D1 helpers live
// here so `index.ts` ↔ `sync.ts` stays a one-way import (no cycle).
//
// Privacy: the server stores only an opaque client-computed HMAC of the
// sorted (userA, userB) pair — never the raw ids — so it cannot enumerate
// the social graph (see migrations/0006_sync_pairings.sql).

/// A pairing key is a 64-hex client-computed HMAC. Reject anything else
/// so a malformed body can't insert junk rows.
export function isValidPairHmac(s: unknown): s is string {
  return typeof s === "string" && /^[0-9a-f]{64}$/.test(s);
}

/// Record (or re-activate) a pairing. Idempotent: re-pairing the same two
/// users — e.g. opening a fresh link from an already-paired friend —
/// upserts the same row and (re)sets it active rather than inserting a
/// duplicate.
export async function upsertPairing(
  db: D1Database,
  pairHmac: string,
  nowSec: number,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO pairings (pair_hmac, created_at, status)
       VALUES (?1, ?2, 'active')
       ON CONFLICT(pair_hmac) DO UPDATE SET status = 'active'`,
    )
    .bind(pairHmac, nowSec)
    .run();
}

/// Trust-on-first-use bind of an attested Secure-Enclave key to its
/// logical app user id, so Phase 1's upload/pull can resolve the caller's
/// user from the attested key. Only ever called after the attestation
/// gate has verified the key, so the key row already exists.
export async function bindKeyUser(
  db: D1Database,
  keyId: string,
  userId: string,
  nowSec: number,
): Promise<void> {
  await db
    .prepare(
      `UPDATE attest_keys SET user_id = ?2, last_used_at = ?3 WHERE key_id = ?1`,
    )
    .bind(keyId, userId, nowSec)
    .run();
}
