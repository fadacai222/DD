CREATE TABLE calls (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    caller_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    callee_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    caller_device_id uuid NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    answered_device_id uuid REFERENCES devices(id) ON DELETE RESTRICT,
    room_name varchar(96) NOT NULL UNIQUE,
    kind varchar(16) NOT NULL,
    status varchar(16) NOT NULL DEFAULT 'ringing',
    created_at timestamptz NOT NULL DEFAULT now(),
    ring_expires_at timestamptz NOT NULL,
    accepted_at timestamptz,
    ended_at timestamptz,
    end_reason varchar(32),
    version integer NOT NULL DEFAULT 0,
    CONSTRAINT calls_users_distinct CHECK (caller_user_id <> callee_user_id),
    CONSTRAINT calls_kind_valid CHECK (kind IN ('audio', 'video')),
    CONSTRAINT calls_status_valid CHECK (status IN ('ringing', 'accepted', 'rejected', 'ended')),
    CONSTRAINT calls_expiry_after_create CHECK (ring_expires_at > created_at),
    CONSTRAINT calls_version_nonnegative CHECK (version >= 0),
    CONSTRAINT calls_state_consistent CHECK (
        (status = 'ringing' AND accepted_at IS NULL AND ended_at IS NULL AND end_reason IS NULL AND answered_device_id IS NULL)
        OR
        (status = 'accepted' AND accepted_at IS NOT NULL AND ended_at IS NULL AND end_reason IS NULL AND answered_device_id IS NOT NULL)
        OR
        (status = 'rejected' AND accepted_at IS NULL AND ended_at IS NOT NULL AND end_reason = 'rejected' AND answered_device_id IS NULL)
        OR
        (status = 'ended' AND ended_at IS NOT NULL AND end_reason IS NOT NULL)
    )
);

CREATE INDEX calls_caller_active_idx
    ON calls(caller_user_id, status, created_at DESC)
    WHERE status IN ('ringing', 'accepted');
CREATE INDEX calls_callee_active_idx
    ON calls(callee_user_id, status, created_at DESC)
    WHERE status IN ('ringing', 'accepted');
CREATE INDEX calls_ring_timeout_idx
    ON calls(ring_expires_at, id)
    WHERE status = 'ringing';
CREATE INDEX calls_history_pair_idx
    ON calls(LEAST(caller_user_id, callee_user_id), GREATEST(caller_user_id, callee_user_id), created_at DESC);
