ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_edit_state_valid;
ALTER TABLE messages DROP COLUMN IF EXISTS edit_version;
ALTER TABLE messages DROP COLUMN IF EXISTS edited_at;
