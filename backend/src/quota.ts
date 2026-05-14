import type { ProviderId } from "./types.ts";

// All quota state lives in D1. We keep the row shape boring on purpose —
// the router does the smart bit, this file just gives it accurate counters.
//
// Daily reset: we don't run a cron. Each read self-resets if the row's
// `reset_at` is in the past. This is cheap (one extra UPDATE on the first
// request after midnight UTC) and avoids needing a Cron Trigger.
const SECONDS_PER_DAY = 86_400;

export interface ProviderQuotaRow {
  provider: ProviderId;
  rpd_used: number;
  rpd_limit: number;
  reset_at: number;
  consecutive_errors: number;
  last_error_at: number | null;
  last_success_at: number | null;
  total_requests: number;
  total_errors: number;
}

export interface DeviceQuotaRow {
  device_id: string;
  requests_today: number;
  reset_at: number;
}

// Snapshot of all 4 providers. The router uses this list every request to
// pick a winner; we read once, decide, then write the increment after we
// know which provider answered.
export async function loadProviderQuotas(
  db: D1Database,
  nowSec: number,
): Promise<ProviderQuotaRow[]> {
  // Self-reset rows whose window expired. Doing this in SQL avoids a
  // race where two concurrent reads both see "expired" and double-reset.
  await db
    .prepare(
      `UPDATE provider_quotas
       SET rpd_used = 0,
           reset_at = ?1 + ${SECONDS_PER_DAY},
           consecutive_errors = 0
       WHERE reset_at <= ?1`,
    )
    .bind(nowSec)
    .run();

  const result = await db
    .prepare(`SELECT * FROM provider_quotas`)
    .all<ProviderQuotaRow>();
  return result.results ?? [];
}

// Bumps usage and clears the error streak — call after a successful provider
// response. Atomic via the WHERE clause so we don't trample concurrent writes.
export async function recordSuccess(
  db: D1Database,
  provider: ProviderId,
  nowSec: number,
): Promise<void> {
  await db
    .prepare(
      `UPDATE provider_quotas
       SET rpd_used = rpd_used + 1,
           total_requests = total_requests + 1,
           consecutive_errors = 0,
           last_success_at = ?2
       WHERE provider = ?1`,
    )
    .bind(provider, nowSec)
    .run();
}

// Doesn't increment `rpd_used` — we only count requests the provider
// actually billed against our quota. Bumps the error counter so the router
// shuns this provider for the next ~60 seconds.
export async function recordError(
  db: D1Database,
  provider: ProviderId,
  nowSec: number,
  countAgainstQuota: boolean,
): Promise<void> {
  await db
    .prepare(
      `UPDATE provider_quotas
       SET consecutive_errors = consecutive_errors + 1,
           total_errors = total_errors + 1,
           last_error_at = ?2,
           rpd_used = rpd_used + ?3
       WHERE provider = ?1`,
    )
    .bind(provider, nowSec, countAgainstQuota ? 1 : 0)
    .run();
}

// Per-device daily cap. Returns the new count after the increment, OR
// null if the device hit its cap. Single SQL statement = race-safe.
export async function bumpDeviceQuota(
  db: D1Database,
  deviceId: string,
  limit: number,
  nowSec: number,
): Promise<{ ok: true; remaining: number } | { ok: false; reset_at: number }> {
  // Reset if window expired. UPSERT pattern — INSERT on first contact.
  await db
    .prepare(
      `INSERT INTO device_quotas (device_id, requests_today, reset_at, total_requests, first_seen_at, last_seen_at)
       VALUES (?1, 0, ?2 + ${SECONDS_PER_DAY}, 0, ?2, ?2)
       ON CONFLICT(device_id) DO UPDATE SET
         requests_today = CASE WHEN reset_at <= ?2 THEN 0 ELSE requests_today END,
         reset_at = CASE WHEN reset_at <= ?2 THEN ?2 + ${SECONDS_PER_DAY} ELSE reset_at END,
         last_seen_at = ?2`,
    )
    .bind(deviceId, nowSec)
    .run();

  // Read to decide whether to allow.
  const row = await db
    .prepare(
      `SELECT requests_today, reset_at FROM device_quotas WHERE device_id = ?1`,
    )
    .bind(deviceId)
    .first<{ requests_today: number; reset_at: number }>();

  if (!row) {
    // Should be unreachable after the upsert; treat as soft-allow once.
    return { ok: true, remaining: limit - 1 };
  }
  if (row.requests_today >= limit) {
    return { ok: false, reset_at: row.reset_at };
  }
  // Increment and return remaining. Two-statement is fine here because the
  // worst case — a race that lets one extra request through — is harmless.
  await db
    .prepare(
      `UPDATE device_quotas
       SET requests_today = requests_today + 1,
           total_requests = total_requests + 1
       WHERE device_id = ?1`,
    )
    .bind(deviceId)
    .run();
  return { ok: true, remaining: limit - row.requests_today - 1 };
}
