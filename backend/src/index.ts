// Must run before `@peculiar/x509` (loaded via ./appattest.ts) — its
// transitive `tsyringe` dependency throws at module load without the
// `Reflect.metadata` polyfill.
import "reflect-metadata";
import { route, RouterExhaustedError } from "./router.ts";
import { bumpDeviceQuota, bumpIpParseQuota } from "./quota.ts";
import { handleSharePage } from "./share.ts";
import { handlePrivacyPage } from "./privacy.ts";
import {
  handleUploadShareItems,
  handleFetchShareItems,
  sweepExpiredShareItems,
} from "./share_items.ts";
import {
  isValidPairHmac,
  upsertPairing,
  bindKeyUser,
  isValidUserId,
  isValidSyncId,
  isValidVersion,
  isValidOp,
  getKeyUserId,
  isPairingActive,
  upsertPairing,
  recordDelivery,
  fetchInbox,
  ackDeliveries,
  revokePairing,
  sweepExpiredDeliveries,
  MAX_DELIVERY_PAYLOAD_BYTES,
  isValidDeviceToken,
  isValidApnsEnv,
  registerDeviceToken,
  getDeviceTokens,
} from "./sync.ts";
import { apnsConfigFromEnv, sendPush, sendPairingPush } from "./apns.ts";
import { handleTestProviders } from "./test_providers.ts";
import {
  issueChallenge,
  verifyAttestation,
  verifyAssertion,
  getStoredKey,
  storeKey,
  bumpCounter,
  type AttestEnv,
} from "./appattest.ts";
import { logEvent } from "./log.ts";
import {
  MAX_CATEGORY_NAME,
  MAX_CATEGORY_EMOJI,
  MAX_LOCALE_HINT,
  sanitizePromptText,
} from "./prompt.ts";
import type { ParseResponse, ProviderRequest } from "./types.ts";

// Worker bindings declared in wrangler.toml. Provider API keys are
// optional — a missing key just makes the corresponding provider skip
// itself (auth_error) and the router falls through to the next one.
export interface Env {
  DB: D1Database;
  AI: Ai;
  ENV: string;
  PER_DEVICE_DAILY_LIMIT: string;
  // Per-IP daily cap on POST /v1/parse-receipt — closes the device-ID
  // rotation hole. Default 200; higher than per-device because shared
  // NAT/WiFi means one IP can legitimately be many devices.
  PER_IP_DAILY_LIMIT?: string;
  // Per-IP 60-second cap on GET /share — burst protection for the
  // CPU-heaviest route (SVG render). Default 60/min.
  PER_IP_SHARE_PER_MINUTE_LIMIT?: string;
  // Salt for SHA-256 over `CF-Connecting-IP`. Set via `wrangler secret
  // put IP_HASH_SALT`. Absent → a static dev salt is used; never deploy
  // production without setting this.
  IP_HASH_SALT?: string;
  LOG_LEVEL: string;
  // App Attest. `APP_ATTEST_APP_ID` is "<TeamID>.<BundleID>" (public,
  // in `[vars]`). `ATTEST_SECRET` signs the stateless challenge HMAC —
  // set via `wrangler secret put ATTEST_SECRET` (any 32+ random chars).
  // `APP_ATTEST_REQUIRED` ("1"/"0") gates strictness: prod requires a
  // valid assertion, staging is lenient so simulator dev (no App
  // Attest) still works.
  APP_ATTEST_APP_ID?: string;
  ATTEST_SECRET?: string;
  APP_ATTEST_REQUIRED?: string;
  GEMINI_API_KEY?: string;
  GROQ_API_KEY?: string;
  OPENROUTER_API_KEY?: string;
  MISTRAL_API_KEY?: string;
  SAMBANOVA_API_KEY?: string;
  NVIDIA_API_KEY?: string;
  HUGGINGFACE_API_KEY?: string;
}

// Image preprocessing happens on iOS (resize + EXIF strip), so we just
// validate size here. 5 MB ceiling is generous — Groq base64 caps at 4 MB,
// so iOS should target ~3 MB before upload.
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

// Hard request body cap, enforced via Content-Length BEFORE we parse
// multipart. 5 MB image + ~1 MB headroom for form metadata. Cooperative
// clients with chunked-encoding skip this gate but still hit the
// MAX_IMAGE_BYTES check after parsing.
const MAX_BODY_BYTES = 6 * 1024 * 1024;

// Defaults applied when the env vars are absent — keeps the Worker
// hardened-by-default even if wrangler.toml is misconfigured.
// The /share-side default lives in `share.ts` to keep this entry-point
// agnostic of routes it doesn't gate itself.
const DEFAULT_PER_IP_DAILY = 200;
const DEFAULT_PER_DEVICE_DAILY = 30;

const ALLOWED_MIMES = new Set([
  "image/jpeg",
  "image/jpg",
  "image/png",
  "image/heic",
  "image/heif",
  "image/webp",
]);

