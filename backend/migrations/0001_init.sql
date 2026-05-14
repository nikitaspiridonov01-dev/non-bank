-- Per-provider quota state. One row per provider id.
-- `rpd_used` resets when `now > reset_at`.
CREATE TABLE IF NOT EXISTS provider_quotas (
  provider TEXT PRIMARY KEY,
  rpd_used INTEGER NOT NULL DEFAULT 0,
  rpd_limit INTEGER NOT NULL,
  reset_at INTEGER NOT NULL,
  consecutive_errors INTEGER NOT NULL DEFAULT 0,
  last_error_at INTEGER,
  last_success_at INTEGER,
  total_requests INTEGER NOT NULL DEFAULT 0,
  total_errors INTEGER NOT NULL DEFAULT 0
);

-- Per-device daily counter. Device id = iOS IDFV (anonymous, rotates on reinstall).
-- `requests_today` resets when `now > reset_at`.
CREATE TABLE IF NOT EXISTS device_quotas (
  device_id TEXT PRIMARY KEY,
  requests_today INTEGER NOT NULL DEFAULT 0,
  reset_at INTEGER NOT NULL,
  total_requests INTEGER NOT NULL DEFAULT 0,
  first_seen_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_device_last_seen ON device_quotas(last_seen_at);

-- Seed providers with their free-tier daily caps. `reset_at = 0` forces a
-- recalculation on first read. Caps are intentionally conservative — they
-- represent the *aggregate* free quota across all our users, not per-user.
-- We stop hitting a provider at 95% to leave headroom for clock skew.
INSERT OR IGNORE INTO provider_quotas (provider, rpd_used, rpd_limit, reset_at)
VALUES
  ('gemini',      0, 1000, 0),
  ('groq',        0, 1000, 0),
  ('cloudflare',  0,   60, 0),  -- ~10k neurons/day ÷ ~150 neurons/receipt
  ('openrouter',  0,   45, 0);  -- 50 RPD - 5 buffer
