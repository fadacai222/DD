ALTER TABLE messages DROP CONSTRAINT messages_type_valid;
ALTER TABLE messages
    ADD CONSTRAINT messages_type_valid CHECK (type IN ('TEXT', 'IMAGE', 'SYSTEM', 'ENCRYPTED'));

CREATE TABLE message_media (
    message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    media_id uuid NOT NULL REFERENCES media_objects(id) ON DELETE RESTRICT,
    role varchar(24) NOT NULL DEFAULT 'PRIMARY',
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (message_id, media_id),
    CONSTRAINT message_media_role_valid CHECK (role IN ('PRIMARY','THUMBNAIL'))
);

CREATE INDEX message_media_media_idx ON message_media(media_id, message_id);
