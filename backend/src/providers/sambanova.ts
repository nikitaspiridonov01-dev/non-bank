import type { Provider, ProviderEnv } from "./base.ts";
import { coerceReceipt, extractJSON } from "./base.ts";
import type { ProviderRequest, ProviderResult } from "../types.ts";
import { ProviderError } from "../types.ts";
import {
  RECEIPT_SYSTEM_PROMPT,
  buildUserPrompt,
} from "../prompt.ts";
import { toBase64 } from "../lib/bytes.ts";

// SambaNova Cloud — Llama 3.2 11B Vision Instruct.
// Free tier: 10 RPM, ~30K TPM. SambaNova publishes the free-tier rate
// limits at docs.sambanova.ai/cloud/docs/get-started/rate-limits — at
// roughly 2k tokens per receipt the per-minute budget yields about 150
// receipts/day worth of capacity once you factor in concurrency and the
// daily-reset semantics of our router.
//
// API: OpenAI-compatible Chat Completions. No native JSON mode — we ask
// the model in the prompt and use `extractJSON` to peel any prose off.
const ENDPOINT = "https://api.sambanova.ai/v1/chat/completions";
const MODEL = "Llama-3.2-11B-Vision-Instruct";

export const sambanovaProvider: Provider = {
  id: "sambanova",
  dailyLimit: 150,
  async parse(req: ProviderRequest, env: ProviderEnv): Promise<ProviderResult> {
    if (!env.SAMBANOVA_API_KEY) {
      throw new ProviderError(
        "sambanova",
        "auth_error",
        "SAMBANOVA_API_KEY not set",
      );
    }
    const dataUri = `data:${req.imageMime};base64,${toBase64(req.imageBytes)}`;
    const body = {
      model: MODEL,
      temperature: 0.1,
      max_tokens: 2048,
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
        Authorization: `Bearer ${env.SAMBANOVA_API_KEY}`,
      },
      body: JSON.stringify(body),
    });

    if (res.status === 429) {
      const retryAfter = Number(res.headers.get("retry-after") ?? "60");
      throw new ProviderError(
        "sambanova",
        "rate_limited",
        await safeText(res),
        429,
        Number.isFinite(retryAfter) ? retryAfter : 60,
      );
    }
    if (res.status === 401 || res.status === 403) {
      throw new ProviderError(
        "sambanova",
        "auth_error",
        await safeText(res),
        res.status,
      );
    }
    if (res.status === 400) {
      throw new ProviderError(
        "sambanova",
        "bad_request",
        await safeText(res),
        400,
      );
    }
    if (!res.ok) {
      throw new ProviderError(
        "sambanova",
        "upstream_error",
        await safeText(res),
        res.status,
      );
    }

    const data = (await res.json()) as ChatCompletion;
    const text = data.choices?.[0]?.message?.content;
    if (!text) {
      throw new ProviderError(
        "sambanova",
        "bad_response",
        `no content: ${JSON.stringify(data).slice(0, 300)}`,
      );
    }
    return {
      receipt: coerceReceipt(extractJSON(text, "sambanova"), "sambanova"),
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
