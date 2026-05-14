# non-bank Receipt Proxy

Cloudflare Worker that receives a receipt image from the iOS app and returns a normalized `ParsedReceipt` JSON. Routes across four free vision-LLM providers with smart quota tracking and automatic fallback.

```
iOS app  ──multipart──▶  Worker  ──pick best provider──▶  [Gemini | Groq | CF Workers AI | OpenRouter]
                            │
                            └──▶ D1 (provider quotas + per-device daily limits)
```

If all four providers are exhausted, the Worker returns `503 all_providers_unavailable` and iOS falls back to its local Vision OCR.

---

## Deployment — one-time setup

You'll register four free accounts (no credit card needed for any of them). At each step, copy the API key — you'll paste them into Wrangler at the end.

### 1. Cloudflare account + Wrangler CLI

1. Sign up at https://dash.cloudflare.com/sign-up — free, no card.
2. Install Node.js 20+ (if you don't already have it): `brew install node`.
3. From this `backend/` directory:

   ```bash
   cd /Users/nikitaspiridonov/myApp/backend
   npm install
   npx wrangler login    # opens browser, click "Allow"
   ```

### 2. Create the D1 database

```bash
npm run db:create
```

The command prints a `database_id`. Copy it and paste it into `wrangler.toml`, replacing `REPLACE_AFTER_CREATE`:

```toml
[[d1_databases]]
binding = "DB"
database_name = "non-bank-receipts"
database_id = "<paste-here>"
migrations_dir = "migrations"
```

Apply the schema:

```bash
npm run db:migrate:remote
```

### 3. Google AI Studio (Gemini)

1. Go to https://aistudio.google.com/apikey
2. Sign in with a Google account.
3. Click **"Create API key"** → choose **"Create API key in new project"** (gives you the full 1000 RPD on a fresh project quota).
4. Copy the key.
5. Save as Worker secret:

   ```bash
   npx wrangler secret put GEMINI_API_KEY
   # paste the key when prompted
   ```

> **Privacy heads-up:** the free tier sends your data to Google for model training. Mention this in your app's privacy disclosure.

### 4. Groq Cloud

1. Go to https://console.groq.com/keys
2. Sign up (Google / GitHub login works).
3. Click **"Create API Key"**, name it `non-bank-receipts`.
4. Copy the key (it's shown once — save it now).
5. Save as Worker secret:

   ```bash
   npx wrangler secret put GROQ_API_KEY
   ```

### 5. OpenRouter

1. Go to https://openrouter.ai/settings/keys
2. Sign up (Google login works, no card needed for free models).
3. Click **"Create Key"**, name it `non-bank-receipts`.
4. Copy the key.
5. Save as Worker secret:

   ```bash
   npx wrangler secret put OPENROUTER_API_KEY
   ```

> Free tier on OpenRouter is 50 RPD across the whole pool of users. This is the lowest-priority provider; the router only hits it when the others are exhausted or erroring.

### 6. Cloudflare Workers AI (no API key needed)

This one runs on the same Worker via the `[ai]` binding in `wrangler.toml`. Cloudflare gives you 10,000 free neurons/day automatically — nothing to configure.

### 7. Deploy

```bash
npm run deploy
```

The output ends with a URL like `https://non-bank-receipt-proxy.YOUR-SUBDOMAIN.workers.dev` — that's your endpoint. Save it; iOS needs it.

### 8. Smoke-test the deploy

Health check:

```bash
curl https://non-bank-receipt-proxy.YOUR-SUBDOMAIN.workers.dev/v1/health
# → {"ok":true,"env":"production"}
```

Quota snapshot:

```bash
curl https://non-bank-receipt-proxy.YOUR-SUBDOMAIN.workers.dev/v1/quota
# → {"providers":[{"provider":"gemini","rpd_used":0,"rpd_limit":1000,...}, ...]}
```

End-to-end with a real receipt photo:

```bash
curl -X POST https://non-bank-receipt-proxy.YOUR-SUBDOMAIN.workers.dev/v1/parse-receipt \
  -F image=@/path/to/receipt.jpg \
  -F device_id=test-device-12345 \
  -F 'categories=[{"name":"Groceries","emoji":"🛒"},{"name":"Restaurants","emoji":"🍕"}]' \
  -F locale=en_RS
```

You should get back JSON with `receipt`, `provider`, and `pool_remaining`.

---

## Local development

```bash
cp .dev.vars.example .dev.vars   # paste keys for local testing
npm run db:migrate:local
npm run dev                       # → http://localhost:8787
```

`wrangler dev` uses a local SQLite for D1 — your remote quotas aren't affected.

---

## Operations

### Tail live logs

```bash
npm run tail
```

### Reset all quotas (e.g. after testing)

```bash
npm run db:console:remote -- "UPDATE provider_quotas SET rpd_used = 0, consecutive_errors = 0"
```

### Reset one device's daily count

```bash
npm run db:console:remote -- "DELETE FROM device_quotas WHERE device_id = 'TARGET_ID'"
```

### Inspect provider health

```bash
npm run db:console:remote -- "SELECT provider, rpd_used, rpd_limit, consecutive_errors, total_errors, total_requests FROM provider_quotas"
```

---

## API contract

### `POST /v1/parse-receipt`

**Request:** `multipart/form-data`

| Part         | Type     | Required | Notes                                                                   |
|--------------|----------|----------|-------------------------------------------------------------------------|
| `image`      | file     | yes      | JPEG/PNG/HEIC/WEBP, ≤ 5 MB (target ~3 MB after iOS resize)              |
| `device_id`  | string   | yes      | iOS IDFV, 8-128 chars                                                   |
| `categories` | string   | no       | JSON array `[{"name":"Groceries","emoji":"🛒"}, ...]` — max 50          |
| `locale`     | string   | no       | e.g. `en_RS`, `ru_RU` — currency disambiguation hint                    |

**200 response:**

```json
{
  "receipt": {
    "storeName": "Maxi",
    "date": "2026-05-01",
    "currency": "RSD",
    "totalAmount": 1450,
    "suggestedCategory": "Groceries",
    "items": [
      {"name": "Milk 1L", "quantity": 1, "price": 219, "total": 219},
      {"name": "Bread",   "quantity": 2, "price": 75,  "total": 150}
    ]
  },
  "provider": "gemini",
  "pool_remaining": 2003,
  "pool_low": false
}
```

**Headers on success:**

- `x-device-remaining`: requests left for this device today
- `x-provider`: which provider answered

**Error codes:**

| Status | `error`                       | iOS should…                                          |
|--------|-------------------------------|------------------------------------------------------|
| 400    | `bad_request`                 | Show error, don't retry                              |
| 413    | `bad_request` (size)          | Re-compress image smaller, retry once                |
| 429    | `device_rate_limited`         | Show "daily limit", fall back to local OCR for today |
| 503    | `all_providers_unavailable`   | Fall back to local OCR for this scan                 |

---

## File map

```
backend/
├── README.md                       ← you are here
├── package.json
├── wrangler.toml                   ← bindings (DB, AI) + public env
├── tsconfig.json
├── vitest.config.ts
├── .dev.vars.example               ← template for local secrets
├── migrations/
│   └── 0001_init.sql               ← D1 schema + provider seed rows
├── src/
│   ├── index.ts                    ← Worker entry, route dispatch
│   ├── router.ts                   ← Smart provider selection + fallback
│   ├── quota.ts                    ← D1 read/write for both quota tables
│   ├── prompt.ts                   ← Shared system prompt + JSON schema
│   ├── types.ts                    ← ParsedReceipt + provider contract
│   ├── lib/
│   │   └── bytes.ts                ← Chunked base64 encoder
│   └── providers/
│       ├── base.ts                 ← Provider interface + JSON coercion
│       ├── gemini.ts               ← Google Gemini 2.5 Flash-Lite
│       ├── groq.ts                 ← Groq Llama 4 Scout 17B
│       ├── cloudflare.ts           ← CF Workers AI (Llama 3.2 11B Vision)
│       └── openrouter.ts           ← OpenRouter (Qwen3-VL → Gemma-4 fallback)
└── test/
    └── router.test.ts              ← JSON coercion + extraction smoke tests
```
