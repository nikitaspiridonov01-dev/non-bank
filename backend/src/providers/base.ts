import type {
  ProviderId,
  ProviderRequest,
  ProviderResult,
} from "../types.ts";
import { ProviderError } from "../types.ts";

export interface Provider {
  readonly id: ProviderId;
  // Soft daily limit — used by router to compute remaining quota ratio.
  readonly dailyLimit: number;
  parse(req: ProviderRequest, env: ProviderEnv): Promise<ProviderResult>;
}

// Subset of the Worker's Env that providers actually need. Keeps the
// providers untestable-by-design without secrets, and clearly documents
// each adapter's deps. New providers added here must also be set as
// Wrangler secrets (see `wrangler.toml` for the `wrangler secret put`
// commands) and registered in `router.ts` / the DB seed.
export interface ProviderEnv {
  GEMINI_API_KEY?: string;
  GROQ_API_KEY?: string;
  OPENROUTER_API_KEY?: string;
  MISTRAL_API_KEY?: string;
  SAMBANOVA_API_KEY?: string;
  NVIDIA_API_KEY?: string;
  HUGGINGFACE_API_KEY?: string;
  AI?: Ai; // Cloudflare Workers AI binding (typed by @cloudflare/workers-types)
}

// Validate + coerce a model's JSON output into our canonical ParsedReceipt
// shape. Most providers honor the schema, but we never trust a raw model
// response — the same logic also recovers from "the model added prose
// around the JSON" by extracting the first {...} block.
import type { ParsedReceipt, ParsedReceiptItem } from "../types.ts";

export function coerceReceipt(raw: unknown, providerId: ProviderId): ParsedReceipt {
  const obj = ensureObject(raw, providerId);
  const rawItems = ensureArray(obj.items, providerId).map((it) =>
    coerceItem(it, providerId),
  );
  const items = sanitizeDiscountSemantics(rawItems.filter(isUsableItem));
  // Diagnostic: when the model's emitted items count differs from
  // what survives `isUsableItem` filtering, surface both numbers in
  // `wrangler tail`. Used to triangulate "50-line receipt parses only
  // N items" reports — narrows the cause between
  //   (a) model returned fewer than expected (image / token / prompt
  //       issue) → raw_items already short here
  //   (b) coerceReceipt dropped items as unusable → raw_items high
  //       but filtered_items lower
  if (rawItems.length !== items.length) {
    console.log(JSON.stringify({
      ts: Date.now(),
      level: "info",
      msg: "coerceReceipt:items_filtered",
      provider: providerId,
      raw_items: rawItems.length,
      filtered_items: items.length,
    }));
  }
  const totalAmount = reconcileGrandTotal(
    nullableNumber(obj.totalAmount),
    items,
    providerId,
  );
  return {
    storeName: nullableString(obj.storeName),
    date: nullableString(obj.date),
    currency: nullableString(obj.currency),
    totalAmount,
    suggestedCategory: nullableString(obj.suggestedCategory),
    language: normalizeLanguage(nullableString(obj.language)),
    items,
  };
}

/// Lock the language tag to a stable two-letter ISO-639-1 form so the
/// iOS analytics enum doesn't have to handle BCP-47 variants or
/// uppercase. Returns `null` for anything outside that shape — iOS
/// collapses null to `.other` so unknown languages still group cleanly.
function normalizeLanguage(raw: string | null): string | null {
  if (raw == null) return null;
  // Strip BCP-47 region suffix if the model emits `en-US` instead
  // of just `en`. Models that follow the prompt return the bare
  // 2-letter code; this is defensive for the ones that drift.
  const base = raw.trim().toLowerCase().split(/[-_]/)[0];
  return /^[a-z]{2}$/.test(base) ? base : null;
}

/// Diagnostic-only check for a suspicious mismatch between the model's
/// reported grand total and the sum of the items it emitted.
///
/// The grand total is the source of truth — it's what the customer
/// actually paid per the receipt. We DO NOT auto-substitute it with
/// the items sum here, even when the gap looks pathological. Reasons:
///   1. The reported total may be right and the items may have been
///      truncated / partially OCR'd → substitution would replace a
///      correct number with an undercount.
///   2. Downstream (iOS split-by-items math, manual edits, adding
///      discounts) needs the true total to stay stable so the
///      balance check has a fixed anchor. Silently rewriting it
///      makes future user edits diverge from the receipt.
///   3. A mismatch is a real signal that the UI should surface to
///      the user, not paper over.
///
/// What we do instead: log a structured warning when the gap exceeds
/// 1.5× the reported total. Triage the underlying cause from the log
/// (model misread of total, model truncation of items, blurry image)
/// and improve the system prompt or provider config; the iOS detail
/// view already surfaces an "items don't add up" warning to the user
/// from the same data.
function reconcileGrandTotal(
  reported: number | null,
  items: ParsedReceiptItem[],
  providerId: ProviderId,
): number | null {
  if (reported == null || items.length < 3) return reported;
  const itemsSum = items.reduce((acc, it) => acc + (it.total ?? 0), 0);
  if (itemsSum > 0 && itemsSum > reported * 1.5) {
    console.log(JSON.stringify({
      ts: Date.now(),
      level: "warn",
      msg: "coerceReceipt:total_mismatch",
      provider: providerId,
      reported_total: reported,
      items_sum: itemsSum,
      ratio: itemsSum / Math.max(reported, 0.01),
    }));
  }
  return reported;
}

