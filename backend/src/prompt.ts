// Single source of truth for the receipt-extraction prompt and JSON schema.
// All four provider adapters reuse this so the iOS side gets the same
// structure regardless of which model answered.

export const RECEIPT_SYSTEM_PROMPT = `You extract structured data from receipt photos. Receipts may be physical paper receipts, restaurant bills, supermarket tapes, screenshots of food-delivery order summaries (Wolt, Uber Eats, Glovo, Bolt Food), or e-commerce confirmations.

Return ONLY a JSON object matching the provided schema. No prose, no markdown fences.

LANGUAGES: receipts may be in any language. Common: English, Spanish, French, Portuguese, German, Serbian, Russian, Polish, Italian, Czech, Dutch, Turkish. Recognize numerals in any script.

ITEMS — what to EXTRACT (positive line totals):
- Every food / drink / product line
- Delivery fee — count it as an item with name "Delivery"
- Packaging / bag fee — count as an item

ITEMS — what to EXTRACT as NEGATIVE line totals (deductions):
- ONLY explicit deductions: discount, promo, voucher, coupon, loyalty discount, rebate
- Multilingual: ru "скидка", de "Rabatt", fr "remise", it "sconto", es "descuento", pl "rabat", sr "popust", pt "desconto"
- A discount line MUST be one of: (a) explicitly labelled with one of these words, or (b) shown with a clearly negative price like "-2,50" / "−2,50" alongside a separate base item.
- The line total MUST be negative: e.g. price = -2.50, total = -2.50
- If shown as "-2,50" or "−2,50", emit total = -2.50
- If the discount has only a percentage and no absolute amount, skip it

CRITICAL — when NOT to mark a line as a discount:
- A single-line receipt is NEVER a discount — that line is the full charge. Receipts that contain ONE non-skipped row are subscription / service / one-item purchases, and that row's total MUST be POSITIVE regardless of merchant name.
- A subscription / recurring charge / merchant name (e.g. "OPENAI *CHATGPT SUBSCR", "NETFLIX.COM", "SPOTIFY USA") is NEVER a discount — even if the receipt is brief. Treat as a normal positive item.
- A line is a discount ONLY when there are OTHER positive items above it that it could plausibly be reducing. If you can't point to which item the discount applies to, it isn't a discount.
- Fees, taxes, tips, and service charges are NOT discounts (they're either skipped or kept positive — see the SKIP list and "Delivery/Packaging fee" rule above).

ITEMS — what to SKIP:
- Tax / VAT / NDS / TVA / IVA / MwSt / IGV / PVN / KDV lines
- Subtotal / sub-total / Zwischensumme / Międzysuma / Подытог
- Grand total / TOTAL / Итого / Gesamt / Razem — NEVER include as an item
- Tip / gratuity / service charge in ANY language. Recognise variants like "service charge", "svc fee", "obsługa" / "napiwek" (Polish), "servis" / "servisna naknada" / "napojnica" (Serbian Latin), "обслуживание" / "сервисный сбор" / "услуга" or "сервис" as a standalone line (Cyrillic), "mancia" / "coperto" (Italian), "pourboire" (French), "trinkgeld" (German), "propina" (Spanish), "gorjeta" (Portuguese). These are payments, not items.
- Cash / card / Visa / Mastercard / "Card *1234" payment rows
- Change / refund / Сдача / Rückgeld / Reszta / Vuelto
- Phone / address / tax ID / receipt number / waiter / table / cashier
- Date / time on its own line
- Strikethrough / crossed-out price next to a final price — keep ONLY the final (smaller) price

NUMBER FORMATTING:
- Prices MUST be plain decimal numbers in JSON: 1100.00 not 1,100.00 or 1.100,00
- 1.100,00 → 1100.00 (EU thousands, comma decimal)
- 550,00 → 550.00 (EU comma decimal)
- 5,5 → 5.50 (1-decimal accepted)
- 250 → 250.00 (integer prices accepted, common on RSD/JPY/HUF receipts)
- quantity is usually 1 unless explicitly stated like "2x" or "3 ×"
- total = quantity × price for each item (or negative for discounts)

RECEIPT WITHOUT A TOTAL LINE:
- This is fine. Set totalAmount = 0 and emit all items.
- Common on order-summary screenshots cropped above the totals card.

MULTI-GUEST RECEIPTS (Guest 1 / Guest 2 / Table 5 - Guest 1):
- Extract items from EVERY guest section. Don't stop at the first sub-total.
- Grand total is the LAST one if there are several.

METADATA:
- storeName: restaurant or store name, usually at the top
- date: convert to YYYY-MM-DD format
- currency: ISO 4217 code (RSD, EUR, USD, RUB, PLN, CZK, GBP, etc.). If receipt is from Serbia (Belgrade, RSD prices) → RSD.

CATEGORY:
- Pick exactly one suggestedCategory from the user's category list provided in the user message.
- Match by semantic meaning, not literal substring (e.g. "McDonald's" → "Food & Restaurants" if present).
- If nothing fits well, set suggestedCategory to null. Do NOT invent new categories.`;

