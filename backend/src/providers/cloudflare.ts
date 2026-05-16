import type { Provider, ProviderEnv } from "./base.ts";
import { coerceReceipt, extractJSON } from "./base.ts";
import type { ProviderRequest, ProviderResult } from "../types.ts";
import { ProviderError } from "../types.ts";
import {
  RECEIPT_SYSTEM_PROMPT,
  buildUserPrompt,
} from "../prompt.ts";

// Cloudflare Workers AI — Llama 3.2 11B Vision Instruct.
// Runs ON the same Worker via `env.AI.run()` — no network hop, no auth dance,
// counted against the 10k neurons/day free pool (~50-80 receipts/day).
//
// Two non-obvious things about this binding:
//   1. The image is passed as a *number array* (uint8 values 0-255), NOT a
//      base64 string or a data URI. Don't try to feed it `image_url` — that
//      schema only works for the 4-bit quantized variant.
//   2. There's no native JSON mode. We prompt for JSON and validate.
const MODEL = "@cf/meta/llama-3.2-11b-vision-instruct";

export const cloudflareProvider: Provider = {
  id: "cloudflare",
  dailyLimit: 60,
  async parse(req: ProviderRequest, env: ProviderEnv): Promise<ProviderResult> {
    if (!env.AI) {
      throw new ProviderError(
        "cloudflare",
        "auth_error",
        "Workers AI binding not configured",
      );
    }
    const userPrompt =
      buildUserPrompt(req.categories, req.localeHint) +
      "\n\nReturn ONLY a single JSON object. No prose, no markdown fences.";

    let result: { response?: string };
    try {
      // Llama 3.2 Vision messages-style input. The image must be in a
      // separate top-level `image` field (not inside messages) per CF docs.
      result = (await env.AI.run(MODEL, {
        messages: [
          { role: "system", content: RECEIPT_SYSTEM_PROMPT },
          { role: "user", content: userPrompt },
        ],
        image: Array.from(req.imageBytes),
        // 4096 covers ~65 receipt items at ~60 tokens each, with
        // overhead for the JSON wrapper + metadata. The previous
        // 2048 cap truncated the items array mid-emission on
        // 30+-item receipts, producing malformed JSON the router
        // logged as `bad_response` and rolled over to the next
        // provider (which had the same cap).
        max_tokens: 8192,
        temperature: 0.1,
      })) as { response?: string };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      // CF surfaces "neurons exhausted" as a generic error — match by text.
      if (/neuron|quota|limit|exceeded/i.test(msg)) {
        throw new ProviderError("cloudflare", "rate_limited", msg);
      }
      throw new ProviderError("cloudflare", "upstream_error", msg);
    }

    const text = result.response;
    if (!text) {
      throw new ProviderError(
        "cloudflare",
        "bad_response",
        `no response: ${JSON.stringify(result).slice(0, 300)}`,
      );
    }
    return {
      receipt: coerceReceipt(extractJSON(text, "cloudflare"), "cloudflare"),
      rawResponseSnippet: text.slice(0, 500),
    };
  },
};