// Hard guard against the LLM misclassifying obvious non-discount lines as
// negative-total deductions. The prompt already tells the model "a single
// line is never a discount", but Gemini/Groq/etc. occasionally emit one
// anyway on subscription receipts (OPENAI *CHATGPT, NETFLIX, etc.). We
// flip the sign back to positive on the server so iOS never sees the
// nonsense state. Two rules:
//
//   1. If there is exactly ONE item and its total is negative — flip it.
//      A single-line receipt is the full charge by definition.
//   2. If ALL items are negative — the LLM inverted the entire receipt.
//      Flip them all so at least one positive line exists.
//
// We deliberately don't flip individual lines in a multi-item receipt
// even when their name doesn't look discount-y; the model may have seen
// a strikethrough or "−2,50" the prompt's discount-keyword list misses,
// and that's still a legitimate deduction.
function sanitizeDiscountSemantics(items: ParsedReceiptItem[]): ParsedReceiptItem[] {
  if (items.length === 0) return items;
  if (items.length === 1) {
    const only = items[0];
    if ((only.total ?? 0) < 0 || (only.price ?? 0) < 0) {
      return [{
        ...only,
        total: only.total != null ? Math.abs(only.total) : only.total,
        price: only.price != null ? Math.abs(only.price) : only.price,
      }];
    }
    return items;
  }
  const allNegative = items.every((it) => (it.total ?? 0) < 0);
  if (allNegative) {
    return items.map((it) => ({
      ...it,
      total: it.total != null ? Math.abs(it.total) : it.total,
      price: it.price != null ? Math.abs(it.price) : it.price,
    }));
  }
  return items;
}

// Strip ```json fences and find the first JSON object — for providers
// without native JSON mode (Cloudflare, sometimes OpenRouter free models).
export function extractJSON(text: string, providerId: ProviderId): unknown {
  const trimmed = text.trim();
  // Direct parse path.
  try {
    return JSON.parse(trimmed);
  } catch {
    // fall through
  }
  // Strip markdown fences.
  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]+?)```/);
  if (fenced) {
    try {
      return JSON.parse(fenced[1].trim());
    } catch {
      // fall through
    }
  }
  // Find first balanced object — handles "Here's the JSON: { ... } Hope this helps!"
  const start = trimmed.indexOf("{");
  if (start >= 0) {
    let depth = 0;
    for (let i = start; i < trimmed.length; i++) {
      const ch = trimmed[i];
      if (ch === "{") depth++;
      else if (ch === "}") {
        depth--;
        if (depth === 0) {
          try {
            return JSON.parse(trimmed.slice(start, i + 1));
          } catch {
            break;
          }
        }
      }
    }
  }
  throw new ProviderError(
    providerId,
    "bad_response",
    `could not extract JSON from response: ${trimmed.slice(0, 200)}`,
  );
}

function coerceItem(raw: unknown, providerId: ProviderId): ParsedReceiptItem {
  const obj = ensureObject(raw, providerId);
  const name = String(obj.name ?? "").trim();
  return {
    name,
    quantity: nullableNumber(obj.quantity),
    price: nullableNumber(obj.price),
    total: nullableNumber(obj.total),
  };
}

function isUsableItem(item: ParsedReceiptItem): boolean {
  if (!item.name) return false;
  const hasValue = (item.price ?? 0) !== 0 || (item.total ?? 0) !== 0;
  return hasValue;
}

function ensureObject(raw: unknown, providerId: ProviderId): Record<string, unknown> {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    throw new ProviderError(providerId, "bad_response", "expected JSON object");
  }
  return raw as Record<string, unknown>;
}

function ensureArray(raw: unknown, providerId: ProviderId): unknown[] {
  if (!Array.isArray(raw)) {
    throw new ProviderError(providerId, "bad_response", "expected array");
  }
  return raw;
}

function nullableString(v: unknown): string | null {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  return s.length === 0 ? null : s;
}

function nullableNumber(v: unknown): number | null {
  if (v === null || v === undefined) return null;
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  if (typeof v === "string") {
    const n = parseFlexibleNumber(v);
    return n;
  }
  return null;
}

// Tolerates the four ways receipts/LLMs format decimals:
//   "1100.00"   US plain                     → 1100.00
//   "1,100.00"  US thousands + dot decimal   → 1100.00
//   "1.100,00"  EU thousands + comma decimal → 1100.00
//   "550,00"    EU comma decimal             → 550.00
//   "5,5"       EU short comma decimal       → 5.50
//   "-2,50"     negative EU                  → -2.50
//   "−2,50"     unicode minus EU             → -2.50
// Matches the recovery semantics of `FlexibleDouble` on the iOS side
// (non-bank/Models/ReceiptItem.swift) so the same string lands on the
// same Double regardless of where it's parsed.
export function parseFlexibleNumber(input: string): number | null {
  // Strip whitespace and normalize unicode minus to ASCII.
  const s = input.trim().replace(/\s/g, "").replace(/[−–—]/g, "-");
  if (s.length === 0) return null;
  const hasDot = s.includes(".");
  const hasComma = s.includes(",");
  let normalized: string;
  if (hasDot && hasComma) {
    // Whichever separator appears LAST is the decimal one — strip the other.
    if (s.lastIndexOf(",") > s.lastIndexOf(".")) {
      normalized = s.replace(/\./g, "").replace(",", ".");
    } else {
      normalized = s.replace(/,/g, "");
    }
  } else if (hasComma) {
    // Lone comma → always decimal in receipt context.
    normalized = s.replace(",", ".");
  } else {
    normalized = s;
  }
  const n = Number(normalized);
  return Number.isFinite(n) ? n : null;
}
