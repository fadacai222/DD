CREATE TABLE users (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    email_normalized varchar(254) NOT NULL UNIQUE,
    email_verified_at timestamptz NOT NULL,
    handle_normalized varchar(32) NOT NULL UNIQUE,
    display_name varchar(80) NOT NULL,
    avatar_media_id uuid,
    bio varchar(500) NOT NULL DEFAULT '',
    status varchar(24) NOT NULL DEFAULT 'ACTIVE',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CONSTRAINT users_email_nonempty CHECK (char_length(email_normalized) BETWEEN 3 AND 254),
    CONSTRAINT users_handle_format CHECK (handle_normalized ~ '^[a-z][a-z0-9_]{2,31}$'),
    CONSTRAINT users_display_name_nonempty CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 80),
    CONSTRAINT users_status_valid CHECK (status IN ('ACTIVE', 'SUSPENDED', 'DELETING', 'DELETED')),
    CONSTRAINT users_deleted_state_consistent CHECK ((status = 'DELETED') = (deleted_at IS NOT NULL))
);

CREATE TABLE user_privacy_settings (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    allow_email_search boolean NOT NULL DEFAULT false,
    allow_stranger_messages boolean NOT NULL DEFAULT false,
    show_online_status boolean NOT NULL DEFAULT true,
    read_receipts_enabled boolean NOT NULL DEFAULT true,
    notification_preview_enabled boolean NOT NULL DEFAULT true,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE auth_passwords (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    password_hash text NOT NULL,
    password_changed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT auth_passwords_hash_length CHECK (char_length(password_hash) BETWEEN 40 AND 512)
);

CREATE TABLE devices (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name varchar(120) NOT NULL,
    platform varchar(24) NOT NULL,
    app_version varchar(40) NOT NULL DEFAULT '',
    identity_public_key bytea,
    identity_key_algorithm varchar(40),
    identity_key_version integer,
    is_verified boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    CONSTRAINT devices_name_nonempty CHECK (char_length(btrim(name)) BETWEEN 1 AND 120),
    CONSTRAINT devices_platform_valid CHECK (platform IN ('ANDROID', 'IOS', 'WINDOWS', 'MACOS', 'LINUX', 'WEB')),
    CONSTRAINT devices_identity_key_complete CHECK (
        (identity_public_key IS NULL AND identity_key_algorithm IS NULL AND identity_key_version IS NULL)
        OR
        (identity_public_key IS NOT NULL AND identity_key_algorithm IS NOT NULL AND identity_key_version IS NOT NULL AND identity_key_version > 0)
    )
);
CREATE INDEX devices_user_active_idx ON devices(user_id, last_seen_at DESC) WHERE revoked_at IS NULL;

CREATE TABLE refresh_tokens (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    family_id uuid NOT NULL,
    parent_token_id uuid REFERENCES refresh_tokens(id) ON DELETE SET NULL,
    token_hash bytea NOT NULL UNIQUE,
    issued_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    used_at timestamptz,
    revoked_at timestamptz,
    revoke_reason varchar(64),
    CONSTRAINT refresh_tokens_hash_length CHECK (octet_length(token_hash) = 32),
    CONSTRAINT refresh_tokens_expiry_after_issue CHECK (expires_at > issued_at),
    CONSTRAINT refresh_tokens_revocation_reason_consistent CHECK (
        (revoked_at IS NULL AND revoke_reason IS NULL) OR
        (revoked_at IS NOT NULL AND revoke_reason IS NOT NULL)
    )
);
CREATE INDEX refresh_tokens_user_active_idx ON refresh_tokens(user_id, expires_at DESC) WHERE revoked_at IS NULL;
CREATE INDEX refresh_tokens_device_active_idx ON refresh_tokens(device_id, expires_at DESC) WHERE revoked_at IS NULL;
CREATE INDEX refresh_tokens_family_idx ON refresh_tokens(family_id, issued_at);

CREATE TABLE email_codes (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    purpose varchar(32) NOT NULL,
    email_normalized varchar(254) NOT NULL,
    code_hash bytea NOT NULL,
    attempts integer NOT NULL DEFAULT 0,
    max_attempts integer NOT NULL DEFAULT 5,
    created_at timestamptz NOT NULL DEFAULT now(),
    sent_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    request_ip_hash bytea,
    device_fingerprint_hash bytea,
    CONSTRAINT email_codes_purpose_valid CHECK (purpose IN ('REGISTER', 'PASSWORD_RESET', 'CHANGE_EMAIL')),
    CONSTRAINT email_codes_hash_length CHECK (octet_length(code_hash) = 32),
    CONSTRAINT email_codes_attempts_valid CHECK (attempts >= 0 AND max_attempts BETWEEN 1 AND 20 AND attempts <= max_attempts),
    CONSTRAINT email_codes_expiry_after_create CHECK (expires_at > created_at)
);
CREATE INDEX email_codes_lookup_idx ON email_codes(email_normalized, purpose, created_at DESC);
CREATE INDEX email_codes_active_expiry_idx ON email_codes(expires_at) WHERE consumed_at IS NULL;
