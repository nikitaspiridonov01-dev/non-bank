import type { Provider, ProviderEnv } from "./base.ts";
import { coerceReceipt } from "./base.ts";
import type { ProviderRequest, ProviderResult } from "../types.ts";
import { ProviderError } from "../types.ts";
import {
  RECEIPT_SYSTEM_PROMPT,
  RECEIPT_JSON_SCHEMA,
  buildUserPrompt,
} from "../prompt.ts";
import { toBase64 } from "../lib/bytes.ts";

// Gemini 2.5 Flash-Lite — primary provider.
// Free tier: 1000 RPD, 15 RPM. Native `responseSchema` (OpenAPI 3.0 subset).
// Quota is per GCP *project*, not per key — picking Flash-Lite over Flash
// because Flash-Lite alone gives us the bigger 1000 RPD pool.
//
// Endpoint: v1beta is the only one exposing structured-output features; v1
// lags by months. Auth header `x-goog-api-key` (not `Authorization`).
const ENDPOINT =
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent";

export const geminiProvider: Provider = {
  id: "gemini",
  dailyLimit: 1000,
  async parse(req: ProviderRequest, env: ProviderEnv): Promise<ProviderResult> {
    if (!env.GEMINI_API_KEY) {
      throw new ProviderError(
        "gemini",
        "auth_error",
        "GEMINI_API_KEY not set",
      );
    }
    const body = {
      systemInstruction: { parts: [{ text: RECEIPT_SYSTEM_PROMPT }] },
      contents: [
        {
          role: "user",
          parts: [
            { text: buildUserPrompt(req.categories, req.localeHint) },
            {
              inline_data: {
                mime_type: req.imageMime,
                data: toBase64(req.imageBytes),
              },
            },
          ],
        },
      ],
      generationConfig: {
        responseMimeType: "application/json",
        responseSchema: RECEIPT_JSON_SCHEMA,
        temperature: 0.1,
      },
    };

    const res = await fetch(ENDPOINT, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-goog-api-key": env.GEMINI_API_KEY,
      },
      body: JSON.stringify(body),
    });

    if (res.status === 429) {
      throw new ProviderError(
        "gemini",
        "rate_limited",
        await safeText(res),
        429,
      );
    }
    if (res.status === 401 || res.status === 403) {
      throw new ProviderError(
        "gemini",
        "auth_error",
        await safeText(res),
        res.status,
      );
    }
    if (res.status === 400) {
      throw new ProviderError(
        "gemini",
        "bad_request",
        await safeText(res),
        400,
      );
    }
    if (!res.ok) {
      throw new ProviderError(
        "gemini",
        "upstream_error",
        await safeText(res),
        res.status,
      );
    }

    const data = (await res.json()) as GeminiResponse;
    // Gemini puts the JSON-as-text inside candidates[0].content.parts[0].text.
    // With responseSchema set, the text IS the JSON object as a string.
    const text =
      data.candidates?.[0]?.content?.parts?.[0]?.text ??
      data.candidates?.[0]?.content?.parts?.find((p) => "text" in p)?.text;
    if (!text) {
      throw new ProviderError(
        "gemini",
        "bad_response",
        `no text in candidates: ${JSON.stringify(data).slice(0, 300)}`,
      );
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch (e) {
      throw new ProviderError(
        "gemini",
        "bad_response",
        `JSON parse failed: ${text.slice(0, 200)}`,
      );
    }
    return {
      receipt: coerceReceipt(parsed, "gemini"),
      rawResponseSnippet: text.slice(0, 500),
    };
  },
};

interface GeminiResponse {
  candidates?: Array<{
    content?: {
      parts?: Array<{ text?: string }>;
    };
  }>;
}

async function safeText(res: Response): Promise<string> {
  try {
    return (await res.text()).slice(0, 500);
  } catch {
    return `<unreadable body, status ${res.status}>`;
  }
}