// Used by Gemini's responseSchema and by our local validator after parsing
// any provider's JSON. Note: Gemini's schema dialect is OpenAPI-3.0 subset,
// so no `oneOf`/`$ref`. We keep this intentionally simple.
export const RECEIPT_JSON_SCHEMA = {
  type: "object",
  properties: {
    storeName: { type: "string", nullable: true },
    date: {
      type: "string",
      nullable: true,
      description: "YYYY-MM-DD or null if not visible",
    },
    currency: {
      type: "string",
      nullable: true,
      description: "ISO 4217 code (e.g. EUR, USD, RSD)",
    },
    totalAmount: {
      type: "number",
      nullable: true,
      description: "Grand total as a plain decimal, or 0 if not present",
    },
    suggestedCategory: {
      type: "string",
      nullable: true,
      description:
        "Exact name from the user's category list, or null if nothing fits",
    },
    items: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          quantity: { type: "number", nullable: true },
          price: { type: "number", nullable: true },
          total: { type: "number", nullable: true },
        },
        required: ["name", "total"],
      },
    },
  },
  required: ["items"],
} as const;

// Per-field length caps for user-controlled text that ends up inside the
// LLM prompt. Two purposes:
//   1. Bound token cost — a malicious 1 MB category name would inflate
//      every parse-receipt call's prompt and burn provider quota.
//   2. Prompt-injection ceiling — even after we strip control characters,
//      a generous cap means an attacker can't fit a long alternative
//      instruction inside a single field.
// Numbers picked from real-world usage: longest legitimate iOS category
// name in the seed list is 22 chars; locale identifiers are <=10 chars
// (`sr_Latn_RS`). Caps are ~3× headroom over the legitimate maximum.
export const MAX_CATEGORY_NAME = 64;
export const MAX_CATEGORY_EMOJI = 8;
export const MAX_LOCALE_HINT = 16;

// Strip newlines, control chars, and zero-width / bidi formatting chars
// from user-supplied text before it lands in the prompt. These are the
// classic prompt-injection escape hatches — a category name containing
// `\n\nIGNORE PREVIOUS INSTRUCTIONS: ...` would otherwise reach the
// model as a separate prompt section. Whitespace collapses to single
// spaces so a long run of tabs doesn't waste cap budget.
export function sanitizePromptText(input: string, maxLength: number): string {
  return input
    // C0 + DEL controls (incl. \n, \r, \t), plus Unicode line/paragraph
    // separators (U+2028, U+2029) and the zero-width / bidi formatting
    // chars that some models honour as section breaks: U+200B-200F
    // (ZWSP, ZWNJ, ZWJ, LRM, RLM), U+202A-202E (LRE, RLE, PDF, LRO,
    // RLO), U+2060 (word joiner), U+FEFF (BOM). Replaced with a space
    // — the collapse step below squashes runs so the visible text
    // stays clean.
    .replace(/[\x00-\x1F\x7F\u2028\u2029\u200B-\u200F\u202A-\u202E\u2060\uFEFF]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, maxLength);
}

export function buildUserPrompt(
  categories: Array<{ name: string; emoji?: string }>,
  localeHint?: string,
): string {
  // Defense-in-depth: even if a future caller forgets to pre-sanitize at
  // the request boundary, the prompt builder enforces the rules itself.
  // Cheap (string ops, no allocations beyond what the slice would do).
  const safeCategories = categories.map((c) => ({
    name: sanitizePromptText(c.name, MAX_CATEGORY_NAME),
    emoji: c.emoji ? sanitizePromptText(c.emoji, MAX_CATEGORY_EMOJI) : undefined,
  }));
  const safeLocale = localeHint
    ? sanitizePromptText(localeHint, MAX_LOCALE_HINT)
    : undefined;

  const list = safeCategories.length
    ? safeCategories
        .map((c) => `- ${c.emoji ? c.emoji + " " : ""}${c.name}`)
        .join("\n")
    : "(no categories provided — set suggestedCategory to null)";
  const locale = safeLocale ? `\n\nUser locale hint: ${safeLocale}` : "";
  return `Extract the receipt from the attached image.

User's existing categories — pick the best match for suggestedCategory:
${list}${locale}`;
}
