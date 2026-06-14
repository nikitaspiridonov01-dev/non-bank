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

// ─── Phase 1: addressed deliveries ────────────────────────────────────

/// Hard TTL backstop for a delivery a recipient never pulls (e.g. they
/// uninstalled). 14 days keeps the table bounded without dropping a
/// delivery before a friend who only opens the app occasionally sees it.
export const DELIVERY_TTL_SECONDS = 14 * 24 * 60 * 60;

/// Max ciphertext bundle (base64) for one delivery — mirrors the
/// share-items cap (~10 KB plaintext → ~14 KB base64). A whole split
/// transaction + receipt items fits comfortably; anything larger is the
/// client's cue to fall back to the manual share sheet.
export const MAX_DELIVERY_PAYLOAD_BYTES = 14 * 1024;

/// User ids are non-PII adjective-noun-4digit strings. Validate length
/// rather than format so the server doesn't encode client naming rules;
/// the App-Attest gate is what actually authenticates the caller.
export function isValidUserId(s: unknown): s is string {
  return typeof s === "string" && s.length >= 3 && s.length <= 64;
}

/// Transaction sync ids are client-generated opaque tokens. Bound the
/// length so a malformed body can't store oversized keys.
export function isValidSyncId(s: unknown): s is string {
  return typeof s === "string" && s.length >= 1 && s.length <= 128;
}

/// A delivery version is a non-negative monotonic integer.
export function isValidVersion(n: unknown): n is number {
  return typeof n === "number" && Number.isInteger(n) && n >= 0;
}

export function isValidOp(s: unknown): s is "upsert" | "delete" {
  return s === "upsert" || s === "delete";
}

/// Resolve the logical user id bound (trust-on-first-use) to an attested
/// key, so the inbox/ack routes can enforce "a device reads only its own
/// inbox". Null when the key isn't bound (pre-attestation rows / lenient
/// simulator dev).
export async function getKeyUserId(
  db: D1Database,
  keyId: string,
): Promise<string | null> {
  const row = await db
    .prepare(`SELECT user_id FROM attest_keys WHERE key_id = ?1`)
    .bind(keyId)
    .first<{ user_id: string | null }>();
  return row?.user_id ?? null;
}

/// True iff an ACTIVE pairing exists for this opaque pair HMAC. Gates
/// uploads so a delivery can only be addressed within a live pairing —
/// and so a `revoke` (friend removal) immediately stops new deliveries.
export async function isPairingActive(
  db: D1Database,
  pairHmac: string,
): Promise<boolean> {
  const row = await db
    .prepare(
      `SELECT 1 FROM pairings WHERE pair_hmac = ?1 AND status = 'active'`,
    )
    .bind(pairHmac)
    .first();
  return row != null;
}

/// Version-guarded UPSERT of one addressed delivery. The `WHERE
/// excluded.version > pending_deliveries.version` on the conflict branch
/// is the collision guard: a stale (lower-or-equal version) re-delivery
/// is a no-op, so an out-of-order edit can never clobber a newer one, and
/// equal-version races resolve by server-received order (first wins).
/// A newer edit clears acked_at/delete_after so the recipient re-pulls.
/// Returns whether the row was actually written (false = stale no-op).
export async function recordDelivery(
  db: D1Database,
  d: {
    recipientId: string;
    txSyncId: string;
    version: number;
    op: "upsert" | "delete";
    payload: string;
    checksum: string | null;
  },
  nowSec: number,
): Promise<{ applied: boolean }> {
  const result = await db
    .prepare(
      `INSERT INTO pending_deliveries
         (recipient_id, tx_sync_id, version, op, payload, checksum,
          created_at, updated_at, expires_at, acked_at, delete_after)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?7 + ${DELIVERY_TTL_SECONDS}, NULL, NULL)
       ON CONFLICT(recipient_id, tx_sync_id) DO UPDATE SET
         version      = excluded.version,
         op           = excluded.op,
         payload      = excluded.payload,
         checksum     = excluded.checksum,
         updated_at   = excluded.updated_at,
         expires_at   = excluded.expires_at,
         acked_at     = NULL,
         delete_after = NULL
       WHERE excluded.version > pending_deliveries.version`,
    )
    .bind(
      d.recipientId,
      d.txSyncId,
      d.version,
      d.op,
      d.payload,
      d.checksum,
      nowSec,
    )
    .run();
  return { applied: (result.meta?.changes ?? 0) > 0 };
}

