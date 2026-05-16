-- Server-side storage for receipt items associated with a share-link.
--
-- Why this exists
-- ----------------
-- The share-URL payload encodes the transaction's financial summary
-- (total, splits, participants) but NOT the receipt items list —
-- items would balloon the URL past comfortable iMessage / Telegram
-- preview length and the existing encoder strips them. Recipients
-- have always seen `byItems`-mode shares as `byAmount` on the wire.
--
-- This table lets the sender's app upload the items to the Worker
-- after generating the URL; recipients fetch them back by the
-- payload checksum and reconstruct `byItems` locally. iOS never
-- sends plaintext: items are encrypted client-side with a key
-- derived from the URL payload (HKDF / AES-256-GCM), so the Worker
-- stores opaque ciphertext and can't decode the data on its own.
--
-- Lifecycle / cost model
-- ----------------------
--   - `share_id` keys the row to the URL's payload checksum (same
--     value `SharedTransactionPayload.checksum` produces on iOS).
--   - `expires_at` runs a 30-day TTL from last activity. Every GET
--     refreshes it; rows untouched for 30 days are eligible for
--     deletion (lazy at-read OR future Cron Trigger sweep).
--   - At Cloudflare D1 Free-tier scale (5 GB storage / 100k writes
--     per day) this table comfortably hosts millions of active
--     shares — see commit notes for the headroom math.
--
-- Snapshot semantics: re-uploading the same `share_id` overwrites
-- the row. The sender's explicit Share action is the only path
-- that re-uploads — silent local edits do NOT touch this table.
CREATE TABLE IF NOT EXISTS share_items (
  share_id TEXT PRIMARY KEY,
  -- Opaque ciphertext bundle: nonce || ciphertext || auth_tag, base64.
  -- iOS-side codec lives next to the share-link encoder.
  payload BLOB NOT NULL,
  -- Length cap is enforced at the API layer; this column is just for
  -- forensics ("how big was the row that hit the 10KB limit?").
  payload_size INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  last_opened_at INTEGER NOT NULL,
  opens_count INTEGER NOT NULL DEFAULT 0
);

-- For the eventual TTL sweep — `WHERE expires_at < now` is one of
-- the two queries that ever touches this table at scale.
CREATE INDEX IF NOT EXISTS idx_share_items_expires ON share_items(expires_at);

-- Reserved for an LRU eviction pass if the storage budget ever bites
-- (it won't at current scale — 5 GB / 1.5 KB per share = ~3M rows of
-- headroom). Kept inexpensive (B-tree on one integer column) so we
-- don't have to migrate when the time comes.
CREATE INDEX IF NOT EXISTS idx_share_items_last_opened ON share_items(last_opened_at);
