import { route, RouterExhaustedError } from "./router.ts";
import { bumpDeviceQuota, bumpIpParseQuota } from "./quota.ts";
import { handleSharePage } from "./share.ts";
import {
  handleUploadShareItems,
  handleFetchShareItems,
} from "./share_items.ts";
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
  async fetch(req: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
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
      if (url.pathname === "/v1/quota" && req.method === "GET") {
        return withCors(await handleQuotaSnapshot(env), cors);
      }
      if (url.pathname === "/v1/admin/accept-llama" && req.method === "POST") {
        return withCors(await handleAcceptLlama(env), cors);
      }
      // Share-link landing page — friends without the iOS app land here
      // and see a transaction preview with an "Open in app" deep link.
      // Not under `/v1/` because the URL is the user-facing share link
      // (shorter / more shareable) and the route is HTML, not API.
      if (url.pathname === "/share" && req.method === "GET") {
        return handleSharePage(req, env);
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
};

// Extract caller IP for rate-limiting. `CF-Connecting-IP` is set by the
// Cloudflare edge on every request and cannot be spoofed by the client.
// `X-Forwarded-For` is intentionally NOT consulted (clients control it).
// Returns a stable string even for missing header (so an attacker who
// somehow bypasses the edge still hits the per-"unknown" cap).
function callerIp(req: Request): string {
  return req.headers.get("CF-Connecting-IP") ?? "unknown";
}

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
    );
    const response: ParseResponse = {
      receipt: result.receipt,
      provider: result.provider,
      pool_remaining: result.poolRemaining,
      pool_low: result.poolLow,
    };
    logEvent(env, "info", {
      route: "/v1/parse-receipt",
      ip_hash: ipHash,
      device_hash: deviceHash,
      provider: result.provider,
      latency_ms: Date.now() - startMs,
      status: 200,
      attempts: result.triedProviders.length,
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
