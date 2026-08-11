ALTER TABLE messages DROP CONSTRAINT messages_type_valid;
ALTER TABLE messages
    ADD CONSTRAINT messages_type_valid
    CHECK (type IN ('TEXT','IMAGE','GIF','STICKER','STICKER_PACK','FILE','VOICE','VIDEO','SYSTEM','ENCRYPTED'));
