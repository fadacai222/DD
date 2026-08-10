DROP INDEX IF EXISTS calls_conversation_time_idx;
ALTER TABLE calls DROP COLUMN IF EXISTS conversation_id;
