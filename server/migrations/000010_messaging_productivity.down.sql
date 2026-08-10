DROP TABLE IF EXISTS conversation_pinned_messages;
DROP TABLE IF EXISTS saved_messages;
DROP INDEX IF EXISTS conversation_members_user_archive_idx;
ALTER TABLE conversation_members DROP COLUMN IF EXISTS archived_at;
DROP INDEX IF EXISTS messages_forward_source_idx;
ALTER TABLE messages DROP COLUMN IF EXISTS forwarded_from_message_id;
