ALTER TABLE media_objects DROP CONSTRAINT IF EXISTS media_objects_purpose_valid;
ALTER TABLE media_objects
    ADD CONSTRAINT media_objects_purpose_valid
    CHECK (purpose IN (
        'CHAT_IMAGE','CHAT_FILE','CHAT_VOICE','CHAT_VIDEO','STICKER','GIF',
        'MOMENT_IMAGE','MOMENT_VIDEO','GROUP_AVATAR','MOMENT_COVER'
    ));

ALTER TABLE groups
    ADD COLUMN avatar_media_id uuid REFERENCES media_objects(id) ON DELETE SET NULL,
    ADD COLUMN avatar_revision bigint NOT NULL DEFAULT 0;
CREATE INDEX groups_avatar_media_idx ON groups(avatar_media_id) WHERE avatar_media_id IS NOT NULL;

ALTER TABLE users
    ADD COLUMN moment_cover_media_id uuid REFERENCES media_objects(id) ON DELETE SET NULL,
    ADD COLUMN moment_cover_revision bigint NOT NULL DEFAULT 0;
CREATE INDEX users_moment_cover_media_idx ON users(moment_cover_media_id) WHERE moment_cover_media_id IS NOT NULL;
