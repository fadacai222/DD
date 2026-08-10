DROP TABLE IF EXISTS moment_relationship_preferences;
DROP INDEX IF EXISTS moment_comments_moment_time_idx;
DROP TABLE IF EXISTS moment_comments;
DROP INDEX IF EXISTS moment_likes_time_idx;
DROP TABLE IF EXISTS moment_likes;
DROP TABLE IF EXISTS moment_visibility_users;
DROP INDEX IF EXISTS moment_media_media_idx;
DROP TABLE IF EXISTS moment_media;
DROP INDEX IF EXISTS moments_feed_time_idx;
DROP INDEX IF EXISTS moments_author_time_idx;
DROP TABLE IF EXISTS moments;

ALTER TABLE media_objects DROP CONSTRAINT IF EXISTS media_objects_purpose_valid;
ALTER TABLE media_objects
    ADD CONSTRAINT media_objects_purpose_valid
    CHECK (purpose IN ('CHAT_IMAGE','CHAT_FILE','CHAT_VOICE','CHAT_VIDEO','STICKER','GIF'));

ALTER TABLE outbox_events DROP CONSTRAINT IF EXISTS outbox_aggregate_type_valid;
ALTER TABLE outbox_events
    ADD CONSTRAINT outbox_aggregate_type_valid
    CHECK (aggregate_type IN ('MESSAGE', 'CONVERSATION', 'RELATIONSHIP', 'GROUP'));
