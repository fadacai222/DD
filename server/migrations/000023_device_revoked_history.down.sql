DROP INDEX IF EXISTS idx_devices_user_visible_history;

ALTER TABLE devices
    DROP COLUMN IF EXISTS revoked_history_cleared_at;
