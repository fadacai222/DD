ALTER TABLE outbox_events DROP CONSTRAINT IF EXISTS outbox_aggregate_type_valid;
ALTER TABLE outbox_events
    ADD CONSTRAINT outbox_aggregate_type_valid
    CHECK (aggregate_type IN ('MESSAGE', 'CONVERSATION', 'RELATIONSHIP', 'GROUP', 'MOMENT'));

ALTER TABLE media_objects DROP CONSTRAINT IF EXISTS media_objects_purpose_valid;
ALTER TABLE media_objects
    ADD CONSTRAINT media_objects_purpose_valid
    CHECK (purpose IN (
        'CHAT_IMAGE','CHAT_FILE','CHAT_VOICE','CHAT_VIDEO','STICKER','GIF',
        'MOMENT_IMAGE','MOMENT_VIDEO'
    ));

CREATE TABLE moments (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    author_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    text varchar(2000) NOT NULL DEFAULT '',
    visibility varchar(24) NOT NULL DEFAULT 'ALL_CONTACTS',
    status varchar(16) NOT NULL DEFAULT 'ACTIVE',
    created_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CONSTRAINT moments_visibility_valid CHECK (visibility IN ('ALL_CONTACTS','PRIVATE','EXCLUDE')),
    CONSTRAINT moments_status_valid CHECK (status IN ('ACTIVE','DELETED')),
    CONSTRAINT moments_deleted_state_consistent CHECK (
        (status='ACTIVE' AND deleted_at IS NULL) OR
        (status='DELETED' AND deleted_at IS NOT NULL)
    )
);
CREATE INDEX moments_author_time_idx ON moments(author_user_id, created_at DESC, id DESC) WHERE status='ACTIVE';
CREATE INDEX moments_feed_time_idx ON moments(created_at DESC, id DESC) WHERE status='ACTIVE';

CREATE TABLE moment_media (
    moment_id uuid NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
    media_id uuid NOT NULL REFERENCES media_objects(id) ON DELETE RESTRICT,
    sort_order smallint NOT NULL,
    PRIMARY KEY(moment_id, media_id),
    UNIQUE(moment_id, sort_order),
    CONSTRAINT moment_media_order_valid CHECK (sort_order BETWEEN 0 AND 8)
);
CREATE INDEX moment_media_media_idx ON moment_media(media_id, moment_id);

CREATE TABLE moment_visibility_users (
    moment_id uuid NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    mode varchar(16) NOT NULL,
    PRIMARY KEY(moment_id, user_id),
    CONSTRAINT moment_visibility_users_mode_valid CHECK (mode IN ('INCLUDED','EXCLUDED'))
);

CREATE TABLE moment_likes (
    moment_id uuid NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(moment_id, user_id)
);
CREATE INDEX moment_likes_time_idx ON moment_likes(moment_id, created_at, user_id);

CREATE TABLE moment_comments (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    moment_id uuid NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
    author_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reply_to_comment_id uuid REFERENCES moment_comments(id) ON DELETE SET NULL,
    text varchar(1000) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CONSTRAINT moment_comments_text_nonempty CHECK (char_length(btrim(text)) BETWEEN 1 AND 1000)
);
CREATE INDEX moment_comments_moment_time_idx ON moment_comments(moment_id, created_at, id) WHERE deleted_at IS NULL;

CREATE TABLE moment_relationship_preferences (
    owner_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    target_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    hide_target boolean NOT NULL DEFAULT false,
    hide_from_target boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(owner_user_id, target_user_id),
    CONSTRAINT moment_relationship_preferences_not_self CHECK (owner_user_id <> target_user_id),
    CONSTRAINT moment_relationship_preferences_nonempty CHECK (hide_target OR hide_from_target)
);
