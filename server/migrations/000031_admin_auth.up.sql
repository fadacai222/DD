CREATE TABLE admin_accounts (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    email_normalized varchar(254) NOT NULL UNIQUE,
    password_hash text NOT NULL,
    role varchar(32) NOT NULL,
    status varchar(16) NOT NULL DEFAULT 'ACTIVE',
    totp_secret_ciphertext bytea,
    totp_enabled_at timestamptz,
    totp_last_counter bigint,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    last_login_at timestamptz,
    CONSTRAINT admin_accounts_email_nonempty CHECK (char_length(email_normalized) BETWEEN 3 AND 254),
    CONSTRAINT admin_accounts_password_hash_length CHECK (char_length(password_hash) BETWEEN 40 AND 512),
    CONSTRAINT admin_accounts_role_valid CHECK (role IN ('SUPER_ADMIN', 'MODERATOR', 'SUPPORT_READ_ONLY')),
    CONSTRAINT admin_accounts_status_valid CHECK (status IN ('ACTIVE', 'DISABLED')),
    CONSTRAINT admin_accounts_totp_consistent CHECK (
        (totp_secret_ciphertext IS NULL AND totp_enabled_at IS NULL AND totp_last_counter IS NULL) OR
        (totp_secret_ciphertext IS NOT NULL AND totp_enabled_at IS NOT NULL)
    )
);

CREATE TABLE admin_sessions (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    admin_id uuid NOT NULL REFERENCES admin_accounts(id) ON DELETE CASCADE,
    token_hash bytea NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    idle_expires_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    revoke_reason varchar(64),
    client_ip inet,
    user_agent varchar(500) NOT NULL DEFAULT '',
    CONSTRAINT admin_sessions_token_hash_length CHECK (octet_length(token_hash) = 32),
    CONSTRAINT admin_sessions_expiry_valid CHECK (expires_at > created_at AND idle_expires_at > created_at AND idle_expires_at <= expires_at),
    CONSTRAINT admin_sessions_revocation_consistent CHECK (
        (revoked_at IS NULL AND revoke_reason IS NULL) OR
        (revoked_at IS NOT NULL AND revoke_reason IS NOT NULL)
    )
);
CREATE INDEX admin_sessions_admin_active_idx ON admin_sessions(admin_id, expires_at DESC) WHERE revoked_at IS NULL;

CREATE TABLE admin_auth_challenges (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    admin_id uuid NOT NULL REFERENCES admin_accounts(id) ON DELETE CASCADE,
    token_hash bytea NOT NULL UNIQUE,
    purpose varchar(24) NOT NULL,
    pending_totp_secret bytea,
    attempts integer NOT NULL DEFAULT 0,
    max_attempts integer NOT NULL DEFAULT 5,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    client_ip inet,
    user_agent varchar(500) NOT NULL DEFAULT '',
    CONSTRAINT admin_auth_challenges_token_hash_length CHECK (octet_length(token_hash) = 32),
    CONSTRAINT admin_auth_challenges_purpose_valid CHECK (purpose IN ('MFA_ENROLL', 'MFA_VERIFY')),
    CONSTRAINT admin_auth_challenges_attempts_valid CHECK (attempts >= 0 AND max_attempts BETWEEN 1 AND 10 AND attempts <= max_attempts),
    CONSTRAINT admin_auth_challenges_expiry_valid CHECK (expires_at > created_at),
    CONSTRAINT admin_auth_challenges_pending_secret_consistent CHECK (
        purpose = 'MFA_ENROLL' OR pending_totp_secret IS NULL
    )
);
CREATE INDEX admin_auth_challenges_admin_active_idx ON admin_auth_challenges(admin_id, expires_at DESC) WHERE consumed_at IS NULL;

CREATE TABLE admin_recovery_codes (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    admin_id uuid NOT NULL REFERENCES admin_accounts(id) ON DELETE CASCADE,
    code_hash bytea NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    used_at timestamptz,
    CONSTRAINT admin_recovery_codes_hash_length CHECK (octet_length(code_hash) = 32),
    UNIQUE (admin_id, code_hash)
);
CREATE INDEX admin_recovery_codes_unused_idx ON admin_recovery_codes(admin_id) WHERE used_at IS NULL;

CREATE TABLE admin_login_failures (
    id bigserial PRIMARY KEY,
    email_normalized varchar(254) NOT NULL,
    client_ip inet,
    attempted_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX admin_login_failures_email_time_idx ON admin_login_failures(email_normalized, attempted_at DESC);
CREATE INDEX admin_login_failures_ip_time_idx ON admin_login_failures(client_ip, attempted_at DESC) WHERE client_ip IS NOT NULL;

CREATE TABLE admin_audit_events (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    actor_admin_id uuid REFERENCES admin_accounts(id) ON DELETE SET NULL,
    session_id uuid REFERENCES admin_sessions(id) ON DELETE SET NULL,
    actor_role varchar(32),
    action varchar(80) NOT NULL,
    target_type varchar(40),
    target_id varchar(128),
    reason varchar(500),
    detail jsonb NOT NULL DEFAULT '{}'::jsonb,
    client_ip inet,
    user_agent varchar(500) NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT admin_audit_events_action_nonempty CHECK (char_length(btrim(action)) BETWEEN 1 AND 80),
    CONSTRAINT admin_audit_events_role_valid CHECK (actor_role IS NULL OR actor_role IN ('SUPER_ADMIN', 'MODERATOR', 'SUPPORT_READ_ONLY')),
    CONSTRAINT admin_audit_events_detail_object CHECK (jsonb_typeof(detail) = 'object')
);
CREATE INDEX admin_audit_events_time_idx ON admin_audit_events(created_at DESC);
CREATE INDEX admin_audit_events_actor_time_idx ON admin_audit_events(actor_admin_id, created_at DESC);
CREATE INDEX admin_audit_events_target_time_idx ON admin_audit_events(target_type, target_id, created_at DESC);
