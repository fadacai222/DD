CREATE TABLE moment_activity_notifications (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    recipient_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    moment_id uuid NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
    actor_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind varchar(16) NOT NULL,
    source_comment_id uuid REFERENCES moment_comments(id) ON DELETE CASCADE,
    dedupe_key varchar(180) NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    read_at timestamptz,
    CONSTRAINT moment_activity_kind_valid CHECK (kind IN ('LIKE','COMMENT')),
    CONSTRAINT moment_activity_not_self CHECK (recipient_user_id <> actor_user_id),
    CONSTRAINT moment_activity_comment_source_consistent CHECK (
        (kind='LIKE' AND source_comment_id IS NULL) OR
        (kind='COMMENT' AND source_comment_id IS NOT NULL)
    )
);

CREATE INDEX moment_activity_unread_recipient_idx
    ON moment_activity_notifications(recipient_user_id, created_at DESC, id DESC)
    WHERE read_at IS NULL;

CREATE INDEX moment_activity_moment_idx
    ON moment_activity_notifications(moment_id, created_at DESC, id DESC);

CREATE INDEX moment_activity_comment_idx
    ON moment_activity_notifications(source_comment_id)
    WHERE source_comment_id IS NOT NULL;
