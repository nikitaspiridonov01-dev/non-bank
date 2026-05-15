import type { Provider, ProviderEnv } from "./base.ts";
import { coerceReceipt, extractJSON } from "./base.ts";
import type { ProviderRequest, ProviderResult } from "../types.ts";
import { ProviderError } from "../types.ts";
import {
  RECEIPT_SYSTEM_PROMPT,
  buildUserPrompt,
} from "../prompt.ts";
import { toBase64 } from "../lib/bytes.ts";

// Hugging Face Inference Providers — Llama 3.2 11B Vision Instruct.
// Free serverless inference is officially documented as allowed for any
// use case within rate limits (~300 req/hour on the anonymous-ish tier
// for free users; the HF token raises that ceiling further). We seed
// the DB at 200/day — conservative even with the free quota because
// serverless cold starts can produce sporadic 503s and the router's
// error-streak rule will shun the provider briefly when that happens.
//
// API: HF's OpenAI-compatible router endpoint at router.huggingface.co.
// Same wire format as Groq / OpenRouter — `image_url` with a data URI.
const ENDPOINT = "https://router.huggingface.co/v1/chat/completions";
const MODEL = "meta-llama/Llama-3.2-11B-Vision-Instruct";

export const huggingfaceProvider: Provider = {
  id: "huggingface",
  dailyLimit: 200,
  async parse(req: ProviderRequest, env: ProviderEnv): Promise<ProviderResult> {
    if (!env.HUGGINGFACE_API_KEY) {
      throw new ProviderError(
        "huggingface",
        "auth_error",
        "HUGGINGFACE_API_KEY not set",
      );
    }
    const dataUri = `data:${req.imageMime};base64,${toBase64(req.imageBytes)}`;
    const body = {
      model: MODEL,
      temperature: 0.1,
      // 4096 covers ~65 items (see cloudflare.ts for rationale).
      max_tokens: 4096,
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
        Authorization: `Bearer ${env.HUGGINGFACE_API_KEY}`,
      },
      body: JSON.stringify(body),
    });

    // 503 from the HF router usually means the underlying model is loading
    // (cold start) — surface as rate_limited so the cooldown kicks in
    // rather than treating it as a hard failure.
    if (res.status === 429 || res.status === 503) {
      const retryAfter = Number(res.headers.get("retry-after") ?? "30");
      throw new ProviderError(
        "huggingface",
        "rate_limited",
        await safeText(res),
        res.status,
        Number.isFinite(retryAfter) ? retryAfter : 30,
      );
    }
    if (res.status === 401 || res.status === 403) {
      throw new ProviderError(
        "huggingface",
        "auth_error",
        await safeText(res),
        res.status,
      );
    }
    if (res.status === 400 || res.status === 404) {
      throw new ProviderError(
        "huggingface",
        "bad_request",
        await safeText(res),
        res.status,
      );
    }
    if (!res.ok) {
      throw new ProviderError(
        "huggingface",
        "upstream_error",
        await safeText(res),
        res.status,
      );
    }

    const data = (await res.json()) as ChatCompletion;
    const text = data.choices?.[0]?.message?.content;
    if (!text) {
      throw new ProviderError(
        "huggingface",
        "bad_response",
        `no content: ${JSON.stringify(data).slice(0, 300)}`,
      );
    }
    return {
      receipt: coerceReceipt(extractJSON(text, "huggingface"), "huggingface"),
      rawResponseSnippet: text.slice(0, 500),
    };
  },
};

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
