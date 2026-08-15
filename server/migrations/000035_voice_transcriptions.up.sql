CREATE TABLE voice_transcription_preferences (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    auto_transcribe_enabled boolean NOT NULL DEFAULT false,
    enabled_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK ((auto_transcribe_enabled AND enabled_at IS NOT NULL) OR (NOT auto_transcribe_enabled AND enabled_at IS NULL))
);
CREATE INDEX voice_transcription_preferences_enabled_idx ON voice_transcription_preferences(enabled_at, user_id) WHERE auto_transcribe_enabled=true;

CREATE TABLE voice_transcriptions (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    message_id uuid NOT NULL UNIQUE REFERENCES messages(id) ON DELETE CASCADE,
    requested_by_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status varchar(16) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','RUNNING','COMPLETED','FAILED')),
    transcript text,
    language varchar(32),
    model varchar(128),
    error_category varchar(64),
    retryable boolean NOT NULL DEFAULT false,
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    available_at timestamptz NOT NULL DEFAULT now(),
    lease_expires_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    completed_at timestamptz,
    CHECK (status <> 'COMPLETED' OR (transcript IS NOT NULL AND completed_at IS NOT NULL AND error_category IS NULL)),
    CHECK (status <> 'FAILED' OR (completed_at IS NOT NULL AND error_category IS NOT NULL))
);
CREATE INDEX voice_transcriptions_pending_idx ON voice_transcriptions(available_at, created_at, id) WHERE status='PENDING';
CREATE INDEX voice_transcriptions_running_lease_idx ON voice_transcriptions(lease_expires_at, id) WHERE status='RUNNING';
