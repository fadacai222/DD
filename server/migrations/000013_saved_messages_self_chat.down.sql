DELETE FROM conversations WHERE type='SELF';

DROP INDEX IF EXISTS saved_messages_migrated_message_uidx;
ALTER TABLE saved_messages DROP COLUMN IF EXISTS migrated_message_id;

ALTER TABLE conversations DROP CONSTRAINT conversations_direct_pair_consistent;
ALTER TABLE conversations DROP CONSTRAINT conversations_type_valid;

ALTER TABLE conversations
    ADD CONSTRAINT conversations_type_valid
    CHECK (type IN ('DIRECT', 'GROUP'));

ALTER TABLE conversations
    ADD CONSTRAINT conversations_direct_pair_consistent
    CHECK ((type = 'DIRECT') = (direct_pair_key IS NOT NULL));
