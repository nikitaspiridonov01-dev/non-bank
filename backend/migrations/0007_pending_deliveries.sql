-- Server-mediated split-transaction sync — Phase 1: addressed deliveries.
--
-- Why this exists
-- ----------------
-- Phase 0 (0006) recorded that two users are *paired*. This table is the
-- actual delivery channel: when a user creates or edits a split, the app
-- uploads one addressed, end-to-end-encrypted delivery per paired
-- recipient. The recipient's app pulls its inbox on open, applies the
-- transaction headlessly, and acks. After ack (or a hard TTL) the row is
-- swept, so the table stays small and the social graph isn't persisted.
--
-- Privacy
-- -------
-- `recipient_id` is the raw (non-PII adjective-noun-4digit) user id — it
-- HAS to be raw because it's the inbox routing key. That's acceptable
-- because rows are transient (deleted shortly after ack, hard-capped at a
-- 14-day TTL), unlike `pairings` which is long-lived and therefore stores
-- only an opaque HMAC. `payload` is an opaque base64 AES-GCM blob the
-- Worker cannot read.
--
-- Concurrency / collisions
-- ------------------------
-- `version` is a monotonic per-(recipient, transaction) edit counter set
-- by the sender (incremented on every local edit). The upload UPSERT only
-- overwrites a stored row when the incoming version is STRICTLY GREATER
-- (see `recordDelivery` in src/sync.ts), so:
--   * an out-of-order / delayed delivery of an OLDER edit can never clobber
--     a newer one already stored (lost-update / divergence prevented), and
--   * two edits that race at the same version are resolved by
--     server-received order (first writer wins; the equal-version loser is
--     a no-op) — a deterministic tie-break.
-- A new edit also clears `acked_at`/`delete_after` so the recipient
-- re-pulls and re-applies the fresher version.
CREATE TABLE IF NOT EXISTS pending_deliveries (
  recipient_id TEXT    NOT NULL,            -- raw user id (inbox routing key)
  tx_sync_id   TEXT    NOT NULL,            -- transaction sync id
  version      INTEGER NOT NULL,            -- monotonic edit counter; higher wins
  op           TEXT    NOT NULL,            -- 'upsert' | 'delete' (tombstone)
  payload      TEXT    NOT NULL,            -- base64 AES-GCM ciphertext (opaque); '' for delete
  checksum     TEXT,                        -- content checksum for client-side dedup; null for delete
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  expires_at   INTEGER NOT NULL,            -- hard TTL (14 days) — backstop for never-opening recipients
  acked_at     INTEGER,                     -- set when the recipient confirms local apply
  delete_after INTEGER,                     -- set to next-UTC-day after ack; cron sweeps past this
  PRIMARY KEY (recipient_id, tx_sync_id)
);

-- Inbox pull: un-acked rows for one recipient. Composite so the pull is an
-- index range-scan, not a table scan.
CREATE INDEX IF NOT EXISTS idx_pending_inbox ON pending_deliveries(recipient_id, acked_at);

-- Cron sweep drivers: hard-TTL expiry and post-ack cleanup.
CREATE INDEX IF NOT EXISTS idx_pending_expires ON pending_deliveries(expires_at);
CREATE INDEX IF NOT EXISTS idx_pending_delete_after ON pending_deliveries(delete_after);
