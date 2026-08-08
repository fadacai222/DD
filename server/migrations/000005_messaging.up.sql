CREATE TABLE messages (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    sequence bigint NOT NULL,
    sender_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    sender_device_id uuid NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    client_message_id varchar(80) NOT NULL,
    type varchar(24) NOT NULL,
    content_json jsonb,
    ciphertext_json jsonb,
    reply_to_message_id uuid REFERENCES messages(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    recalled_at timestamptz,
    deleted_at timestamptz,
    CONSTRAINT messages_sequence_positive CHECK (sequence > 0),
    CONSTRAINT messages_client_id_nonempty CHECK (char_length(btrim(client_message_id)) BETWEEN 8 AND 80),
    CONSTRAINT messages_type_valid CHECK (type IN ('TEXT', 'SYSTEM', 'ENCRYPTED')),
    CONSTRAINT messages_content_mode_valid CHECK (
        (type = 'ENCRYPTED' AND ciphertext_json IS NOT NULL AND content_json IS NULL)
        OR
        (type <> 'ENCRYPTED' AND content_json IS NOT NULL AND ciphertext_json IS NULL)
    ),
    CONSTRAINT messages_recall_delete_consistent CHECK (recalled_at IS NULL OR deleted_at IS NULL)
);
CREATE UNIQUE INDEX messages_conversation_sequence_uidx ON messages(conversation_id, sequence);
CREATE UNIQUE INDEX messages_sender_device_client_uidx ON messages(sender_device_id, client_message_id);
CREATE INDEX messages_conversation_history_idx ON messages(conversation_id, sequence DESC) WHERE deleted_at IS NULL;
CREATE INDEX messages_sender_idx ON messages(sender_user_id, created_at DESC);

ALTER TABLE conversations
    ADD CONSTRAINT conversations_last_message_fk
    FOREIGN KEY (last_message_id) REFERENCES messages(id) ON DELETE SET NULL;

CREATE TABLE outbox_events (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    aggregate_type varchar(32) NOT NULL,
    aggregate_id uuid NOT NULL,
    event_type varchar(64) NOT NULL,
    conversation_id uuid REFERENCES conversations(id) ON DELETE CASCADE,
    sequence bigint,
    target_user_id uuid REFERENCES users(id) ON DELETE CASCADE,
    payload_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    available_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    attempts integer NOT NULL DEFAULT 0,
    last_error text,
    CONSTRAINT outbox_attempts_nonnegative CHECK (attempts >= 0),
    CONSTRAINT outbox_sequence_positive CHECK (sequence IS NULL OR sequence > 0),
    CONSTRAINT outbox_aggregate_type_valid CHECK (aggregate_type IN ('MESSAGE', 'CONVERSATION'))
);
CREATE INDEX outbox_pending_idx ON outbox_events(available_at, created_at, id) WHERE published_at IS NULL;
CREATE INDEX outbox_aggregate_idx ON outbox_events(aggregate_type, aggregate_id, created_at DESC);
CREATE INDEX outbox_conversation_idx ON outbox_events(conversation_id, created_at DESC) WHERE conversation_id IS NOT NULL;
CREATE INDEX outbox_target_user_idx ON outbox_events(target_user_id, created_at DESC) WHERE target_user_id IS NOT NULL;

CREATE TABLE sync_events (
    cursor bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id uuid NOT NULL DEFAULT uuidv7() UNIQUE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    source_outbox_id uuid NOT NULL REFERENCES outbox_events(id) ON DELETE CASCADE,
    event_type varchar(64) NOT NULL,
    resource_id uuid,
    conversation_id uuid REFERENCES conversations(id) ON DELETE CASCADE,
    sequence bigint,
    payload_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT sync_sequence_positive CHECK (sequence IS NULL OR sequence > 0),
    UNIQUE (source_outbox_id, user_id)
);
CREATE INDEX sync_events_user_cursor_idx ON sync_events(user_id, cursor);
CREATE INDEX sync_events_conversation_idx ON sync_events(user_id, conversation_id, sequence) WHERE conversation_id IS NOT NULL;

CREATE TABLE message_local_deletions (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    deleted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, message_id)
);
