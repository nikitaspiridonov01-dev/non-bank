-- Server-mediated split-transaction sync — Phase 0: friend pairing.
--
-- Why this exists
-- ----------------
-- Today a split transaction is delivered to a friend only by the sender
-- manually re-sharing a link. Once a real user opens a share link (the
-- existing onOpenURL → ShareLinkCoordinator round-trip), the two are
-- "paired" and future transactions should sync automatically. This table
-- records that pairing so Phase 1 can auto-deliver only between paired
-- users.
--
-- Privacy
-- -------
-- We store ONLY an opaque HMAC of the sorted (userA, userB) pair,
-- computed CLIENT-side, so the raw user ids — and therefore the social
-- graph — never reach the server / a D1 snapshot. The server can verify a
-- specific pairing exists (the client recomputes the same HMAC) but cannot
-- enumerate who is paired with whom. User ids are non-PII
-- adjective-noun-4digit strings regardless.
--
-- Lifecycle
-- ---------
-- Upserted on link-open (status 'active'); flipped to 'revoked' when a
-- friend is removed (Phase 1+). Pairing rows are tiny and long-lived (no
-- TTL) — at ~0.1 KB/row the 5 GB D1 free budget is never a concern here.
CREATE TABLE IF NOT EXISTS pairings (
  pair_hmac  TEXT PRIMARY KEY,             -- HMAC(appSecret, sorted(userA,userB)), 64-hex, client-computed
  created_at INTEGER NOT NULL,
  status     TEXT NOT NULL DEFAULT 'active' -- 'active' | 'revoked'
);

CREATE INDEX IF NOT EXISTS idx_pairings_status ON pairings(status);

-- Bind an attested Secure-Enclave key to its logical app user id so the
-- sync endpoints can resolve "which user is this attested request from"
-- without a separate identity service. Trust-on-first-use: the first
-- attested key to claim a user id owns it (Phase 1 tightens this if
-- needed). Nullable because rows predating this migration (and lenient
-- simulator dev with no attestation) have no bound user.
ALTER TABLE attest_keys ADD COLUMN user_id TEXT;

CREATE INDEX IF NOT EXISTS idx_attest_keys_user ON attest_keys(user_id);
