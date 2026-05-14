-- Seed the four additional providers (Mistral, SambaNova, NVIDIA, Hugging
-- Face) into the quota table so the router has rows to read from on the
-- first request. `INSERT OR IGNORE` keeps this safe to re-run and avoids
-- clobbering counters if any of these rows already exist from a previous
-- deploy.
--
-- Caps are conservative free-tier headroom (see each provider's source
-- file for the upstream documented limits and the rationale behind the
-- number chosen here):
--   - mistral:     Free Experiment ~500K TPM/day ÷ ~2K tokens/receipt
--   - sambanova:   Free Cloud — 10 RPM, generous TPM
--   - nvidia:      Credit-based dev tier (1000 lifetime credits)
--   - huggingface: Free Serverless Inference Providers
INSERT OR IGNORE INTO provider_quotas (provider, rpd_used, rpd_limit, reset_at)
VALUES
  ('mistral',     0, 200, 0),
  ('sambanova',   0, 150, 0),
  ('nvidia',      0,  50, 0),
  ('huggingface', 0, 200, 0);
