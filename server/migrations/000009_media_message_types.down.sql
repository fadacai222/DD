ALTER TABLE messages DROP CONSTRAINT messages_type_valid;
ALTER TABLE messages
    ADD CONSTRAINT messages_type_valid
    CHECK (type IN ('TEXT', 'IMAGE', 'SYSTEM', 'ENCRYPTED'));
