ALTER TABLE media_objects DROP CONSTRAINT media_objects_purpose_valid;
ALTER TABLE media_objects
    ADD CONSTRAINT media_objects_purpose_valid
    CHECK (purpose IN ('CHAT_IMAGE','CHAT_FILE','CHAT_VOICE','STICKER','GIF'));

ALTER TABLE messages DROP CONSTRAINT messages_type_valid;
ALTER TABLE messages
    ADD CONSTRAINT messages_type_valid
    CHECK (type IN ('TEXT','IMAGE','GIF','STICKER','FILE','VOICE','SYSTEM','ENCRYPTED'));
