import type { Provider, ProviderEnv } from "./base.ts";
import { coerceReceipt, extractJSON } from "./base.ts";
import type { ProviderRequest, ProviderResult } from "../types.ts";
import { ProviderError } from "../types.ts";
import {
  RECEIPT_SYSTEM_PROMPT,
  buildUserPrompt,
} from "../prompt.ts";
import { toBase64 } from "../lib/bytes.ts";

// OpenRouter — last-resort cloud tier. Without paid credits this is 50 RPD
// across the whole pool, so we treat it as a *backup of last resort* in the
// router (lowest priority weighting). With $10 of credits topped up later
// the cap rises to 1000 RPD on `:free` models.
//
// Model selection: Qwen3-VL-235B-Thinking has the strongest receipt-OCR
// quality of the free vision models (verified May 2026). Gemma-4-31B is
// the documented fallback if Qwen3-VL is deprecated. We try Qwen first
// and let extractJSON() recover if either model wraps the JSON in prose.
const ENDPOINT = "https://openrouter.ai/api/v1/chat/completions";
const MODEL_PRIMARY = "qwen/qwen3-vl-235b-thinking:free";
const MODEL_FALLBACK = "google/gemma-4-31b-it:free";

export const openrouterProvider: Provider = {
  id: "openrouter",
  dailyLimit: 45,
  async parse(req: ProviderRequest, env: ProviderEnv): Promise<ProviderResult> {
    if (!env.OPENROUTER_API_KEY) {
      throw new ProviderError(
        "openrouter",
        "auth_error",
        "OPENROUTER_API_KEY not set",
      );
    }
    try {
      return await callModel(MODEL_PRIMARY, req, env);
    } catch (e) {
      // Fall back to the secondary model on either of:
      //   - `bad_request` — primary model was deprecated (OpenRouter
      //     returns 404 with `model_not_found`), so the model name
      //     itself is gone
      //   - `rate_limited` — the primary `:free` model is
      //     globally rate-limited "upstream" (this is the common
      //     case for the big popular Qwen3-VL-235B model). The
      //     fallback Gemma is less in-demand and often still works.
      if (
        e instanceof ProviderError &&
        (e.kind === "bad_request" || e.kind === "rate_limited")
      ) {
        return await callModel(MODEL_FALLBACK, req, env);
      }
      throw e;
    }
  },
};

async function callModel(
  model: string,
  req: ProviderRequest,
  env: ProviderEnv,
): Promise<ProviderResult> {
  const dataUri = `data:${req.imageMime};base64,${toBase64(req.imageBytes)}`;
  const body = {
    model,
    temperature: 0.1,
    // 4096 covers ~65 items (see cloudflare.ts for rationale).
    max_tokens: 8192,
    messages: [
      { role: "system", content: RECEIPT_SYSTEM_PROMPT },
      {
        role: "user",
        content: [
          {
            type: "text",
            text:
              buildUserPrompt(req.categories, req.localeHint) +
              "\n\nReturn ONLY a single JSON object. No prose, no markdown fences.",
          },
          { type: "image_url", image_url: { url: dataUri } },
        ],
      },
    ],
  };

  const res = await fetch(ENDPOINT, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${env.OPENROUTER_API_KEY!}`,
      // OpenRouter requires these headers for free-tier requests; they're
      // also displayed in their dashboard so you can identify your traffic.
      "HTTP-Referer": "https://github.com/nikitaspiridonov01-dev/non-bank",
      "X-Title": "non-bank receipt scanner",
    },
    body: JSON.stringify(body),
  });

  if (res.status === 429) {
    throw new ProviderError(
      "openrouter",
      "rate_limited",
      await safeText(res),
      429,
    );
  }
  if (res.status === 401 || res.status === 403) {
    throw new ProviderError(
      "openrouter",
      "auth_error",
      await safeText(res),
      res.status,
    );
  }
  if (res.status === 400 || res.status === 404) {
    throw new ProviderError(
      "openrouter",
      "bad_request",
      await safeText(res),
      res.status,
    );
  }
  if (!res.ok) {
    throw new ProviderError(
      "openrouter",
      "upstream_error",
      await safeText(res),
      res.status,
    );
  }

  const data = (await res.json()) as ChatCompletion;
  const text = data.choices?.[0]?.message?.content;
  if (!text) {
    throw new ProviderError(
      "openrouter",
      "bad_response",
      `no content: ${JSON.stringify(data).slice(0, 300)}`,
    );
  }
  return {
    receipt: coerceReceipt(extractJSON(text, "openrouter"), "openrouter"),
    rawResponseSnippet: text.slice(0, 500),
  };
}

interface ChatCompletion {
  choices?: Array<{ message?: { content?: string } }>;
}

async function safeText(res: Response): Promise<string> {
  try {
    return (await res.text()).slice(0, 500);
  } catch {
    return `<unreadable body, status ${res.status}>`;
  }
}
