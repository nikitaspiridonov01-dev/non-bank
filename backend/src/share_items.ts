// Server-side storage for the receipt items associated with a share
// link. Pairs with the existing `/share` HTML preview by reusing the
// payload `checksum` as the row key: iOS generates the URL exactly
// as before, then uploads the items (E2E-encrypted client-side) under
// that checksum. Recipients fetch the ciphertext back, decrypt with a
// URL-derived key, and reconstruct `byItems` mode locally.
//
// Storage is opaque from the Worker's perspective — it stores a base64
// ciphertext blob and a few timestamps. The Worker can't read the
// items it persists, so a database leak doesn't expose receipt
// contents; only someone who already has the share URL (and therefore
// the encryption key) can decrypt.

import { bumpIpParseQuota } from "./quota.ts";
import { logEvent } from "./log.ts";

// Minimum slice of the Worker `Env` that the items endpoints need.
// Same pattern as `ShareEnv` in `share.ts` — keep the shared bindings
// list narrow per route to make the data flow obvious.
export interface ShareItemsEnv {
  DB: D1Database;
  IP_HASH_SALT?: string;
  PER_IP_DAILY_LIMIT?: string;
  LOG_LEVEL?: string;
}

// Cap on the ciphertext bundle in bytes. Picked at ~10 KB so a
// 100-item receipt with name + per-item assignees comfortably fits
// (real-world receipts max out around ~30 items × ~150 B = 4.5 KB
// plaintext; ciphertext is +~40 B for nonce+tag plus base64 inflation
// ~33%). Rows that exceed this are 413'd at the API layer rather
// than silently truncated — the iOS side falls back to byAmount.
const MAX_PAYLOAD_BYTES = 10 * 1024;

const TTL_SECONDS = 30 * 24 * 60 * 60;

const SHARE_ID_PATTERN = /^[0-9a-f]{64}$/;

/// POST /v1/share-items/:share_id
/// Body: { payload: "<base64>" }
/// Upserts the row keyed by `share_id` (payload checksum), refreshes
/// the TTL clock, and returns 201 on insert / 200 on overwrite.
export async function handleUploadShareItems(
  req: Request,
  env: ShareItemsEnv,
  shareID: string,
  ipHash: string,
  nowSec: number,
): Promise<Response> {
  if (!SHARE_ID_PATTERN.test(shareID)) {
    return jsonResponse(
      { error: "bad_request", detail: "share_id must be 64-char hex" },
      400,
    );
  }
  // Re-use the per-IP daily quota that already guards
  // `/v1/parse-receipt`. Sender shares are bursty but bounded; running
  // both endpoints against the same budget keeps the abuse-protection
  // model simple — a single attacker can't drain "items" requests
  // without also burning their parse-receipt budget.
  const limit =
    Number.parseInt(env.PER_IP_DAILY_LIMIT ?? "", 10) || 200;
  const gate = await bumpIpParseQuota(env.DB, ipHash, limit, nowSec);
  if (!gate.ok) {
    return jsonResponse(
      {
        error: "ip_rate_limited",
        detail: `daily limit ${limit} reached for this network`,
        reset_at: gate.reset_at,
      },
      429,
    );
  }

  const contentType = req.headers.get("content-type") ?? "";
  if (!contentType.startsWith("application/json")) {
    return jsonResponse(
      { error: "bad_request", detail: "expected application/json" },
      400,
    );
  }

  // Pre-read Content-Length to reject oversized bodies before the JSON
  // parser allocates. `MAX_PAYLOAD_BYTES` is the ciphertext cap; the
  // JSON envelope adds ~30 bytes of `{"payload":"..."}` overhead, so
  // we accept up to MAX + 256.
  const declaredLength = Number.parseInt(
    req.headers.get("content-length") ?? "0",
    10,
  );
  if (declaredLength > MAX_PAYLOAD_BYTES + 256) {
    return jsonResponse(
      { error: "payload_too_large", detail: `max ${MAX_PAYLOAD_BYTES} bytes` },
      413,
    );
  }

  let body: { payload?: unknown };
  try {
    body = await req.json();
  } catch {
    return jsonResponse(
      { error: "bad_request", detail: "invalid JSON body" },
      400,
    );
  }
  if (typeof body.payload !== "string" || body.payload.length === 0) {
    return jsonResponse(
      { error: "bad_request", detail: "payload (base64) required" },
      400,
    );
  }
  // Base64 expands ~33% so the raw-byte cap maps to ~14 KB of base64.
  // Generous enough to swallow any sane receipt; tight enough that an
  // attacker can't park megabytes of data under a single share-id.
  const ciphertext = body.payload;
  if (ciphertext.length > MAX_PAYLOAD_BYTES * 2) {
    return jsonResponse(
      { error: "payload_too_large", detail: `max ${MAX_PAYLOAD_BYTES} bytes` },
      413,
    );
  }

  // Detect insert vs overwrite up-front so we can return 201 / 200
  // accordingly — REST convention, and lets clients tell whether the
  // first upload of a share or a re-share happened.
  const existing = await env.DB
    .prepare(`SELECT 1 FROM share_items WHERE share_id = ?1`)
    .bind(shareID)
    .first();
  const isInsert = existing == null;

  // Single upsert. `last_opened_at` is bumped to now on upload so a
  // share is "warm" from the moment the sender pushes it, even if no
  // recipient has opened it yet.
  await env.DB
    .prepare(
      `INSERT INTO share_items
         (share_id, payload, payload_size, created_at, expires_at,
          last_opened_at, opens_count)
       VALUES (?1, ?2, ?3, ?4, ?4 + ${TTL_SECONDS}, ?4, 0)
       ON CONFLICT(share_id) DO UPDATE SET
         payload = ?2,
         payload_size = ?3,
         expires_at = ?4 + ${TTL_SECONDS},
         last_opened_at = ?4`,
    )
    .bind(shareID, ciphertext, ciphertext.length, nowSec)
    .run();

  logEvent(env, "info", {
    route: "/v1/share-items POST",
    ip_hash: ipHash,
    share_id: shareID.slice(0, 8),
    payload_size: ciphertext.length,
    insert: isInsert,
  });

  return jsonResponse(
    { ok: true, expires_at: nowSec + TTL_SECONDS },
    isInsert ? 201 : 200,
  );
}

