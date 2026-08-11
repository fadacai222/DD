DROP INDEX IF EXISTS users_moment_cover_media_idx;
ALTER TABLE users
    DROP COLUMN IF EXISTS moment_cover_revision,
    DROP COLUMN IF EXISTS moment_cover_media_id;

DROP INDEX IF EXISTS groups_avatar_media_idx;
ALTER TABLE groups
    DROP COLUMN IF EXISTS avatar_revision,
    DROP COLUMN IF EXISTS avatar_media_id;

ALTER TABLE media_objects DROP CONSTRAINT IF EXISTS media_objects_purpose_valid;
ALTER TABLE media_objects
    ADD CONSTRAINT media_objects_purpose_valid
    CHECK (purpose IN (
        'CHAT_IMAGE','CHAT_FILE','CHAT_VOICE','CHAT_VIDEO','STICKER','GIF',
        'MOMENT_IMAGE','MOMENT_VIDEO'
    ));
