ALTER TABLE conversations DROP CONSTRAINT conversations_type_valid;
ALTER TABLE conversations DROP CONSTRAINT conversations_direct_pair_consistent;

ALTER TABLE conversations
    ADD CONSTRAINT conversations_type_valid
    CHECK (type IN ('DIRECT', 'GROUP', 'SELF'));

ALTER TABLE conversations
    ADD CONSTRAINT conversations_direct_pair_consistent
    CHECK (
        (type = 'GROUP' AND direct_pair_key IS NULL)
        OR
        (type IN ('DIRECT', 'SELF') AND direct_pair_key IS NOT NULL)
    );

ALTER TABLE saved_messages
    ADD COLUMN migrated_message_id uuid REFERENCES messages(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX saved_messages_migrated_message_uidx
    ON saved_messages(migrated_message_id)
    WHERE migrated_message_id IS NOT NULL;
