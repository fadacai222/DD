CREATE TABLE qr_login_sessions (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    nonce_hash bytea NOT NULL UNIQUE,
    target_origin text NOT NULL,
    requested_device_name varchar(120) NOT NULL,
    requested_platform varchar(32) NOT NULL,
    requested_app_version varchar(40) NOT NULL DEFAULT '',
    status varchar(16) NOT NULL DEFAULT 'PENDING',
    scanned_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    scanned_device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    scanned_at timestamptz,
    confirmed_at timestamptz,
    consumed_at timestamptz,
    CONSTRAINT qr_login_nonce_hash_length CHECK (octet_length(nonce_hash)=32),
    CONSTRAINT qr_login_status_valid CHECK (status IN ('PENDING','SCANNED','CONFIRMED','REJECTED','CONSUMED','EXPIRED')),
    CONSTRAINT qr_login_expiry_after_create CHECK (expires_at > created_at),
    CONSTRAINT qr_login_state_consistent CHECK (
        (status='PENDING' AND scanned_user_id IS NULL AND scanned_device_id IS NULL AND scanned_at IS NULL AND confirmed_at IS NULL AND consumed_at IS NULL)
        OR
        (status='SCANNED' AND scanned_user_id IS NOT NULL AND scanned_device_id IS NOT NULL AND scanned_at IS NOT NULL AND confirmed_at IS NULL AND consumed_at IS NULL)
        OR
        (status IN ('CONFIRMED','REJECTED') AND scanned_user_id IS NOT NULL AND scanned_device_id IS NOT NULL AND scanned_at IS NOT NULL AND confirmed_at IS NOT NULL AND consumed_at IS NULL)
        OR
        (status='CONSUMED' AND scanned_user_id IS NOT NULL AND scanned_device_id IS NOT NULL AND scanned_at IS NOT NULL AND confirmed_at IS NOT NULL AND consumed_at IS NOT NULL)
        OR status='EXPIRED'
    )
);
CREATE INDEX qr_login_expiry_idx ON qr_login_sessions(expires_at,id) WHERE status IN ('PENDING','SCANNED','CONFIRMED');

CREATE TABLE group_qr_invites (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    group_id uuid NOT NULL REFERENCES groups(conversation_id) ON DELETE CASCADE,
    created_by_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    nonce_hash bytea NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    use_count integer NOT NULL DEFAULT 0,
    max_uses integer,
    CONSTRAINT group_qr_nonce_hash_length CHECK (octet_length(nonce_hash)=32),
    CONSTRAINT group_qr_expiry_after_create CHECK (expires_at > created_at),
    CONSTRAINT group_qr_use_count_nonnegative CHECK (use_count >= 0),
    CONSTRAINT group_qr_max_uses_positive CHECK (max_uses IS NULL OR max_uses > 0)
);
CREATE INDEX group_qr_group_time_idx ON group_qr_invites(group_id,created_at DESC);
CREATE INDEX group_qr_expiry_idx ON group_qr_invites(expires_at,id) WHERE revoked_at IS NULL;
