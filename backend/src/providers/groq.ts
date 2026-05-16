import type { Provider, ProviderEnv } from "./base.ts";
import { coerceReceipt, extractJSON } from "./base.ts";
import type { ProviderRequest, ProviderResult } from "../types.ts";
import { ProviderError } from "../types.ts";
import {
  RECEIPT_SYSTEM_PROMPT,
  buildUserPrompt,
} from "../prompt.ts";
import { toBase64 } from "../lib/bytes.ts";

// Groq Llama 4 Scout 17B — secondary provider.
// Free tier: 1000 RPD, 30 RPM, 6K TPM. Sub-second responses.
// OpenAI-compat surface, so the request shape mirrors OpenRouter — keep an
// eye on the diff if you refactor a shared OpenAI helper later.
//
// Strict JSON mode (`response_format: { type: "json_object" }`) is enabled
// — early in 2025 Groq's vision path produced ~5% empty completions when
// strict JSON was on, but newer model versions are reliable. The fence-
// wrapped output we used to see (` ```json {...} ``` ` confusing the
// parser) is gone when this flag is set. `extractJSON` is kept as a
// belt-and-suspenders fallback for the rare cases the model still emits
// prose despite the flag.
const ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";
const MODEL = "meta-llama/llama-4-scout-17b-16e-instruct";

export const groqProvider: Provider = {
  id: "groq",
  dailyLimit: 1000,
  async parse(req: ProviderRequest, env: ProviderEnv): Promise<ProviderResult> {
    if (!env.GROQ_API_KEY) {
      throw new ProviderError("groq", "auth_error", "GROQ_API_KEY not set");
    }
    const dataUri = `data:${req.imageMime};base64,${toBase64(req.imageBytes)}`;
    const body = {
      model: MODEL,
      temperature: 0.1,
      // 6K TPM is the real cap; cap output to keep room for image tokens.
      // 8192 covers ~65 items (see cloudflare.ts for rationale).
      max_completion_tokens: 8192,
      // Strict JSON output — bypasses the ```json fence wrapping the
      // model otherwise produces despite "no markdown" in the prompt.
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
            { type: "image_url", image_url: { url: dataUri } },
          ],
        },
      ],
    };

    const res = await fetch(ENDPOINT, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${env.GROQ_API_KEY}`,
      },
      body: JSON.stringify(body),
    });

    if (res.status === 429) {
      const retryAfter = Number(res.headers.get("retry-after") ?? "60");
      throw new ProviderError(
        "groq",
        "rate_limited",
        await safeText(res),
        429,
        Number.isFinite(retryAfter) ? retryAfter : 60,
      );
    }
    if (res.status === 401 || res.status === 403) {
      throw new ProviderError(
        "groq",
        "auth_error",
        await safeText(res),
        res.status,
      );
    }
    if (res.status === 400) {
      throw new ProviderError(
        "groq",
        "bad_request",
        await safeText(res),
        400,
      );
    }
    if (!res.ok) {
      throw new ProviderError(
        "groq",
        "upstream_error",
        await safeText(res),
        res.status,
      );
    }

    const data = (await res.json()) as ChatCompletion;
    const text = data.choices?.[0]?.message?.content;
    if (!text) {
      throw new ProviderError(
        "groq",
        "bad_response",
        `no content: ${JSON.stringify(data).slice(0, 300)}`,
      );
    }
    return {
      receipt: coerceReceipt(extractJSON(text, "groq"), "groq"),
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
