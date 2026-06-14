-- Server-mediated split-transaction sync — Phase 3: APNs push tokens.
--
-- Why this exists
-- ----------------
-- P1 delivers transactions to a recipient's inbox; the recipient applies
-- them on next foreground (pull). This table lets the Worker ALSO send an
-- APNs push the moment a delivery is uploaded, so the recipient gets an
-- immediate "new shared expense" nudge instead of waiting until they next
-- open the app. The push is only a nudge — the actual (encrypted) data is
-- still pulled from /v1/sync/inbox; the push carries no financial content.
--
-- Privacy / size
-- --------------
-- `user_id` is the raw routing key (same justification as
-- pending_deliveries.recipient_id — needed to address the device). One row
-- per (user, device token); tokens rotate rarely so writes are negligible.
-- `env` records which APNs environment the token is for ('production' for
-- TestFlight/App Store builds, 'sandbox' for Xcode development builds) so
-- the Worker hits the matching APNs host.
CREATE TABLE IF NOT EXISTS device_tokens (
  user_id    TEXT    NOT NULL,            -- raw user id (push routing key)
  token      TEXT    NOT NULL,            -- APNs device token (hex)
  env        TEXT    NOT NULL,            -- 'production' | 'sandbox'
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, token)
);

CREATE INDEX IF NOT EXISTS idx_device_tokens_user ON device_tokens(user_id);
