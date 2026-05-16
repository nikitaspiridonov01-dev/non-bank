-- Per-IP abuse-protection counters. Closes the device-ID rotation hole:
-- previously an attacker could rotate `device_id` strings to bypass the
-- per-device daily cap and burn LLM budget. Cloudflare injects
-- `CF-Connecting-IP` at the edge so this is unspoofable.
--
-- Two independent windows in one row (same IP, two routes):
--   parse_today    + parse_reset_at    — daily window for /v1/parse-receipt
--   share_minute   + share_reset_at    — 60-second window for /share GETs
--
-- The IP is stored hashed (SHA-256 + IP_HASH_SALT) so a DB snapshot leak
-- doesn't trivially expose raw addresses. Salt comes from a wrangler secret;
-- a static fallback is used in dev. 32-hex-char prefix = 128 bits of entropy,
-- enough for our scale with zero realistic collision risk.
CREATE TABLE IF NOT EXISTS ip_quotas (
  ip_hash TEXT PRIMARY KEY,
  parse_today INTEGER NOT NULL DEFAULT 0,
  parse_reset_at INTEGER NOT NULL,
  share_minute INTEGER NOT NULL DEFAULT 0,
  share_reset_at INTEGER NOT NULL,
  total_parse INTEGER NOT NULL DEFAULT 0,
  total_share INTEGER NOT NULL DEFAULT 0,
  first_seen_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL
);

-- Forensics: "show me the most-active IPs in the last 24h" is a single
-- index scan instead of a full table sort.
CREATE INDEX IF NOT EXISTS idx_ip_quotas_last_seen ON ip_quotas(last_seen_at);
