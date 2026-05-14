// Shape returned by the Worker to iOS. Mirrors `ParsedReceipt` in the
// Swift codebase exactly — keep in sync with non-bank/Models/ReceiptItem.swift.
export interface ParsedReceiptItem {
  name: string;
  quantity: number | null;
  price: number | null;
  total: number | null;
}

export interface ParsedReceipt {
  storeName: string | null;
  date: string | null;
  currency: string | null;
  totalAmount: number | null;
  // New field — LLM picks the closest match from the category list iOS
  // sent in the request, or returns null if nothing fits.
  suggestedCategory: string | null;
  items: ParsedReceiptItem[];
}

// Wrapped response so the client can show which provider answered and how
// much quota is left across the pool.
export interface ParseResponse {
  receipt: ParsedReceipt;
  provider: ProviderId;
  // Total remaining requests across the pool (sum of unused quota for all
  // providers that aren't currently rate-limited or erroring).
  pool_remaining: number;
  // Hint for the iOS client: when `true`, fall back to local OCR for the
  // next request — the cloud is nearly tapped out.
  pool_low: boolean;
}

// Provider id is just a tag the router and iOS read back as a string;
// adding to this union extends the routing pool. The order below mirrors
// `router.ts`'s `QUALITY_RANK` — newer providers (mistral/sambanova/
// nvidia/huggingface) sit in the middle of the quality ladder between
// gemini at the top and openrouter as the last-resort cushion.
export type ProviderId =
  | "gemini"
  | "groq"
  | "cloudflare"
  | "openrouter"
  | "mistral"
  | "sambanova"
  | "nvidia"
  | "huggingface";

// Inputs forwarded to a provider adapter. Image is raw bytes (the Worker
// accepts multipart/form-data, decodes once, then hands the same bytes to
// whichever provider wins routing).
export interface ProviderRequest {
  imageBytes: Uint8Array;
  imageMime: string;
  // Existing user categories — passed to the LLM so it can pick one. We
  // send name + emoji so the model has visual context too.
  categories: Array<{ name: string; emoji?: string }>;
  // Locale hint from iOS (`Locale.current.identifier`) — helps the model
  // pick the right currency symbol family for ambiguous receipts.
  localeHint?: string;
}

export interface ProviderResult {
  receipt: ParsedReceipt;
  // For telemetry / debugging only — not exposed to iOS.
  rawResponseSnippet?: string;
}

// Errors are typed so the router can decide retry vs. give-up.
export class ProviderError extends Error {
  constructor(
    public readonly provider: ProviderId,
    public readonly kind: ProviderErrorKind,
    message: string,
    public readonly status?: number,
    public readonly retryAfterSeconds?: number,
  ) {
    super(`[${provider}] ${kind}: ${message}`);
  }
}

export type ProviderErrorKind =
  // Rate-limited or quota exhausted at provider — skip & try next.
  | "rate_limited"
  // Provider is reachable but the model returned malformed/no JSON — likely
  // a one-off; downgrade priority briefly.
  | "bad_response"
  // Network or 5xx — try next provider.
  | "upstream_error"
  // Auth/config issue — disable the provider for this request, alert in logs.
  | "auth_error"
  // Image rejected (too large, wrong format) — don't retry on other providers
  // either; iOS should preprocess differently.
  | "bad_request";