export interface InboxDelivery {
  tx_sync_id: string;
  version: number;
  op: string;
  payload: string;
  checksum: string | null;
}

/// Fetch one recipient's un-acked, non-expired inbox. Idempotent: no TTL
/// extension and no delete-on-read, so a crash between pull and ack just
/// re-delivers (the client apply is itself idempotent via syncID+version).
export async function fetchInbox(
  db: D1Database,
  recipientId: string,
  nowSec: number,
): Promise<InboxDelivery[]> {
  const res = await db
    .prepare(
      `SELECT tx_sync_id, version, op, payload, checksum
         FROM pending_deliveries
        WHERE recipient_id = ?1 AND acked_at IS NULL AND expires_at > ?2
        ORDER BY updated_at ASC`,
    )
    .bind(recipientId, nowSec)
    .all<InboxDelivery>();
  return res.results ?? [];
}

/// Start of the next UTC day — when an acked delivery becomes sweepable.
/// Deferring the delete to the next day (rather than deleting on ack)
/// gives a re-pull grace window if the ack races a concurrent re-edit.
export function nextUtcDayStart(nowSec: number): number {
  const day = 24 * 60 * 60;
  return (Math.floor(nowSec / day) + 1) * day;
}

/// Ack delivered rows. Only acks a row when the recipient confirms the
/// version it actually applied is >= the stored version — so a newer edit
/// that arrived AFTER the recipient pulled is NOT acked away, and will be
/// re-pulled. Sets delete_after to the next UTC day for the cron sweep.
export async function ackDeliveries(
  db: D1Database,
  recipientId: string,
  acks: { txSyncId: string; version: number }[],
  nowSec: number,
): Promise<{ acked: number }> {
  const deleteAfter = nextUtcDayStart(nowSec);
  let acked = 0;
  for (const a of acks) {
    const result = await db
      .prepare(
        `UPDATE pending_deliveries
            SET acked_at = ?3, delete_after = ?4
          WHERE recipient_id = ?1 AND tx_sync_id = ?2 AND version <= ?5`,
      )
      .bind(recipientId, a.txSyncId, nowSec, deleteAfter, a.version)
      .run();
    acked += result.meta?.changes ?? 0;
  }
  return { acked };
}

/// Flip a pairing to 'revoked' (friend removal). Idempotent. After this,
/// `isPairingActive` is false so the upload route refuses new deliveries
/// for the pair — the server-side half of "removing a friend stops sync".
export async function revokePairing(
  db: D1Database,
  pairHmac: string,
): Promise<void> {
  await db
    .prepare(`UPDATE pairings SET status = 'revoked' WHERE pair_hmac = ?1`)
    .bind(pairHmac)
    .run();
}

/// Cron sweep: drop acked rows past their delete_after grace window and
/// any hard-TTL-expired rows. Mirrors `sweepExpiredShareItems`; the pull
/// path already filters expired rows so correctness doesn't depend on it —
/// it just bounds table growth.
export async function sweepExpiredDeliveries(
  db: D1Database,
  nowSec: number,
): Promise<{ deleted: number }> {
  const result = await db
    .prepare(
      `DELETE FROM pending_deliveries
        WHERE (delete_after IS NOT NULL AND delete_after <= ?1)
           OR expires_at <= ?1`,
    )
    .bind(nowSec)
    .run();
  return { deleted: result.meta?.changes ?? 0 };
}