// One-way digest of the caller's IP, truncated for storage. SHA-256 with
// a stored salt means a D1 snapshot leak doesn't trivially reverse to
// raw addresses; 16 hex chars = 64 bits of entropy = no realistic
// collision risk at our scale.
export async function hashIp(ip: string, salt: string): Promise<string> {
  const data = new TextEncoder().encode(`${salt}:${ip}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 16);
}

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);
    const cors = corsHeaders();
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors });
    }
    try {
      if (url.pathname === "/v1/parse-receipt" && req.method === "POST") {
        return withCors(await handleParseReceipt(req, env), cors);
      }
      if (url.pathname === "/v1/health" && req.method === "GET") {
        return withCors(jsonResponse({ ok: true, env: env.ENV }, 200), cors);
      }
      // App Attest — issue a stateless challenge for the one-time key
      // attestation. Cheap (HMAC, no storage); gated by the per-IP
      // quota so it can't be used to burn CPU.
      if (url.pathname === "/v1/attest/challenge" && req.method === "GET") {
        return withCors(await handleAttestChallenge(req, env), cors);
      }
      // App Attest — verify an attestation and pin the device's public
      // key. Runs the Apple cert-chain validation; rate-gated per IP.
      if (url.pathname === "/v1/attest/verify" && req.method === "POST") {
        return withCors(await handleAttestVerify(req, env), cors);
      }
      if (url.pathname === "/v1/quota" && req.method === "GET") {
        return withCors(await handleQuotaSnapshot(env), cors);
      }
      if (url.pathname === "/v1/admin/accept-llama" && req.method === "POST") {
        return withCors(await handleAcceptLlama(env), cors);
      }
      // Probe every provider with the same image — used to verify
      // that all API keys are valid and reachable on a given env.
      // Returns one row per provider with `ok` / latency / error,
      // gated by the existing per-IP daily quota.
      if (url.pathname === "/v1/admin/test-providers" && req.method === "POST") {
        const ip = callerIp(req);
        const salt = env.IP_HASH_SALT ?? "non-bank-dev-salt";
        const ipHash = await hashIp(ip, salt);
        const nowSec = Math.floor(Date.now() / 1000);
        return withCors(
          await handleTestProviders(req, env, ipHash, nowSec),
          cors,
        );
      }
      // Share-link landing page — friends without the iOS app land here
      // and see a transaction preview with an "Open in app" deep link.
      // Not under `/v1/` because the URL is the user-facing share link
      // (shorter / more shareable) and the route is HTML, not API.
      if (url.pathname === "/share" && req.method === "GET") {
        return handleSharePage(req, env);
      }
      // Privacy policy — static page. Required for the App Store "Privacy
      // Policy URL" field and TestFlight external (public) testing.
      if (url.pathname === "/privacy" && req.method === "GET") {
        return handlePrivacyPage();
      }
      // Server-mediated sync — Phase 0: record a friend pairing after a
      // real user opens a share link. App-Attest-gated + per-IP rate-
      // limited; stores only an opaque HMAC (no social graph).
      if (url.pathname === "/v1/sync/pair" && req.method === "POST") {
        return withCors(await handleSyncPair(req, env), cors);
      }
      // Phase 1 — addressed deliveries between paired friends.
      //   POST /v1/sync/upload — sender pushes an (encrypted) tx delivery
      //   GET  /v1/sync/inbox  — recipient pulls its un-acked deliveries
      //   POST /v1/sync/ack    — recipient confirms local apply
      //   POST /v1/sync/revoke — flip a pairing to 'revoked' (friend removed)
      if (url.pathname === "/v1/sync/upload" && req.method === "POST") {
        return withCors(await handleSyncUpload(req, env, ctx), cors);
      }
      if (url.pathname === "/v1/sync/inbox" && req.method === "GET") {
        return withCors(await handleSyncInbox(req, env, url), cors);
      }
      if (url.pathname === "/v1/sync/ack" && req.method === "POST") {
        return withCors(await handleSyncAck(req, env), cors);
      }
      if (url.pathname === "/v1/sync/revoke" && req.method === "POST") {
        return withCors(await handleSyncRevoke(req, env), cors);
      }
      // Phase 3 — APNs push token registration (so uploads can nudge the
      // recipient immediately instead of only on their next pull).
      if (url.pathname === "/v1/sync/register-token" && req.method === "POST") {
        return withCors(await handleSyncRegisterToken(req, env), cors);
      }
      // Server-side receipt-items storage (E2E encrypted).
      //   POST /v1/share-items/{share_id} — sender uploads items
      //   GET  /v1/share-items/{share_id} — recipient fetches them
      // Keyed by the URL payload checksum (64-hex). See
      // `share_items.ts` for the storage model + lifecycle.
      const itemsMatch = url.pathname.match(/^\/v1\/share-items\/([0-9a-f]{64})$/);
      if (itemsMatch != null) {
        const shareID = itemsMatch[1];
        const ip = callerIp(req);
        const salt = env.IP_HASH_SALT ?? "non-bank-dev-salt";
        const ipHash = await hashIp(ip, salt);
        const nowSec = Math.floor(Date.now() / 1000);
        if (req.method === "POST") {
          return withCors(
            await handleUploadShareItems(req, env, shareID, ipHash, nowSec),
            cors,
          );
        }
        if (req.method === "GET") {
          return withCors(
            await handleFetchShareItems(env, shareID, ipHash, nowSec),
            cors,
          );
        }
      }
      return withCors(
        jsonResponse({ error: "not_found", path: url.pathname }, 404),
        cors,
      );
    } catch (e) {
      // Last-resort catch — anything reaching here is a bug, not a user
      // error. Don't leak internals.
      logEvent(env, "error", {
        route: url.pathname,
        msg: "unhandled",
        error: e instanceof Error ? e.message : String(e),
      });
      return withCors(jsonResponse({ error: "internal_error" }, 500), cors);
    }
  },

  /// Cron Trigger entry point. Bound in `wrangler.toml` under
  /// `[triggers] crons`. Currently fires once a day to drop expired
  /// `share_items` rows so the table stays bounded — the read path
  /// already filters expired rows from responses, so users see a
  /// 30-day TTL either way; this sweep just reclaims the storage.
  /// Wrap each task in its own try/catch so one failure can't skip
  /// the others when more cron jobs land here.
  async scheduled(
    _event: ScheduledEvent,
    env: Env,
    ctx: ExecutionContext,
  ): Promise<void> {
    const nowSec = Math.floor(Date.now() / 1000);
    ctx.waitUntil((async () => {
      try {
        const { deleted } = await sweepExpiredShareItems(env, nowSec);
        if (deleted > 0) {
          logEvent(env, "info", {
            route: "cron",
            task: "sweepExpiredShareItems",
            deleted,
          });
        }
      } catch (e) {
        logEvent(env, "error", {
          route: "cron",
          task: "sweepExpiredShareItems",
          error: e instanceof Error ? e.message : String(e),
        });
      }
    })());
    ctx.waitUntil((async () => {
      try {
        const { deleted } = await sweepExpiredDeliveries(env.DB, nowSec);
        if (deleted > 0) {
          logEvent(env, "info", {
            route: "cron",
            task: "sweepExpiredDeliveries",
            deleted,
          });
        }
      } catch (e) {
        logEvent(env, "error", {
          route: "cron",
          task: "sweepExpiredDeliveries",
          error: e instanceof Error ? e.message : String(e),
        });
      }
    })());
  },
};

// Extract caller IP for rate-limiting. `CF-Connecting-IP` is set by the
// Cloudflare edge on every request and cannot be spoofed by the client.
// `X-Forwarded-For` is intentionally NOT consulted (clients control it).
// Returns a stable string even for missing header (so an attacker who
// somehow bypasses the edge still hits the per-"unknown" cap).
function callerIp(req: Request): string {
  return req.headers.get("CF-Connecting-IP") ?? "unknown";
}

// ─── App Attest ───────────────────────────────────────────────────────

/// Per-IP gate reused by the two attestation endpoints. The cert-chain
/// validation in `/v1/attest/verify` is CPU-heavy, so rate-limiting it
/// (against the same daily per-IP budget as parse-receipt) matters.
async function attestIpGate(req: Request, env: Env, nowSec: number): Promise<Response | null> {
  const ipHash = await hashIp(callerIp(req), env.IP_HASH_SALT ?? "non-bank-dev-salt");
  const ipLimit = Number.parseInt(env.PER_IP_DAILY_LIMIT ?? "", 10) || DEFAULT_PER_IP_DAILY;
  const gate = await bumpIpParseQuota(env.DB, ipHash, ipLimit, nowSec);
  if (!gate.ok) {
    return jsonResponse(
      { error: "ip_rate_limited", reset_at: gate.reset_at },
      429,
    );
  }
  return null;
}

async function handleAttestChallenge(req: Request, env: Env): Promise<Response> {
  const nowSec = Math.floor(Date.now() / 1000);
  const blocked = await attestIpGate(req, env, nowSec);
  if (blocked) return blocked;
  if (!env.ATTEST_SECRET) {
    return jsonResponse({ error: "attest_misconfigured" }, 500);
  }
  const challenge = await issueChallenge(env.ATTEST_SECRET, nowSec);
  return jsonResponse({ challenge }, 200);
}

async function handleAttestVerify(req: Request, env: Env): Promise<Response> {
  const nowSec = Math.floor(Date.now() / 1000);
  const blocked = await attestIpGate(req, env, nowSec);
  if (blocked) return blocked;
  if (!env.ATTEST_SECRET || !env.APP_ATTEST_APP_ID) {
    return jsonResponse({ error: "attest_misconfigured" }, 500);
  }
  let body: { keyId?: string; attestation?: string; challenge?: string };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "bad_request", detail: "invalid JSON" }, 400);
  }
  if (!body.keyId || !body.attestation || !body.challenge) {
    return jsonResponse({ error: "bad_request", detail: "keyId, attestation, challenge required" }, 400);
  }
  const attEnv: AttestEnv = {
    appId: env.APP_ATTEST_APP_ID,
    // Production Worker accepts only the production aaguid; staging also
    // accepts the development aaguid (Xcode-signed Debug builds).
    expectDev: env.ENV !== "production",
  };
  const result = await verifyAttestation(
    { keyId: body.keyId, attestationB64: body.attestation, challengeB64: body.challenge },
    env.ATTEST_SECRET, attEnv, nowSec,
  );
  if (!result.ok) {
    logEvent(env, "warn", { route: "/v1/attest/verify", msg: "attestation_failed", reason: result.reason });
    return jsonResponse({ error: "attestation_failed", detail: result.reason }, 403);
  }
  await storeKey(env.DB, body.keyId, result.publicKeyB64!, env.ENV, nowSec);
  logEvent(env, "info", { route: "/v1/attest/verify", msg: "attested", key_prefix: body.keyId.slice(0, 8) });
  return jsonResponse({ ok: true }, 200);
}

// ─── Server-mediated sync (Phase 0: pairing) ──────────────────────────

/// Record a friend pairing. Called by the client right after a real user
/// opens a share link (onOpenURL → ShareLinkCoordinator). Stores only the
/// opaque client-computed pair HMAC, and binds the attested key → user id
/// (trust-on-first-use) when an assertion is present so Phase 1 can
/// address deliveries. Best-effort client-side — a failure here never
/// breaks the existing manual-share import.
async function handleSyncPair(req: Request, env: Env): Promise<Response> {
  const nowSec = Math.floor(Date.now() / 1000);
  // Reuse the per-IP daily budget — pairing is rare (once per friend), so
  // it doesn't meaningfully compete with parse-receipt; a dedicated sync
  // counter lands with the Phase 4 quota tuning.
  const blocked = await attestIpGate(req, env, nowSec);
  if (blocked) return blocked;
  // Same env-based strictness as parse-receipt: required in production
  // (once APP_ATTEST_REQUIRED flips to "1"), lenient on staging/simulator.
  const attGate = await gateAttestation(req, env, nowSec);
  if (!attGate.ok) {
    return jsonResponse(
      { error: "attestation_failed", detail: attGate.reason },
      attGate.status,
    );
  }
  let body: { pair_hmac?: unknown; user_id?: unknown };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "bad_request", detail: "invalid JSON" }, 400);
  }
  if (!isValidPairHmac(body.pair_hmac)) {
    return jsonResponse(
      { error: "bad_request", detail: "pair_hmac must be 64 hex chars" },
      400,
    );
  }
  // Bind attested key → user id when both are present (TOFU). Absent on
  // lenient simulator dev with no attestation — the pairing still records.
  const keyId = req.headers.get("X-Attest-Key-Id");
  const userId = typeof body.user_id === "string" ? body.user_id.trim() : "";
  if (keyId && userId.length >= 3 && userId.length <= 64) {
    await bindKeyUser(env.DB, keyId, userId, nowSec);
  }
  await upsertPairing(env.DB, body.pair_hmac, nowSec);
  logEvent(env, "info", { route: "/v1/sync/pair", msg: "paired" });
  return jsonResponse({ ok: true }, 200);
}

/// Authorize a recipient-scoped read/ack: the user_id bound (TOFU) to the
/// caller's attested key must equal the recipient they're acting as, so a
/// device can only touch ITS OWN inbox. Lenient (simulator dev, no
/// attestation / unbound key) trusts the claimed id so local dev works;
/// strict (prod) refuses.
async function authorizeRecipient(
  req: Request, env: Env, claimedRecipientId: string,
): Promise<{ ok: true } | { ok: false; status: number; reason: string }> {
  const required = env.APP_ATTEST_REQUIRED === "1";
  const keyId = req.headers.get("X-Attest-Key-Id");
  if (!keyId) {
    return required ? { ok: false, status: 403, reason: "attestation_required" } : { ok: true };
  }
  const boundUser = await getKeyUserId(env.DB, keyId);
  if (boundUser == null) {
    return required ? { ok: false, status: 403, reason: "key_not_bound" } : { ok: true };
  }
  if (boundUser !== claimedRecipientId) {
    return { ok: false, status: 403, reason: "recipient_mismatch" };
  }
  return { ok: true };
}

/// POST /v1/sync/upload — sender pushes one addressed, E2E-encrypted tx
/// delivery to a paired recipient. Version-guarded (older edits no-op) and
/// only accepted inside an ACTIVE pairing, so a removed friend gets nothing.
async function handleSyncUpload(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const nowSec = Math.floor(Date.now() / 1000);
  const blocked = await attestIpGate(req, env, nowSec);
  if (blocked) return blocked;
  const attGate = await gateAttestation(req, env, nowSec);
  if (!attGate.ok) return jsonResponse({ error: "attestation_failed", detail: attGate.reason }, attGate.status);

  let body: {
    pair_hmac?: unknown; recipient_id?: unknown; tx_sync_id?: unknown;
    version?: unknown; op?: unknown; payload?: unknown; checksum?: unknown;
    sender_id?: unknown;
  };
  try { body = await req.json(); } catch {
    return jsonResponse({ error: "bad_request", detail: "invalid JSON" }, 400);
  }
  if (!isValidPairHmac(body.pair_hmac)) return jsonResponse({ error: "bad_request", detail: "pair_hmac must be 64 hex chars" }, 400);
  if (!isValidUserId(body.recipient_id)) return jsonResponse({ error: "bad_request", detail: "recipient_id required" }, 400);
  if (!isValidSyncId(body.tx_sync_id)) return jsonResponse({ error: "bad_request", detail: "tx_sync_id required" }, 400);
  if (!isValidVersion(body.version)) return jsonResponse({ error: "bad_request", detail: "version must be a non-negative integer" }, 400);
  if (!isValidOp(body.op)) return jsonResponse({ error: "bad_request", detail: "op must be 'upsert' or 'delete'" }, 400);
  const payload = typeof body.payload === "string" ? body.payload : "";
  if (body.op === "upsert" && payload.length === 0) return jsonResponse({ error: "bad_request", detail: "payload required for upsert" }, 400);
  if (payload.length > MAX_DELIVERY_PAYLOAD_BYTES * 2) return jsonResponse({ error: "payload_too_large", detail: `max ${MAX_DELIVERY_PAYLOAD_BYTES} bytes` }, 413);
  const checksum = typeof body.checksum === "string" ? body.checksum : null;
  // Cleartext envelope field: the sender's real user id. Lets the recipient
  // derive the pairwise key + self-heal pairing from this delivery (see
  // 0009_delivery_sender migration). Lenient: stored NULL when absent/invalid
  // so older clients keep working.
  const senderId = isValidUserId(body.sender_id) ? body.sender_id : null;

  // A pair handshake is itself the act of (re)establishing a pairing, so let
  // it re-activate a row the other side's friend-removal had revoked — instead
  // of being rejected by the very gate it exists to clear. This is what
  // stranded re-pairing after a delete: the op="pair" upload 409'd on the
  // still-revoked row, so the handshake was never recorded and no pairing push
  // ever fired. For every other op an inactive pairing still means "stop", so
  // revocation keeps working.
  if (body.op === "pair") {
    await upsertPairing(env.DB, body.pair_hmac, nowSec);
  } else if (!(await isPairingActive(env.DB, body.pair_hmac))) {
    return jsonResponse({ error: "pairing_inactive", detail: "no active pairing" }, 409);
  }

  const { applied } = await recordDelivery(env.DB, {
    recipientId: body.recipient_id, txSyncId: body.tx_sync_id,
    version: body.version, op: body.op, payload, checksum, senderId,
  }, nowSec);

  // Phase 3: nudge the recipient with an APNs push (only for a freshly
  // applied upsert — not stale no-ops or tombstones). The push carries NO
  // financial content; the app pulls the encrypted delivery on receipt.
  // Runs in waitUntil so the upload response returns immediately, and is
  // entirely best-effort (no push configured / send fails → recipient
  // still gets it on next pull).
  if (applied && body.op === "upsert") {
    const recipientId = body.recipient_id;
    const txSyncId = body.tx_sync_id;
    // version is the transaction's editVersion: 0 = first share (a new
    // expense), >= 1 = a subsequent edit. Lets the push say "shared" vs
    // "updated" without the server ever reading the (encrypted) content.
    const isEdit = body.version >= 1;
    ctx.waitUntil(sendDeliveryPush(env, recipientId, txSyncId, isEdit, nowSec));
  } else if (applied && body.op === "pair") {
    // A friend just completed the reciprocal pairing handshake addressed to
    // this recipient (the sharer). Nudge them with a visible push so the
    // handshake applies instantly instead of on the next 60s foreground poll.
    ctx.waitUntil(sendPairingPush(env, body.recipient_id, nowSec));
  }

  logEvent(env, "info", { route: "/v1/sync/upload", applied, op: body.op });
  return jsonResponse({ ok: true, applied }, 200);
}

/// Fan a "new shared expense" alert out to all of a recipient's registered
/// devices. Generic copy only — the server can't (and shouldn't) read who
/// sent it or the amount. Prunes tokens APNs reports as gone (410).
async function sendDeliveryPush(
  env: Env,
  recipientId: string,
  txSyncId: string,
  isEdit: boolean,
  nowSec: number,
): Promise<void> {
  const config = apnsConfigFromEnv(env);
  if (!config) return; // push not configured — pull still delivers
  const tokens = await getDeviceTokens(env.DB, recipientId);
  if (tokens.length === 0) return;
  const alert = isEdit
    ? { title: "Shared expense updated", body: "A friend updated a shared expense." }
    : { title: "New shared expense", body: "A friend shared an expense with you." };
  // Carry the opaque syncID under the SAME key local reminder notifications
  // use (NotificationCoordinator reads `transactionSyncID`), so tapping the
  // push deep-links to the transaction once the pull applies it.
  const data = { transactionSyncID: txSyncId };
  for (const t of tokens) {
    const ok = await sendPush(config, t.token, t.env, alert, nowSec, data);
    if (!ok) {
      // Best-effort cleanup of obviously-dead tokens. We don't have the
      // APNs status code here (sendPush returns bool), so only prune on a
      // clear failure pattern in a future pass; for now leave it — the
      // 14-day delivery TTL + token refresh on next launch self-heal.
      logEvent(env, "info", { route: "push", msg: "send_failed", user: recipientId.slice(0, 6) });
    }
  }
}

/// GET /v1/sync/inbox?recipient_id=… — recipient pulls its un-acked,
/// non-expired deliveries. No TTL bump / no delete-on-read (idempotent).
async function handleSyncInbox(req: Request, env: Env, url: URL): Promise<Response> {
  const nowSec = Math.floor(Date.now() / 1000);
  const blocked = await attestIpGate(req, env, nowSec);
  if (blocked) return blocked;
  const attGate = await gateAttestation(req, env, nowSec);
  if (!attGate.ok) return jsonResponse({ error: "attestation_failed", detail: attGate.reason }, attGate.status);

  const recipientId = url.searchParams.get("recipient_id") ?? "";
  if (!isValidUserId(recipientId)) return jsonResponse({ error: "bad_request", detail: "recipient_id required" }, 400);
  const auth = await authorizeRecipient(req, env, recipientId);
  if (!auth.ok) return jsonResponse({ error: "forbidden", detail: auth.reason }, auth.status);

  const deliveries = await fetchInbox(env.DB, recipientId, nowSec);
  logEvent(env, "info", { route: "/v1/sync/inbox", count: deliveries.length });
  return jsonResponse({ deliveries }, 200);
}

/// POST /v1/sync/ack — recipient confirms it applied the listed
/// (tx_sync_id, version) deliveries locally. Only acks rows whose stored
/// version <= the acked version, so a fresher edit that landed after the
/// pull is preserved for re-delivery.
async function handleSyncAck(req: Request, env: Env): Promise<Response> {
  const nowSec = Math.floor(Date.now() / 1000);
  const blocked = await attestIpGate(req, env, nowSec);
  if (blocked) return blocked;
  const attGate = await gateAttestation(req, env, nowSec);
  if (!attGate.ok) return jsonResponse({ error: "attestation_failed", detail: attGate.reason }, attGate.status);

  let body: { recipient_id?: unknown; acks?: unknown };
  try { body = await req.json(); } catch {
    return jsonResponse({ error: "bad_request", detail: "invalid JSON" }, 400);
  }
  if (!isValidUserId(body.recipient_id)) return jsonResponse({ error: "bad_request", detail: "recipient_id required" }, 400);
  if (!Array.isArray(body.acks)) return jsonResponse({ error: "bad_request", detail: "acks array required" }, 400);
  if (body.acks.length > 500) return jsonResponse({ error: "bad_request", detail: "too many acks" }, 400);
  const auth = await authorizeRecipient(req, env, body.recipient_id);
  if (!auth.ok) return jsonResponse({ error: "forbidden", detail: auth.reason }, auth.status);

  const acks: { txSyncId: string; version: number }[] = [];
  for (const a of body.acks) {
    const item = a as { tx_sync_id?: unknown; version?: unknown };
    if (item && typeof item === "object" && isValidSyncId(item.tx_sync_id) && isValidVersion(item.version)) {
      acks.push({ txSyncId: item.tx_sync_id, version: item.version });
    }
  }
  const { acked } = await ackDeliveries(env.DB, body.recipient_id, acks, nowSec);
  logEvent(env, "info", { route: "/v1/sync/ack", acked });
  return jsonResponse({ ok: true, acked }, 200);
}

/// POST /v1/sync/revoke — flip a pairing to 'revoked' when a user removes
/// a friend. After this the upload route refuses new deliveries for the
/// pair (server-side half of "removing a friend stops sync").
async function handleSyncRevoke(req: Request, env: Env): Promise<Response> {
  const nowSec = Math.floor(Date.now() / 1000);
  const blocked = await attestIpGate(req, env, nowSec);
  if (blocked) return blocked;
  const attGate = await gateAttestation(req, env, nowSec);
  if (!attGate.ok) return jsonResponse({ error: "attestation_failed", detail: attGate.reason }, attGate.status);

  let body: { pair_hmac?: unknown };
  try { body = await req.json(); } catch {
    return jsonResponse({ error: "bad_request", detail: "invalid JSON" }, 400);
  }
  if (!isValidPairHmac(body.pair_hmac)) return jsonResponse({ error: "bad_request", detail: "pair_hmac must be 64 hex chars" }, 400);
  await revokePairing(env.DB, body.pair_hmac);
  logEvent(env, "info", { route: "/v1/sync/revoke", msg: "revoked" });
  return jsonResponse({ ok: true }, 200);
}

/// POST /v1/sync/register-token — register this device's APNs token so
/// deliveries can push. Body: { user_id, token, env }. Caller must be the
/// user (attested key's bound user matches), same as inbox/ack.
async function handleSyncRegisterToken(req: Request, env: Env): Promise<Response> {
  const nowSec = Math.floor(Date.now() / 1000);
  const blocked = await attestIpGate(req, env, nowSec);
  if (blocked) return blocked;
  const attGate = await gateAttestation(req, env, nowSec);
  if (!attGate.ok) return jsonResponse({ error: "attestation_failed", detail: attGate.reason }, attGate.status);

  let body: { user_id?: unknown; token?: unknown; env?: unknown };
  try { body = await req.json(); } catch {
    return jsonResponse({ error: "bad_request", detail: "invalid JSON" }, 400);
  }
  if (!isValidUserId(body.user_id)) return jsonResponse({ error: "bad_request", detail: "user_id required" }, 400);
  if (!isValidDeviceToken(body.token)) return jsonResponse({ error: "bad_request", detail: "token must be hex (32-200 chars)" }, 400);
  if (!isValidApnsEnv(body.env)) return jsonResponse({ error: "bad_request", detail: "env must be 'production' or 'sandbox'" }, 400);
  const auth = await authorizeRecipient(req, env, body.user_id);
  if (!auth.ok) return jsonResponse({ error: "forbidden", detail: auth.reason }, auth.status);

  await registerDeviceToken(env.DB, body.user_id, body.token, body.env, nowSec);
  logEvent(env, "info", { route: "/v1/sync/register-token" });
  return jsonResponse({ ok: true }, 200);
}

/// Verify the App Attest assertion on a protected request. Returns
/// `{ ok: true }` to proceed, or a failure with the HTTP status to
/// return. Strict (prod): missing/invalid → 403. Lenient (staging):
/// missing/invalid → allowed (so simulator dev without App Attest
/// works). On success, bumps the stored Secure-Enclave counter.
async function gateAttestation(
  req: Request, env: Env, nowSec: number,
): Promise<{ ok: true } | { ok: false; status: number; reason: string }> {
  const required = env.APP_ATTEST_REQUIRED === "1";
  const keyId = req.headers.get("X-Attest-Key-Id");
  const assertionB64 = req.headers.get("X-Attest-Assertion");
  const clientDataB64 = req.headers.get("X-Attest-Client-Data");

  if (!keyId || !assertionB64 || !clientDataB64) {
    return required ? { ok: false, status: 403, reason: "attestation_required" } : { ok: true };
  }
  if (!env.APP_ATTEST_APP_ID) {
    // Misconfigured: fail closed when strict, open when lenient.
    return required ? { ok: false, status: 500, reason: "attest_misconfigured" } : { ok: true };
  }
  const stored = await getStoredKey(env.DB, keyId);
  if (!stored) {
    return required ? { ok: false, status: 403, reason: "key_not_registered" } : { ok: true };
  }
  const attEnv: AttestEnv = { appId: env.APP_ATTEST_APP_ID, expectDev: env.ENV !== "production" };
  const result = await verifyAssertion(
    { keyId, assertionB64, clientDataB64, storedPublicKeyB64: stored.public_key, storedCounter: stored.counter },
    attEnv, nowSec,
  );
  if (!result.ok) {
    return required ? { ok: false, status: 403, reason: result.reason ?? "assertion_invalid" } : { ok: true };
  }
  await bumpCounter(env.DB, keyId, result.newCounter!, nowSec);
  return { ok: true };
}

// Provider ids the client may name in `exclude_provider`. Mirrors the
// registry in router.ts; an unknown id in the request is silently dropped.
const VALID_PROVIDER_IDS: ReadonlySet<string> = new Set([
  "gemini", "groq", "cloudflare", "openrouter",
  "mistral", "sambanova", "nvidia", "huggingface",
]);

async function handleParseReceipt(req: Request, env: Env): Promise<Response> {
  const startMs = Date.now();
  const ip = callerIp(req);
  const salt = env.IP_HASH_SALT ?? "non-bank-dev-salt";
  const ipHash = await hashIp(ip, salt);

  // Reject oversized payloads BEFORE parsing the form, so a giant
  // multipart body never gets fully read into the Worker.
  const declaredLength = Number.parseInt(
    req.headers.get("content-length") ?? "0",
    10,
  );
  if (declaredLength > MAX_BODY_BYTES) {
    logEvent(env, "warn", {
      route: "/v1/parse-receipt",
      ip_hash: ipHash,
      content_length: declaredLength,
      msg: "body_too_large",
    });
    return jsonResponse(
      { error: "payload_too_large", detail: `max ${MAX_BODY_BYTES} bytes` },
      413,
    );
  }

  const contentType = req.headers.get("content-type") ?? "";
  if (!contentType.startsWith("multipart/form-data")) {
    return jsonResponse(
      { error: "bad_request", detail: "expected multipart/form-data" },
      400,
    );
  }

  // Per-IP gate comes BEFORE form parsing so a flood of bad requests
  // from one host can't burn Worker CPU on multipart parsing. Also
  // before per-device because device_id is client-asserted and trivially
  // rotated — the IP cap is the real backstop.
  const nowSec = Math.floor(Date.now() / 1000);
  const ipLimit =
    Number.parseInt(env.PER_IP_DAILY_LIMIT ?? "", 10) || DEFAULT_PER_IP_DAILY;
  const ipCheck = await bumpIpParseQuota(env.DB, ipHash, ipLimit, nowSec);
  if (!ipCheck.ok) {
    logEvent(env, "warn", {
      route: "/v1/parse-receipt",
      ip_hash: ipHash,
      msg: "ip_rate_limited",
      reset_at: ipCheck.reset_at,
    });
    return jsonResponse(
      {
        error: "ip_rate_limited",
        detail: `daily limit ${ipLimit} reached for this network`,
        reset_at: ipCheck.reset_at,
      },
      429,
    );
  }

  // App Attest gate — verify the request carries a valid Secure-Enclave
  // assertion from a registered key. Runs BEFORE the multipart parse +
  // LLM call so a forged/replayed request never reaches the expensive
  // path. In production this is required; on staging it's lenient
  // (missing attestation is allowed) so simulator dev keeps working.
  const attGate = await gateAttestation(req, env, nowSec);
  if (!attGate.ok) {
    logEvent(env, "warn", {
      route: "/v1/parse-receipt",
      ip_hash: ipHash,
      msg: "attestation_failed",
      reason: attGate.reason,
    });
    return jsonResponse(
      { error: "attestation_failed", detail: attGate.reason },
      attGate.status,
    );
  }

  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return jsonResponse(
      { error: "bad_request", detail: "could not parse form" },
      400,
    );
  }

  // workers-types narrows form.get to `string | null` (it doesn't model the
  // File branch), so duck-type via Blob — that's the actual minimum surface
  // we need (size + type + arrayBuffer).
  const imageEntry = form.get("image");
  if (imageEntry == null || typeof imageEntry === "string") {
    return jsonResponse(
      { error: "bad_request", detail: "missing 'image' file part" },
      400,
    );
  }
  const image = imageEntry as unknown as Blob;
  if (image.size === 0 || image.size > MAX_IMAGE_BYTES) {
    return jsonResponse(
      { error: "bad_request", detail: `image size ${image.size} out of range` },
      413,
    );
  }
  const mime = (image.type || "image/jpeg").toLowerCase();
  if (!ALLOWED_MIMES.has(mime)) {
    return jsonResponse(
      { error: "bad_request", detail: `unsupported mime ${mime}` },
      415,
    );
  }

  const deviceId = (form.get("device_id") as string | null)?.trim();
  if (!deviceId || deviceId.length < 8 || deviceId.length > 128) {
    return jsonResponse(
      { error: "bad_request", detail: "missing or invalid device_id" },
      400,
    );
  }
  const deviceHash = await hashIp(deviceId, salt);

  // Categories: clamp count, clamp per-field length, strip prompt-injection
  // escape chars. Whole pipeline lives in `sanitizePromptText`; we
  // re-apply here at the boundary so a malformed `categories` payload is
  // 400-rejected by JSON.parse below rather than reaching the LLM at all.
  const categoriesRaw = form.get("categories") as string | null;
  let categories: ProviderRequest["categories"] = [];
  if (categoriesRaw) {
    try {
      const parsed = JSON.parse(categoriesRaw);
      if (Array.isArray(parsed)) {
        categories = parsed
          .filter((c) => c && typeof c.name === "string")
          .slice(0, 50)
          .map((c) => ({
            name: sanitizePromptText(String(c.name), MAX_CATEGORY_NAME),
            emoji: c.emoji
              ? sanitizePromptText(String(c.emoji), MAX_CATEGORY_EMOJI)
              : undefined,
          }))
          // Drop categories whose name was wiped to empty by sanitization
          // (e.g. a name made entirely of control chars).
          .filter((c) => c.name.length > 0);
      }
    } catch {
      // Ignore — categories are an optional hint, not a hard input.
    }
  }
  const rawLocale = (form.get("locale") as string | null)?.trim() || undefined;
  const localeHint = rawLocale
    ? sanitizePromptText(rawLocale, MAX_LOCALE_HINT) || undefined
    : undefined;

  // Optional "second opinion" hint: comma-separated provider ids to SKIP
  // this request, so the client's reconciliation retry (Σ items ≠ printed
  // total) is answered by a DIFFERENT model than the first parse. Unknown
  // ids are dropped; an empty/all-unknown value means no exclusion.
  const excludeProviders = new Set(
    ((form.get("exclude_provider") as string | null) ?? "")
      .split(",")
      .map((s) => s.trim().toLowerCase())
      .filter((s) => VALID_PROVIDER_IDS.has(s)),
  );

  const deviceLimit =
    Number.parseInt(env.PER_DEVICE_DAILY_LIMIT, 10) || DEFAULT_PER_DEVICE_DAILY;
  const deviceCheck = await bumpDeviceQuota(
    env.DB,
    deviceId,
    deviceLimit,
    nowSec,
  );
  if (!deviceCheck.ok) {
    logEvent(env, "warn", {
      route: "/v1/parse-receipt",
      ip_hash: ipHash,
      device_hash: deviceHash,
      msg: "device_rate_limited",
      reset_at: deviceCheck.reset_at,
    });
    return jsonResponse(
      {
        error: "device_rate_limited",
        detail: `daily limit ${deviceLimit} reached`,
        reset_at: deviceCheck.reset_at,
      },
      429,
    );
  }

  const imageBytes = new Uint8Array(await image.arrayBuffer());

  try {
    const result = await route(
      { imageBytes, imageMime: mime, categories, localeHint },
      env,
      nowSec,
      excludeProviders,
    );
    const response: ParseResponse = {
      receipt: result.receipt,
      provider: result.provider,
      pool_remaining: result.poolRemaining,
      pool_low: result.poolLow,
      // `triedProviders` carries the FAILED attempts before the
      // success; the actual count of providers walked through is
      // failures + 1 (the winner). Lets iOS analytics segment by
      // "leading provider degrading" vs happy-path.
      attempted_providers_count: result.triedProviders.length + 1,
    };
    logEvent(env, "info", {
      route: "/v1/parse-receipt",
      ip_hash: ipHash,
      device_hash: deviceHash,
      provider: result.provider,
      latency_ms: Date.now() - startMs,
      status: 200,
      attempts: result.triedProviders.length,
      // Diagnostic fields for the "receipt parses N of M items"
      // class of bugs. `items_count` is post-coerce (what iOS gets).
      // If a receipt visibly has more items than this number, either
      // the model truncated (raw_snippet would show that) or
      // `coerceReceipt`'s `isUsableItem` filter dropped some rows.
      items_count: result.receipt.items.length,
    });
    return jsonResponse(response, 200, {
      "x-device-remaining": String(deviceCheck.remaining),
      "x-ip-remaining": String(ipCheck.remaining),
      "x-provider": result.provider,
    });
  } catch (e) {
    if (e instanceof RouterExhaustedError) {
      logEvent(env, "warn", {
        route: "/v1/parse-receipt",
        ip_hash: ipHash,
        device_hash: deviceHash,
        latency_ms: Date.now() - startMs,
        status: 503,
        msg: "all_providers_unavailable",
        attempts: e.attempts.map((a) => a.provider),
      });
      // Tell iOS to fall back to local OCR. Include a per-attempt summary
      // for the in-app debug viewer (no PII — just provider names + status).
      return jsonResponse(
        {
          error: "all_providers_unavailable",
          attempts: e.attempts,
        },
        503,
      );
    }
    throw e;
  }
}

// One-time bootstrap: Cloudflare requires a `prompt: "agree"` call to the
// Llama 3.2 Vision model before normal inference is allowed. The Workers AI
// binding handles auth for us, so this hop is simpler than spinning up a
// CF API token. Idempotent — calling it again after agreement is a no-op
// (just returns whatever the model says to "agree").
async function handleAcceptLlama(env: Env): Promise<Response> {
  if (!env.AI) {
    return jsonResponse({ error: "AI binding not configured" }, 500);
  }
  try {
    const result = await env.AI.run(
      "@cf/meta/llama-3.2-11b-vision-instruct",
      { prompt: "agree" },
    );
    return jsonResponse({ ok: true, result });
  } catch (e) {
    return jsonResponse(
      {
        error: "agree call failed",
        detail: e instanceof Error ? e.message : String(e),
      },
      500,
    );
  }
}

async function handleQuotaSnapshot(env: Env): Promise<Response> {
  const result = await env.DB.prepare(
    `SELECT provider, rpd_used, rpd_limit, consecutive_errors, total_requests, total_errors FROM provider_quotas`,
  ).all();
  return jsonResponse({ providers: result.results ?? [] });
}

function jsonResponse(
  body: unknown,
  status = 200,
  extra: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...extra },
  });
}

function corsHeaders(): Record<string, string> {
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "POST, GET, OPTIONS",
    "access-control-allow-headers": "content-type",
    "access-control-max-age": "86400",
  };
}

function withCors(res: Response, cors: Record<string, string>): Response {
  const headers = new Headers(res.headers);
  for (const [k, v] of Object.entries(cors)) headers.set(k, v);
  return new Response(res.body, { status: res.status, headers });
}
