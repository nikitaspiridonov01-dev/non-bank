import type { Provider, ProviderEnv } from "./base.ts";
import { coerceReceipt, extractJSON } from "./base.ts";
import type { ProviderRequest, ProviderResult } from "../types.ts";
import { ProviderError } from "../types.ts";
import {
  RECEIPT_SYSTEM_PROMPT,
  buildUserPrompt,
} from "../prompt.ts";
import { toBase64 } from "../lib/bytes.ts";

// NVIDIA NIM — Llama 3.2 11B Vision Instruct, hosted on build.nvidia.com.
// Free tier is **credit-based**, not daily-reset: a personal account gets
// 1000 lifetime credits for the dev / personal program. Each request
// consumes one credit. The router's per-day quota model doesn't natively
// fit this — we set a small `rpd_limit` (50/day) so credits last roughly
// 20 days even at saturation; once the credits are physically exhausted
// NVIDIA returns 402 / 429, the router's error-streak cooldown shuns the
// provider, and traffic falls back to the others. If you re-up credits
// you can leave the seed alone; the daily counter resets independently.
//
// API: OpenAI-compatible Chat Completions at
// integrate.api.nvidia.com/v1/chat/completions.
const ENDPOINT = "https://integrate.api.nvidia.com/v1/chat/completions";
const MODEL = "meta/llama-3.2-11b-vision-instruct";

export const nvidiaProvider: Provider = {
  id: "nvidia",
  dailyLimit: 50,
  async parse(req: ProviderRequest, env: ProviderEnv): Promise<ProviderResult> {
    if (!env.NVIDIA_API_KEY) {
      throw new ProviderError(
        "nvidia",
        "auth_error",
        "NVIDIA_API_KEY not set",
      );
    }
    const dataUri = `data:${req.imageMime};base64,${toBase64(req.imageBytes)}`;
    const body = {
      model: MODEL,
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
        Authorization: `Bearer ${env.NVIDIA_API_KEY}`,
        Accept: "application/json",
      },
      body: JSON.stringify(body),
    });

    // 402 = out of credits on the personal-dev tier; treat as rate-limited
    // so the router's cooldown kicks in rather than killing the worker.
    if (res.status === 429 || res.status === 402) {
      const retryAfter = Number(res.headers.get("retry-after") ?? "60");
      throw new ProviderError(
        "nvidia",
        "rate_limited",
        await safeText(res),
        res.status,
        Number.isFinite(retryAfter) ? retryAfter : 60,
      );
    }
    if (res.status === 401 || res.status === 403) {
      throw new ProviderError(
        "nvidia",
        "auth_error",
        await safeText(res),
        res.status,
      );
    }
    if (res.status === 400) {
      throw new ProviderError(
        "nvidia",
        "bad_request",
        await safeText(res),
        400,
      );
    }
    if (!res.ok) {
      throw new ProviderError(
        "nvidia",
        "upstream_error",
        await safeText(res),
        res.status,
      );
    }

    const data = (await res.json()) as ChatCompletion;
    const text = data.choices?.[0]?.message?.content;
    if (!text) {
      throw new ProviderError(
        "nvidia",
        "bad_response",
        `no content: ${JSON.stringify(data).slice(0, 300)}`,
      );
    }
    return {
      receipt: coerceReceipt(extractJSON(text, "nvidia"), "nvidia"),
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
