CREATE TABLE group_call_sessions (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    conversation_id uuid NOT NULL REFERENCES groups(conversation_id) ON DELETE CASCADE,
    kind varchar(16) NOT NULL,
    status varchar(16) NOT NULL DEFAULT 'ACTIVE',
    room_name varchar(160) NOT NULL UNIQUE,
    started_by_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    started_by_device_id uuid NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    max_participants integer NOT NULL DEFAULT 32,
    started_at timestamptz NOT NULL DEFAULT now(),
    ended_at timestamptz,
    CONSTRAINT group_call_kind_valid CHECK (kind IN ('AUDIO', 'VIDEO')),
    CONSTRAINT group_call_status_valid CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT group_call_participant_limit_valid CHECK (max_participants BETWEEN 2 AND 500),
    CONSTRAINT group_call_end_state_valid CHECK (
        (status='ACTIVE' AND ended_at IS NULL) OR
        (status='ENDED' AND ended_at IS NOT NULL)
    )
);
CREATE UNIQUE INDEX group_call_one_active_per_group_idx
    ON group_call_sessions(conversation_id)
    WHERE status='ACTIVE';
CREATE INDEX group_call_sessions_started_idx
    ON group_call_sessions(conversation_id, started_at DESC);

CREATE TABLE group_call_participants (
    session_id uuid NOT NULL REFERENCES group_call_sessions(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    joined_at timestamptz NOT NULL DEFAULT now(),
    left_at timestamptz,
    PRIMARY KEY (session_id, user_id),
    CONSTRAINT group_call_participant_time_valid CHECK (
        left_at IS NULL OR left_at >= joined_at
    )
);
CREATE INDEX group_call_active_participants_idx
    ON group_call_participants(session_id, joined_at)
    WHERE left_at IS NULL;
