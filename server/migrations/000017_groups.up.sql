ALTER TABLE outbox_events DROP CONSTRAINT IF EXISTS outbox_aggregate_type_valid;
ALTER TABLE outbox_events
    ADD CONSTRAINT outbox_aggregate_type_valid
    CHECK (aggregate_type IN ('MESSAGE', 'CONVERSATION', 'RELATIONSHIP', 'GROUP'));

CREATE TABLE groups (
    conversation_id uuid PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
    name varchar(80) NOT NULL,
    announcement varchar(1000) NOT NULL DEFAULT '',
    join_mode varchar(24) NOT NULL DEFAULT 'INVITE_ONLY',
    created_by_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    status varchar(16) NOT NULL DEFAULT 'ACTIVE',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    dissolved_at timestamptz,
    CONSTRAINT groups_name_nonempty CHECK (char_length(btrim(name)) BETWEEN 1 AND 80),
    CONSTRAINT groups_join_mode_valid CHECK (join_mode IN ('INVITE_ONLY', 'APPROVAL')),
    CONSTRAINT groups_status_valid CHECK (status IN ('ACTIVE', 'DISSOLVED')),
    CONSTRAINT groups_dissolved_state_consistent CHECK (
        (status = 'ACTIVE' AND dissolved_at IS NULL)
        OR
        (status = 'DISSOLVED' AND dissolved_at IS NOT NULL)
    )
);
CREATE INDEX groups_active_updated_idx ON groups(status, updated_at DESC, conversation_id);

CREATE TABLE group_member_profiles (
    conversation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    nickname varchar(80) NOT NULL DEFAULT '',
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (conversation_id, user_id),
    FOREIGN KEY (conversation_id, user_id)
        REFERENCES conversation_members(conversation_id, user_id)
        ON DELETE CASCADE,
    CONSTRAINT group_member_profiles_nickname_length CHECK (char_length(nickname) <= 80)
);

CREATE TABLE group_join_requests (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    conversation_id uuid NOT NULL REFERENCES groups(conversation_id) ON DELETE CASCADE,
    requester_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    message varchar(200) NOT NULL DEFAULT '',
    status varchar(16) NOT NULL DEFAULT 'PENDING',
    created_at timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz,
    resolved_by_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT group_join_requests_status_valid CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED')),
    CONSTRAINT group_join_requests_resolution_consistent CHECK (
        (status = 'PENDING' AND resolved_at IS NULL AND resolved_by_user_id IS NULL)
        OR
        (status <> 'PENDING' AND resolved_at IS NOT NULL)
    )
);
CREATE UNIQUE INDEX group_join_requests_pending_user_idx
    ON group_join_requests(conversation_id, requester_user_id)
    WHERE status = 'PENDING';
CREATE INDEX group_join_requests_group_status_time_idx
    ON group_join_requests(conversation_id, status, created_at DESC, id DESC);
