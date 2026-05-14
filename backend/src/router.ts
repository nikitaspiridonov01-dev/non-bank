import type { Provider, ProviderEnv } from "./providers/base.ts";
import { geminiProvider } from "./providers/gemini.ts";
import { groqProvider } from "./providers/groq.ts";
import { cloudflareProvider } from "./providers/cloudflare.ts";
import { openrouterProvider } from "./providers/openrouter.ts";
import { mistralProvider } from "./providers/mistral.ts";
import { sambanovaProvider } from "./providers/sambanova.ts";
import { nvidiaProvider } from "./providers/nvidia.ts";
import { huggingfaceProvider } from "./providers/huggingface.ts";
import type {
  ProviderId,
  ProviderRequest,
  ProviderResult,
} from "./types.ts";
import { ProviderError } from "./types.ts";
import {
  loadProviderQuotas,
  recordError,
  recordSuccess,
  type ProviderQuotaRow,
} from "./quota.ts";

// Provider registry, keyed by id. Order doesn't matter — the router scores
// candidates dynamically each request.
const PROVIDERS: Record<ProviderId, Provider> = {
  gemini: geminiProvider,
  groq: groqProvider,
  cloudflare: cloudflareProvider,
  openrouter: openrouterProvider,
  mistral: mistralProvider,
  sambanova: sambanovaProvider,
  nvidia: nvidiaProvider,
  huggingface: huggingfaceProvider,
};

// Soft preference — when two providers tie on remaining-quota ratio, this
// breaks the tie. Higher = preferred when headroom is similar. Ranks are
// monotonically distinct so ties never depend on Map insertion order.
//
// Rough rationale (verified May 2026):
//   - gemini: best receipt OCR quality, native responseSchema
//   - mistral: Pixtral 12B holds up well, native JSON mode
//   - groq: fast, OpenAI-compat, occasional vision flakiness on json_object
//   - nvidia: Llama-3.2-Vision via official NVIDIA hosting, reliable
//   - sambanova: same Llama model, ~10 RPM cap is the main constraint
//   - cloudflare: in-process Workers AI, lowest latency, 60/day cap
//   - huggingface: serverless free tier, cold starts; backup-ish
//   - openrouter: free-tier rotation, lowest tier overall
const QUALITY_RANK: Record<ProviderId, number> = {
  gemini: 8,
  mistral: 7,
  groq: 6,
  nvidia: 5,
  sambanova: 4,
  cloudflare: 3,
  huggingface: 2,
  openrouter: 1,
};

// A provider is shunned for this long after consecutive errors. Avoids
// hammering an upstream that's degraded but not formally rate-limiting us.
const ERROR_COOLDOWN_SECONDS = 60;
const ERROR_STREAK_THRESHOLD = 3;

// We stop hitting a provider when it's used >= 95% of its daily quota,
// leaving headroom for clock skew and racing requests.
const QUOTA_SAFETY_RATIO = 0.95;

export interface RouteResult {
  provider: ProviderId;
  receipt: ProviderResult["receipt"];
  poolRemaining: number;
  poolLow: boolean;
  triedProviders: Array<{ provider: ProviderId; error: string }>;
}

// Picks providers in priority order, calls them in turn, gives up when all
// eligible providers either failed or are rate-limited.
export async function route(
  req: ProviderRequest,
  env: ProviderEnv & { DB: D1Database },
  nowSec: number,
): Promise<RouteResult> {
  const quotas = await loadProviderQuotas(env.DB, nowSec);
  const ranked = rankProviders(quotas, nowSec);
  const tried: Array<{ provider: ProviderId; error: string }> = [];

  for (const candidate of ranked) {
    const provider = PROVIDERS[candidate.provider];
    try {
      const result = await provider.parse(req, env);
      // Validate that we got at least one item — empty results from a
      // healthy 200 response are usually a misread image, not a quota
      // issue. Try the next provider before giving up.
      if (result.receipt.items.length === 0) {
        await recordError(env.DB, candidate.provider, nowSec, true);
        tried.push({
          provider: candidate.provider,
          error: "empty items array",
        });
        continue;
      }
      await recordSuccess(env.DB, candidate.provider, nowSec);
      const remaining = poolRemaining(quotas, candidate.provider);
      return {
        provider: candidate.provider,
        receipt: result.receipt,
        poolRemaining: remaining,
        poolLow: remaining < 20,
        triedProviders: tried,
      };
    } catch (e) {
      const err = e instanceof ProviderError ? e : new ProviderError(
        candidate.provider,
        "upstream_error",
        e instanceof Error ? e.message : String(e),
      );
      // bad_request applies to the image regardless of provider — don't
      // burn the whole pool retrying the same broken bytes.
      const fatal = err.kind === "bad_request";
      await recordError(env.DB, candidate.provider, nowSec, err.kind === "rate_limited");
      tried.push({ provider: candidate.provider, error: err.message });
      if (fatal) break;
    }
  }

  throw new RouterExhaustedError(tried);
}

export class RouterExhaustedError extends Error {
  constructor(
    public readonly attempts: Array<{ provider: ProviderId; error: string }>,
  ) {
    super(
      `all providers failed: ${attempts
        .map((a) => `${a.provider}=${a.error.slice(0, 80)}`)
        .join("; ")}`,
    );
  }
}

interface RankedProvider {
  provider: ProviderId;
  remainingRatio: number;
  qualityRank: number;
}

function rankProviders(
  quotas: ProviderQuotaRow[],
  nowSec: number,
): RankedProvider[] {
  return quotas
    .filter((q) => isEligible(q, nowSec))
    .map<RankedProvider>((q) => ({
      provider: q.provider,
      remainingRatio: 1 - q.rpd_used / Math.max(q.rpd_limit, 1),
      qualityRank: QUALITY_RANK[q.provider],
    }))
    .sort((a, b) => {
      // Primary: prefer the provider with the LARGEST headroom — this
      // keeps the pool balanced and stops us from exhausting one provider
      // while others sit idle.
      const headroomDiff = b.remainingRatio - a.remainingRatio;
      if (Math.abs(headroomDiff) > 0.05) return headroomDiff;
      // Secondary: when headroom is similar (<5pp difference), prefer the
      // higher-quality provider so the user gets the best result available.
      return b.qualityRank - a.qualityRank;
    });
}

function isEligible(q: ProviderQuotaRow, nowSec: number): boolean {
  // Quota cap.
  if (q.rpd_used >= q.rpd_limit * QUOTA_SAFETY_RATIO) return false;
  // Error-streak cooldown.
  if (
    q.consecutive_errors >= ERROR_STREAK_THRESHOLD &&
    q.last_error_at !== null &&
    nowSec - q.last_error_at < ERROR_COOLDOWN_SECONDS
  ) {
    return false;
  }
  return true;
}

function poolRemaining(quotas: ProviderQuotaRow[], justUsed: ProviderId): number {
  return quotas.reduce((acc, q) => {
    const used = q.provider === justUsed ? q.rpd_used + 1 : q.rpd_used;
    return acc + Math.max(0, q.rpd_limit - used);
  }, 0);
}
