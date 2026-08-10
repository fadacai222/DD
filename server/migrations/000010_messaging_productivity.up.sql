ALTER TABLE conversation_members
    ADD COLUMN archived_at timestamptz;

ALTER TABLE messages
    ADD COLUMN forwarded_from_message_id uuid REFERENCES messages(id) ON DELETE SET NULL;
CREATE INDEX messages_forward_source_idx
    ON messages(forwarded_from_message_id) WHERE forwarded_from_message_id IS NOT NULL;

CREATE INDEX conversation_members_user_archive_idx
    ON conversation_members(user_id, status, archived_at, is_pinned DESC, joined_at DESC);

CREATE TABLE saved_messages (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    saved_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, message_id)
);
CREATE INDEX saved_messages_user_time_idx ON saved_messages(user_id, saved_at DESC, message_id DESC);

CREATE TABLE conversation_pinned_messages (
    conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    pinned_by_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    pinned_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (conversation_id, message_id)
);
CREATE INDEX conversation_pinned_messages_time_idx
    ON conversation_pinned_messages(conversation_id, pinned_at DESC, message_id DESC);
