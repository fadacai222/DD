DROP TABLE IF EXISTS message_local_deletions;
DROP TABLE IF EXISTS sync_events;
DROP TABLE IF EXISTS outbox_events;
ALTER TABLE conversations DROP CONSTRAINT IF EXISTS conversations_last_message_fk;
DROP TABLE IF EXISTS messages;