/// GET /v1/share-items/:share_id
/// Returns { payload: "<base64>" } if a non-expired row exists, or
/// 404. As a side-effect, refreshes the row's TTL clock so popular
/// shares stay alive indefinitely while abandoned ones eventually
/// fall out of the table.
export async function handleFetchShareItems(
  env: ShareItemsEnv,
  shareID: string,
  ipHash: string,
  nowSec: number,
): Promise<Response> {
  if (!SHARE_ID_PATTERN.test(shareID)) {
    return jsonResponse(
      { error: "bad_request", detail: "share_id must be 64-char hex" },
      400,
    );
  }
  // Per-IP gate is reused from the upload path — same budget guards
  // GET as POST, see comment above.
  const limit =
    Number.parseInt(env.PER_IP_DAILY_LIMIT ?? "", 10) || 200;
  const gate = await bumpIpParseQuota(env.DB, ipHash, limit, nowSec);
  if (!gate.ok) {
    return jsonResponse(
      {
        error: "ip_rate_limited",
        detail: `daily limit ${limit} reached for this network`,
        reset_at: gate.reset_at,
      },
      429,
    );
  }

  // Filter expired rows at the read site rather than running a
  // separate sweep cron. Cheap (single B-tree probe via the PK
  // index + a comparison) and removes the dependency on a periodic
  // job firing. A future Cron Trigger can prune the table for
  // forensics, but correctness doesn't depend on it.
  const row = await env.DB
    .prepare(
      `SELECT payload FROM share_items
       WHERE share_id = ?1 AND expires_at > ?2`,
    )
    .bind(shareID, nowSec)
    .first<{ payload: string }>();

  if (!row) {
    logEvent(env, "info", {
      route: "/v1/share-items GET",
      ip_hash: ipHash,
      share_id: shareID.slice(0, 8),
      hit: false,
    });
    return jsonResponse({ error: "not_found" }, 404);
  }

  // Refresh TTL + bump access stats on each hit. Two-statement is OK:
  // the worst case (race between GET and DELETE-on-expiry) lets one
  // extra fetch through, which is harmless. We keep the UPDATE
  // unconditional rather than rate-limiting (e.g. "only refresh if
  // last_opened_at > 1 hour ago") because writes are well within
  // budget; cleverness has a maintenance cost we don't need.
  await env.DB
    .prepare(
      `UPDATE share_items
       SET last_opened_at = ?2,
           expires_at = ?2 + ${TTL_SECONDS},
           opens_count = opens_count + 1
       WHERE share_id = ?1`,
    )
    .bind(shareID, nowSec)
    .run();

  logEvent(env, "info", {
    route: "/v1/share-items GET",
    ip_hash: ipHash,
    share_id: shareID.slice(0, 8),
    hit: true,
  });

  return jsonResponse({ payload: row.payload }, 200);
}

/// Cron-triggered sweep that drops rows whose `expires_at` is in the
/// past. The read path already filters expired rows from responses
/// (see `handleFetchShareItems`), so correctness doesn't depend on
/// this — its job is purely to bound D1 storage growth. Without it
/// the table accumulates ciphertext indefinitely (5 GB Free-tier cap
/// would still take years to hit at our scale, but housekeeping is
/// cheap and worth doing).
///
/// Uses the `idx_share_items_expires` B-tree from the migration so
/// the WHERE scan is index-driven, not a table scan.
export async function sweepExpiredShareItems(
  env: ShareItemsEnv,
  nowSec: number,
): Promise<{ deleted: number }> {
  const result = await env.DB
    .prepare(`DELETE FROM share_items WHERE expires_at <= ?1`)
    .bind(nowSec)
    .run();
  // D1's `meta.changes` is the post-delete row count. Safe to access
  // even on zero-row sweeps (returns 0).
  const deleted = result.meta?.changes ?? 0;
  logEvent(env, "info", {
    route: "cron sweepExpiredShareItems",
    deleted,
  });
  return { deleted };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
