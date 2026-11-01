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

// How many models must agree that one band of a tall receipt holds no items
// before that is the answer. The iOS app splits a tall receipt into
// overlapping bands and parses each separately, and a band can legitimately
// be empty: the header above the first line, or the footer under the total
// (payment details, fiscal block, QR code). Without this, an empty band
// walked the whole pool: every provider billed, every provider's error
// streak bumped toward the cooldown (shared by all users), and in the end a
// 503 that made the app abandon the tiled parse altogether. Two agreeing
// models is the answer; the first empty one may still be a misread.
const EMPTY_BAND_AGREEMENT = 2;

export interface RouteOptions {
  // The image is one band of a tall receipt (multipart field `band=1`):
  // an empty item list is a valid answer once EMPTY_BAND_AGREEMENT models
  // agree on it.
  band?: boolean;
  // Provider registry override; tests only.
  providers?: Partial<Record<ProviderId, Provider>>;
}

// Picks providers in priority order, calls them in turn, gives up when all
// eligible providers either failed or are rate-limited.
export async function route(
  req: ProviderRequest,
  env: ProviderEnv & { DB: D1Database },
  nowSec: number,
  // Providers the caller wants skipped this request — the client's
  // "second opinion" retry passes the provider that answered the first
  // (unreconciled) parse here, so a DIFFERENT model gets a turn. If the
  // exclusion would empty the candidate list it's ignored (better to
  // answer with the excluded provider than fail the request outright).
  excludeProviders?: ReadonlySet<string>,
  options: RouteOptions = {},
): Promise<RouteResult> {
  const registry = options.providers ?? PROVIDERS;
  const quotas = await loadProviderQuotas(env.DB, nowSec);
  const allRanked = rankProviders(quotas, nowSec);
  const ranked =
    excludeProviders && excludeProviders.size > 0
      ? allRanked.filter((r) => !excludeProviders.has(r.provider))
      : allRanked;
  const candidates = ranked.length > 0 ? ranked : allRanked;
  type Attempt = { provider: ProviderId; error: string };
  const tried: Attempt[] = [];
  const emptyBand: Array<{ attempt: Attempt; receipt: ProviderResult["receipt"] }> = [];
  // The latest empty answer, as a success like any other.
  const emptyBandResult = (): RouteResult => {
    const last = emptyBand[emptyBand.length - 1];
    const remaining = poolRemaining(quotas, last.attempt.provider);
    return {
      provider: last.attempt.provider,
      receipt: {
        ...last.receipt,
        // A footer band still carries the grand total: keep the first
        // reading of it, from the higher-ranked model.
        totalAmount: emptyBand.find((a) => a.receipt.totalAmount !== null)?.receipt.totalAmount ?? null,
      },
      poolRemaining: remaining,
      poolLow: remaining < 20,
      triedProviders: tried.filter((t) => t !== last.attempt),
    };
  };

  for (const candidate of candidates) {
    const provider = registry[candidate.provider];
    if (!provider) continue;
    try {
      const result = await provider.parse(req, env);
      if (result.receipt.items.length === 0 && options.band) {
        // A real, billed answer: count it as one, without an error streak.
        await recordSuccess(env.DB, candidate.provider, nowSec);
        const attempt: Attempt = { provider: candidate.provider, error: "empty items array" };
        tried.push(attempt);
        emptyBand.push({ attempt, receipt: result.receipt });
        if (emptyBand.length >= EMPTY_BAND_AGREEMENT) return emptyBandResult();
        continue;
      }
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

  // A band one model called empty, with no second model left to confirm it:
  // that answer still beats a 503 that would sink the whole tiled parse.
  if (emptyBand.length > 0) return emptyBandResult();

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
