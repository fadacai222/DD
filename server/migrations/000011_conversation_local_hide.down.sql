DROP INDEX IF EXISTS conversation_members_user_visible_idx;
ALTER TABLE conversation_members DROP COLUMN IF EXISTS hidden_through_sequence;
