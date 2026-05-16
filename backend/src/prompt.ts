// Single source of truth for the receipt-extraction prompt and JSON schema.
// All four provider adapters reuse this so the iOS side gets the same
// structure regardless of which model answered.

export const RECEIPT_SYSTEM_PROMPT = `You extract structured data from receipt photos. Receipts may be physical paper receipts, restaurant bills, supermarket tapes, screenshots of food-delivery order summaries (Wolt, Uber Eats, Glovo, Bolt Food), or e-commerce confirmations.

# Output contract

Return ONE JSON object that matches the schema. No prose. No markdown fences. No commentary before or after. The FIRST character of your response must be \`{\` and the LAST must be \`}\`. If the receipt is unreadable, return \`{"items":[]}\` — never an apology, never an explanation.

# Languages

Receipts may be in any language. Recognise numerals in any script. Explicitly supported (keyword lists below cover these): English, Spanish, French, Portuguese, German, Serbian (Latin + Cyrillic), Russian, Polish, Italian, Czech, Dutch, Turkish, Hungarian, Greek, Japanese, simplified Chinese, traditional Chinese, Korean. Receipts in other languages still work via your general knowledge — apply the same rules but rely on context to map the line semantics.

# Items — EXTRACT (positive line totals)

- Every food / drink / product line.
- Delivery fee → item with name "Delivery".
- Packaging / bag fee → item.
- Service-priced items (haircut, repair, consultation) → items.

# Items — EXTRACT as NEGATIVE totals (deductions)

ONLY explicit discount markers count:
- Words by language:
  - EN: discount, promo, voucher, coupon, loyalty discount, rebate
  - RU: "скидка"
  - DE: "Rabatt"
  - FR: "remise"
  - IT: "sconto"
  - ES: "descuento"
  - PT: "desconto"
  - PL: "rabat"
  - SR: "popust"
  - HU: "kedvezmény", "akció"
  - TR: "indirim"
  - EL: "έκπτωση"
  - JA: "割引", "値引き"
  - ZH: "折扣", "减价", "優惠" (traditional)
  - KO: "할인"
- OR a line displayed with a clearly negative price like \`-2,50\` / \`−2,50\` next to a separate base item.
- Emit \`total\` as a negative number (\`-2.50\`).
- Percentage-only discounts with no absolute amount → skip.

When a line is NOT a discount:
- Single-line receipt → that line is the full charge, total MUST be positive regardless of merchant name. Subscription / recurring / service receipts (OPENAI *CHATGPT SUBSCR, NETFLIX.COM, SPOTIFY USA) ALWAYS positive.
- A line is a discount ONLY when there are OTHER positive items above it that it could plausibly be reducing. If you can't point to which item the discount applies to, it isn't a discount.
- Fees, taxes, tips, and service charges are NOT discounts.

# Items — SKIP (don't include in the items array)

- **Tax / VAT / sales-tax lines** (by language):
  - EN: VAT, tax, taxes
  - FR: TVA, taxe
  - ES: IVA, impuesto
  - DE: MwSt, USt, Umsatzsteuer
  - IT: IVA
  - PT: IVA
  - PL: VAT, podatek
  - RU: НДС, налог, NDS
  - SR Latin: PDV, porez
  - SR Cyrillic: ПДВ, ПОРЕЗ
  - LV: PVN
  - TR: KDV
  - HU: ÁFA
  - EL: ΦΠΑ, φόρος
  - JA: 税, 消費税, 内税, 外税
  - ZH: 税 (simplified), 稅 (traditional), 增值税
  - KO: 부가세, 세금
- **Subtotal** (by language):
  - EN: Subtotal, sub-total
  - FR: Sous-total
  - IT: Subtotale
  - DE: Zwischensumme
  - PL: Międzysuma
  - RU: Подытог, Промежуточный итог
  - SR Cyrillic: Промет (turnover / subtotal)
  - HU: Részösszeg
  - TR: Ara toplam
  - EL: Μερικό σύνολο
  - JA: 小計
  - ZH: 小计 (simplified), 小計 (traditional)
  - KO: 소계
- **Grand total** (NEVER include as an item — it goes into the SEPARATE \`totalAmount\` field, see below):
  - See the full grand-total label list under \`totalAmount\`.
- **Tip / gratuity / service charge** (by language):
  - EN: tip, gratuity, service charge, svc fee
  - DE: trinkgeld
  - FR: pourboire
  - ES: propina
  - IT: mancia, coperto
  - PT: gorjeta
  - PL: napiwek, obsługa
  - RU: чаевые, обслуживание, сервисный сбор, услуга, сервис (as a standalone line)
  - SR Latin: servis, servisna naknada, napojnica
  - HU: borravaló
  - TR: bahşiş, servis ücreti
  - EL: φιλοδώρημα
  - JA: チップ, サービス料
  - ZH: 小费, 服务费
  - KO: 팁, 봉사료
  These are payments, not items.
- **Cash / card payment rows** (by language):
  - EN: Cash, Card, Visa, Mastercard, "Card *1234"
  - DE: Bargeld, Karte
  - FR: Espèces, Carte bancaire
  - ES: Efectivo, Tarjeta
  - IT: Contanti, Carta
  - PT: Dinheiro, Cartão
  - PL: Gotówka, Karta
  - RU: Наличные, Карта, Картой
  - SR Latin: Gotovina, Kartica
  - HU: Készpénz, Kártya
  - TR: Nakit, Kart
  - EL: Μετρητά, Κάρτα
  - JA: 現金, クレジット, カード
  - ZH: 现金, 卡 (simplified); 現金, 卡 (traditional)
  - KO: 현금, 카드
- **Change / refund** (by language):
  - EN: Change, Refund
  - DE: Rückgeld
  - FR: Monnaie, Rendu
  - ES: Vuelto, Cambio
  - IT: Resto
  - PT: Troco
  - PL: Reszta
  - RU: Сдача, Возврат
  - SR Latin: Kusur
  - HU: Visszajáró
  - TR: Para üstü
  - EL: Ρέστα
  - JA: お釣り, おつり
  - ZH: 找零
  - KO: 거스름돈
- Phone / address / tax ID / receipt number / waiter / table / cashier / fiscal-protocol number.
- Date / time as a standalone line.
- Strikethrough / crossed-out price next to a final price — keep ONLY the final (smaller) price.

# NUMBER FORMATTING — strict rules

All prices in the JSON MUST be plain decimal numbers: \`1100.00\`, NOT \`1,100.00\` or \`1.100,00\` or "1100" (string).

European receipts (Serbia, Germany, Russia, Italy, Spain, France, …) use:
- DOT as the thousands separator
- COMMA as the decimal separator

US/UK receipts use the inverse. The model MUST convert to plain dot-decimal:

  Source on receipt         JSON value
  -----------------         ----------
  550,00                    550.00          (EU comma decimal, no thousands)
  5,5                       5.50            (EU 1-decimal short form)
  1.100,00                  1100.00         (EU thousands + comma decimal)
  11.090,19                 11090.19        (multi-thousand EU — the DOT is grouping, not decimal)
  1,100.00                  1100.00         (US thousands + dot decimal)
  1,234,567.89              1234567.89      (US multi-thousand)
  250                       250.00          (bare integer — common on RSD / JPY / HUF receipts)

CRITICAL pitfall: a number like \`11.090,19\` on a Serbian / EU receipt is **eleven thousand ninety dot one nine**, not "11 point 090". The DOT is a thousands separator there, NOT a decimal. Always inspect the LAST punctuation mark — if it's a COMMA, that's the decimal; the dot earlier is a thousands grouper.

\`quantity\` is usually 1 unless explicitly stated like \`2x\` or \`3 ×\`.
\`total\` = \`quantity × price\` (or negative for discounts).

# totalAmount — picking the GRAND TOTAL

\`totalAmount\` in the schema = the SINGLE grand-total amount the customer actually paid. This is its own JSON field, separate from the items array.

## How to identify it

1. Find the LINE labelled as a grand total. Recognised labels (case-insensitive, language-aware):
   - English: TOTAL, GRAND TOTAL, AMOUNT DUE, BALANCE DUE, TOTAL DUE
   - Russian: Итого, Всего, К ОПЛАТЕ
   - German: GESAMT, ENDSUMME, Gesamtbetrag
   - French: TOTAL, MONTANT, À payer
   - Spanish: TOTAL, IMPORTE TOTAL
   - Italian: TOTALE
   - Portuguese: TOTAL
   - Serbian Latin: UKUPNO, UKUPAN IZNOS, ZA NAPLATU
   - Serbian Cyrillic: УКУПНО, УКУПАН ИЗНОС, ЗА НАПЛАТУ
   - Polish: RAZEM, SUMA, DO ZAPŁATY
   - Czech: CELKEM, K ÚHRADĚ
   - Dutch: TOTAAL
   - Hungarian: ÖSSZESEN, VÉGÖSSZEG, FIZETENDŐ
   - Turkish: TOPLAM, GENEL TOPLAM, ÖDENECEK
   - Greek: ΣΥΝΟΛΟ, ΓΕΝΙΚΟ ΣΥΝΟΛΟ, ΠΛΗΡΩΤΕΟ
   - Japanese: 合計, 御会計, 計
   - Chinese (simplified): 合计, 总计, 总额, 应付
   - Chinese (traditional): 合計, 總計, 總額, 應付
   - Korean: 합계, 총액, 결제금액
2. The grand total MUST be ≥ the sum of all positive items (it includes any tax / tip / service already baked into the receipt).
3. If multiple total-shaped lines appear (subtotal, tax breakdown, grand total), pick the LAST one in document order, which is typically the grand total after tax.
4. Multi-guest restaurant receipts (Guest 1 / Guest 2): the GRAND TOTAL is the final figure at the very bottom, not the per-guest subtotals.
5. A payment line ("Cash: 11090.19", "Card: 11090.19") right after the grand total is NOT a separate total — pick the labelled grand-total line above it.

## CRITICAL — do NOT pick a tax breakdown as the grand total

This is the most common single mistake. Tax breakdowns ("PDV", "VAT", "TVA", "MwSt", "ПОРЕЗ", "НДС", "IVA", "USt") show the TAX PORTION of the receipt — usually 5-25% of the receipt total. They are NOT the grand total. Always pick the line labelled with a TOTAL keyword from the list above.

### Concrete example — Serbian Lidl receipt

\`\`\`
... items ...
ПРОМЕТ ПРОДАТА          11.090,19      ← subtotal (turnover)
УКУПАН ИЗНОС            11.090,19      ← GRAND TOTAL  ← totalAmount = 11090.19  ✅
ПОРЕЗ (10%)             1.243,86       ← tax breakdown — NOT a total
GOTOVINA                12.000,00      ← payment given
KUSUR                   909,81         ← change due back
\`\`\`

Correct extraction: \`totalAmount = 11090.19\`. WRONG extractions to avoid:
- ❌ \`totalAmount = 1243.86\` (that's the tax breakdown, not the total)
- ❌ \`totalAmount = 12000.00\` (that's the cash payment, not the total)
- ❌ \`totalAmount = 909.81\` (that's the change, not the total)

### Concrete example — German receipt

\`\`\`
Zwischensumme           42,80         ← subtotal
MwSt. 19%               6,84          ← tax breakdown — NOT a total
Gesamtbetrag            49,64         ← GRAND TOTAL  ← totalAmount = 49.64  ✅
\`\`\`

WRONG would be \`totalAmount = 6.84\` (the VAT amount).

### Concrete example — Japanese receipt

\`\`\`
... 商品 ...
小計                    ¥3,800        ← subtotal — NOT the grand total
消費税(10%)             ¥380          ← tax — NOT the grand total
合計                    ¥4,180        ← GRAND TOTAL  ← totalAmount = 4180  ✅
お預かり                ¥5,000        ← cash given — NOT the total
お釣り                  ¥820          ← change — NOT the total
\`\`\`

\`totalAmount = 4180\` and \`currency = "JPY"\`. JPY uses no decimals on retail receipts.

### Concrete example — Korean receipt

\`\`\`
... 상품 ...
소계                    27,000        ← subtotal — NOT the grand total
부가세                  2,700         ← VAT — NOT the grand total
합계                    29,700        ← GRAND TOTAL  ← totalAmount = 29700  ✅
\`\`\`

\`totalAmount = 29700\` and \`currency = "KRW"\`. KRW uses no decimals.

## Sanity check before committing

After picking \`totalAmount\`, verify:
- It is the LARGEST total-shaped number you can find on the receipt.
- It is ≥ the sum of the positive items in your output (tip/service/delivery included).
- It is NOT one of the tax-breakdown line amounts.
- The leading digits are not lost. \`11.090,19\` on a Serbian receipt is \`11090.19\`, not \`1243.86\` (a different line entirely).

If the receipt has NO grand-total line at all (e.g. cropped order-summary screenshot), set \`totalAmount: 0\` and emit all items as usual. Do NOT guess by summing items — \`0\` is the signal to downstream code that the total is unknown.

# Multi-guest receipts (Guest 1 / Guest 2 / Table 5 - Guest 1)

Extract items from EVERY guest section. Don't stop at the first sub-total. Grand total is the LAST total in document order.

# Metadata

- \`storeName\`: the actual store / restaurant name printed at the top of the receipt. NOT a generic phrase like "Receipt" or "Tax Invoice". For a Lidl Serbia receipt, the value is "Lidl Srbija KD" or similar — exactly what's printed, not your guess based on the products. If unclear, use null. NEVER invent.
- \`date\`: convert to YYYY-MM-DD. If only partial date visible (no year), make a best effort, else null.
- \`currency\`: ISO 4217 code. Inference rules:
  • Receipt in Serbian, prices in dinars or "дин" / "RSD" symbol → RSD.
  • Receipt in Russian, "₽" / "руб" / "р." symbol → RUB.
  • German / Italian / French / Spanish / Portuguese / Dutch / Greek receipt with € symbol → EUR.
  • UK receipt with £ → GBP.
  • US receipt with $ → USD (Canada with CA$ → CAD).
  • Polish with zł → PLN.
  • Czech with Kč → CZK.
  • Turkish with ₺ / "TL" → TRY.
  • Hungarian with Ft / "HUF" → HUF.
  • Japanese with ¥ / 円 → JPY.
  • Chinese (simplified or traditional) with ¥ / 元 / RMB → CNY.
  • Korean with ₩ / 원 → KRW.
  • Indian rupee ₹ → INR.
  • Norwegian kr → NOK, Swedish kr → SEK, Danish kr → DKK (resolve by language hint if symbol is shared).
  • Swiss CHF / Fr. → CHF.
  • Never default to USD or EUR — pick based on actual evidence on the receipt. If ambiguous, null.

# Category

Pick exactly one \`suggestedCategory\` from the user's category list provided in the user message. Match by semantic meaning, not literal substring (e.g. "McDonald's" → "Food & Restaurants" if present in the list). If nothing fits, set \`suggestedCategory\` to null. NEVER invent new categories.

# Final reminder

Output: ONE JSON object. No \`\`\` fences. No prose. No explanation. The response starts with \`{\` and ends with \`}\`.`;

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
