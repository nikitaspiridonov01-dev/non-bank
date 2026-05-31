-- App Attest key registry.
--
-- One row per attested Secure Enclave key (one per app install, unless
-- the user reinstalls / the key is regenerated). Populated by
-- POST /v1/attest/verify after the attestation cert chain validates;
-- read on every POST /v1/parse-receipt to verify the request's
-- assertion signature and enforce the monotonic Secure-Enclave counter.
--
-- `public_key` is the raw uncompressed P-256 point (0x04 || X || Y),
-- base64. `counter` is the last accepted Secure-Enclave signature
-- counter — a new assertion is rejected unless its counter is strictly
-- greater, which defeats replay. `env` records whether the key was
-- attested in the development or production App Attest environment
-- (useful for forensics; staging accepts dev, prod accepts prod).
CREATE TABLE IF NOT EXISTS attest_keys (
  key_id TEXT PRIMARY KEY,
  public_key TEXT NOT NULL,
  counter INTEGER NOT NULL DEFAULT 0,
  env TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL
);

-- Stale-key pruning support: a future cron can drop keys unused for N
-- days (reinstalls leave orphaned rows). Cheap B-tree on one integer.
CREATE INDEX IF NOT EXISTS idx_attest_keys_last_used ON attest_keys(last_used_at);
