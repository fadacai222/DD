CREATE TABLE auth_login_attempts (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    email_normalized varchar(254) NOT NULL,
    succeeded boolean NOT NULL DEFAULT false,
    attempted_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX auth_login_attempts_email_time_idx ON auth_login_attempts(email_normalized, attempted_at DESC);

CREATE TABLE auth_audit_events (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
    event_type varchar(64) NOT NULL,
    detail jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT auth_audit_events_type_nonempty CHECK (char_length(btrim(event_type)) BETWEEN 1 AND 64)
);
CREATE INDEX auth_audit_events_user_time_idx ON auth_audit_events(user_id, created_at DESC);
CREATE INDEX auth_audit_events_type_time_idx ON auth_audit_events(event_type, created_at DESC);
