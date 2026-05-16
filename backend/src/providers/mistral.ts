import type { Provider, ProviderEnv } from "./base.ts";
import { coerceReceipt, extractJSON } from "./base.ts";
import type { ProviderRequest, ProviderResult } from "../types.ts";
import { ProviderError } from "../types.ts";
import {
  RECEIPT_SYSTEM_PROMPT,
  buildUserPrompt,
} from "../prompt.ts";
import { toBase64 } from "../lib/bytes.ts";

// Mistral La Plateforme — Pixtral 12B vision model.
// Free "Experiment" tier: 1 RPS, ~500K tokens/day across the workspace.
// At ~2k tokens per receipt this comfortably handles ~200 requests/day,
// which is what we seed in the DB as `rpd_limit` (conservative — leaves
// headroom for prompt drift and the occasional long itemised receipt).
// Officially documented at docs.mistral.ai/deployment/laplateforme/tier/
//
// API: OpenAI-compatible Chat Completions surface. Native `response_format
// json_object` is supported on Pixtral, which gives us clean JSON without
// needing the `extractJSON` recovery path — but we still call it for the
// rare case where the model echoes prose before the object.
const ENDPOINT = "https://api.mistral.ai/v1/chat/completions";
const MODEL = "pixtral-12b-2409";

export const mistralProvider: Provider = {
  id: "mistral",
  dailyLimit: 200,
  async parse(req: ProviderRequest, env: ProviderEnv): Promise<ProviderResult> {
    if (!env.MISTRAL_API_KEY) {
      throw new ProviderError(
        "mistral",
        "auth_error",
        "MISTRAL_API_KEY not set",
      );
    }
    const dataUri = `data:${req.imageMime};base64,${toBase64(req.imageBytes)}`;
    const body = {
      model: MODEL,
      temperature: 0.1,
      // 4096 covers ~65 items (see cloudflare.ts for rationale).
      max_tokens: 8192,
      response_format: { type: "json_object" },
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
            { type: "image_url", image_url: dataUri },
          ],
        },
      ],
    };

    const res = await fetch(ENDPOINT, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${env.MISTRAL_API_KEY}`,
      },
      body: JSON.stringify(body),
    });

    if (res.status === 429) {
      const retryAfter = Number(res.headers.get("retry-after") ?? "60");
      throw new ProviderError(
        "mistral",
        "rate_limited",
        await safeText(res),
        429,
        Number.isFinite(retryAfter) ? retryAfter : 60,
      );
    }
    if (res.status === 401 || res.status === 403) {
      throw new ProviderError(
        "mistral",
        "auth_error",
        await safeText(res),
        res.status,
      );
    }
    if (res.status === 400) {
      throw new ProviderError(
        "mistral",
        "bad_request",
        await safeText(res),
        400,
      );
    }
    if (!res.ok) {
      throw new ProviderError(
        "mistral",
        "upstream_error",
        await safeText(res),
        res.status,
      );
    }

    const data = (await res.json()) as ChatCompletion;
    const text = data.choices?.[0]?.message?.content;
    if (!text) {
      throw new ProviderError(
        "mistral",
        "bad_response",
        `no content: ${JSON.stringify(data).slice(0, 300)}`,
      );
    }
    return {
      receipt: coerceReceipt(extractJSON(text, "mistral"), "mistral"),
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
