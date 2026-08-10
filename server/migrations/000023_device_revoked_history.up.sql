ALTER TABLE devices
    ADD COLUMN IF NOT EXISTS revoked_history_cleared_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_devices_user_visible_history
    ON devices(user_id, last_seen_at DESC)
    WHERE revoked_history_cleared_at IS NULL;
