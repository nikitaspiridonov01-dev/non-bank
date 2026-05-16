// Diagnostic endpoint that fans out the same receipt image to every
// provider in parallel and reports each one's result. Used to verify
// that all API keys are valid and reachable on a given environment —
// the receipt itself doesn't have to be a real one, the endpoint
// only checks "can each provider auth + respond?".
//
// Why a dedicated endpoint
// ------------------------
// The normal `/v1/parse-receipt` path only hits the FIRST eligible
// provider (router picks by quality rank + quota headroom). A
// regular scan therefore tells you nothing about providers #2-#8.
// Forcing fallback by tweaking `provider_quotas` rows in D1 is
// cumbersome and pollutes prod telemetry. This endpoint sidesteps
// the router and calls each provider directly.
//
// Cost / abuse model
// ------------------
// One call here = 8 real LLM invocations against 8 different
// providers. Per-IP rate limit (reused from Phase 8) bounds the
// damage. The endpoint is under `/v1/admin/` to discourage
// accidental scraping but isn't authenticated otherwise — assume
// someone who finds it can burn 1 call per ~432 seconds (200/day
// IP cap) before the gate stops them.

import { geminiProvider } from "./providers/gemini.ts";
import { groqProvider } from "./providers/groq.ts";
import { cloudflareProvider } from "./providers/cloudflare.ts";
import { openrouterProvider } from "./providers/openrouter.ts";
import { mistralProvider } from "./providers/mistral.ts";
import { sambanovaProvider } from "./providers/sambanova.ts";
import { nvidiaProvider } from "./providers/nvidia.ts";
import { huggingfaceProvider } from "./providers/huggingface.ts";
import type { Provider, ProviderEnv } from "./providers/base.ts";
import { ProviderError } from "./types.ts";
import { bumpIpParseQuota } from "./quota.ts";
import { logEvent } from "./log.ts";

interface TestProvidersEnv extends ProviderEnv {
  DB: D1Database;
  ENV?: string;
  IP_HASH_SALT?: string;
  PER_IP_DAILY_LIMIT?: string;
  LOG_LEVEL?: string;
}

interface ProviderTestResult {
  ok: boolean;
  latency_ms: number;
  items_count?: number;
  total_amount?: number | null;
  store_name?: string | null;
  currency?: string | null;
  error_kind?: string;
  error_message?: string;
}

const ALL_PROVIDERS: ReadonlyArray<{ id: string; impl: Provider }> = [
  { id: "gemini", impl: geminiProvider },
  { id: "groq", impl: groqProvider },
  { id: "cloudflare", impl: cloudflareProvider },
  { id: "openrouter", impl: openrouterProvider },
  { id: "mistral", impl: mistralProvider },
  { id: "sambanova", impl: sambanovaProvider },
  { id: "nvidia", impl: nvidiaProvider },
  { id: "huggingface", impl: huggingfaceProvider },
];

export async function handleTestProviders(
  req: Request,
  env: TestProvidersEnv,
  ipHash: string,
  nowSec: number,
): Promise<Response> {
  // Per-IP gate. One call here is expensive (8 LLM round-trips); the
  // existing parse-receipt budget keeps this from being a free DoS
  // vector for someone who finds the endpoint.
  const limit = Number.parseInt(env.PER_IP_DAILY_LIMIT ?? "", 10) || 200;
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
  if (!contentType.startsWith("multipart/form-data")) {
    return jsonResponse(
      { error: "bad_request", detail: "expected multipart/form-data with image part" },
      400,
    );
  }

  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return jsonResponse({ error: "bad_request", detail: "could not parse form" }, 400);
  }

  const imageEntry = form.get("image");
  if (imageEntry == null || typeof imageEntry === "string") {
    return jsonResponse(
      { error: "bad_request", detail: "missing 'image' file part" },
      400,
    );
  }
  const image = imageEntry as unknown as Blob;
  const imageBytes = new Uint8Array(await image.arrayBuffer());
  const imageMime = (image.type || "image/jpeg").toLowerCase();

  const startedAt = Date.now();
  const probe = { imageBytes, imageMime, categories: [] };

  // Per-provider timeout. Some `:free` reasoning models (Qwen3-VL-235B-
  // Thinking on OpenRouter) can chew through 60+ seconds on internal
  // chain-of-thought before emitting any output, which would block the
  // whole `allSettled` result. 60s is the deliberate max — long enough
  // that legitimately slow providers (Gemini routinely runs ~25s,
  // Cloudflare AI binding can climb past 60s under load) still have a
  // fair shot, and short enough that one stuck provider doesn't extend
  // the curl indefinitely.
  const PER_PROVIDER_TIMEOUT_MS = 60_000;

  // Fan out — all 8 in parallel via `allSettled` so a slow provider
  // doesn't gate the others, and one provider throwing doesn't bring
  // the rest down.
  const settled = await Promise.allSettled(
    ALL_PROVIDERS.map(async ({ id, impl }) => {
      const start = Date.now();
      try {
        const result = await raceTimeout(
          impl.parse(probe, env),
          PER_PROVIDER_TIMEOUT_MS,
        );
        return {
          id,
          out: {
            ok: true,
            latency_ms: Date.now() - start,
            items_count: result.receipt.items.length,
            total_amount: result.receipt.totalAmount,
            store_name: result.receipt.storeName,
            currency: result.receipt.currency,
          } satisfies ProviderTestResult,
        };
      } catch (e) {
        const err = e instanceof ProviderError
          ? { kind: e.kind, message: e.message }
          : { kind: e instanceof TimeoutError ? "timeout" : "unknown",
              message: e instanceof Error ? e.message : String(e) };
        return {
          id,
          out: {
            ok: false,
            latency_ms: Date.now() - start,
            error_kind: err.kind,
            error_message: err.message.slice(0, 300),
          } satisfies ProviderTestResult,
        };
      }
    }),
  );

  const results: Record<string, ProviderTestResult> = {};
  for (const s of settled) {
    if (s.status === "fulfilled") {
      results[s.value.id] = s.value.out;
    }
    // `rejected` only happens if the async wrapper itself threw,
    // which our try/catch above prevents — but log it just in case
    // so a regression on this file doesn't silently lose providers.
  }

  const okCount = Object.values(results).filter((r) => r.ok).length;
  logEvent(env, "info", {
    route: "/v1/admin/test-providers",
    ip_hash: ipHash,
    latency_ms: Date.now() - startedAt,
    ok_count: okCount,
    total: ALL_PROVIDERS.length,
  });

  return jsonResponse(
    {
      env: env.ENV ?? "unknown",
      ok_count: okCount,
      total: ALL_PROVIDERS.length,
      results,
    },
    200,
  );
}

class TimeoutError extends Error {
  constructor(ms: number) {
    super(`timed out after ${ms}ms`);
    this.name = "TimeoutError";
  }
}

/// Promise.race against a setTimeout that rejects after `ms` ms. The
/// underlying fetch isn't cancelled — it continues in the background
/// until Cloudflare reaps it — but the caller stops waiting, which
/// is what `allSettled` needs to keep one slow provider from blocking
/// the rest.
function raceTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new TimeoutError(ms)), ms);
  });
  return Promise.race([p, timeout]).finally(() => {
    if (timer !== undefined) clearTimeout(timer);
  });
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json" },
  });
}
