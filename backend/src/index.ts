import { route, RouterExhaustedError } from "./router.ts";
import { bumpDeviceQuota } from "./quota.ts";
import { handleSharePage } from "./share.ts";
import type { ParseResponse, ProviderRequest } from "./types.ts";

// Worker bindings declared in wrangler.toml. Provider API keys are
// optional — a missing key just makes the corresponding provider skip
// itself (auth_error) and the router falls through to the next one.
export interface Env {
  DB: D1Database;
  AI: Ai;
  ENV: string;
  PER_DEVICE_DAILY_LIMIT: string;
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
const ALLOWED_MIMES = new Set([
  "image/jpeg",
  "image/jpg",
  "image/png",
  "image/heic",
  "image/heif",
  "image/webp",
]);

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
        return handleSharePage(req);
      }
      return withCors(
        jsonResponse({ error: "not_found", path: url.pathname }, 404),
        cors,
      );
    } catch (e) {
      // Last-resort catch — anything reaching here is a bug, not a user
      // error. Don't leak internals.
      console.error("unhandled", e);
      return withCors(jsonResponse({ error: "internal_error" }, 500), cors);
    }
  },
};

async function handleParseReceipt(req: Request, env: Env): Promise<Response> {
  const contentType = req.headers.get("content-type") ?? "";
  if (!contentType.startsWith("multipart/form-data")) {
    return jsonResponse(
      { error: "bad_request", detail: "expected multipart/form-data" },
      400,
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

  const categoriesRaw = form.get("categories") as string | null;
  let categories: ProviderRequest["categories"] = [];
  if (categoriesRaw) {
    try {
      const parsed = JSON.parse(categoriesRaw);
      if (Array.isArray(parsed)) {
        categories = parsed
          .filter((c) => c && typeof c.name === "string")
          .slice(0, 50)
          .map((c) => ({ name: String(c.name), emoji: c.emoji ? String(c.emoji) : undefined }));
      }
    } catch {
      // Ignore — categories are an optional hint, not a hard input.
    }
  }
  const localeHint = (form.get("locale") as string | null)?.trim() || undefined;

  const nowSec = Math.floor(Date.now() / 1000);
  const limit = Number.parseInt(env.PER_DEVICE_DAILY_LIMIT, 10) || 30;
  const deviceCheck = await bumpDeviceQuota(env.DB, deviceId, limit, nowSec);
  if (!deviceCheck.ok) {
    return jsonResponse(
      {
        error: "device_rate_limited",
        detail: `daily limit ${limit} reached`,
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
    return jsonResponse(response, 200, {
      "x-device-remaining": String(deviceCheck.remaining),
      "x-provider": result.provider,
    });
  } catch (e) {
    if (e instanceof RouterExhaustedError) {
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
