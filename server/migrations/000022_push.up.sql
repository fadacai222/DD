CREATE TABLE user_notification_preferences (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    push_enabled boolean NOT NULL DEFAULT true,
    preview_mode varchar(24) NOT NULL DEFAULT 'SENDER_ONLY',
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT user_notification_preview_mode_valid CHECK (
        preview_mode IN ('FULL','SENDER_ONLY','HIDDEN')
    )
);

CREATE TABLE device_push_endpoints (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    provider varchar(24) NOT NULL,
    endpoint text NOT NULL,
    endpoint_hash bytea NOT NULL,
    app_id varchar(160) NOT NULL DEFAULT '',
    environment varchar(16) NOT NULL DEFAULT 'PRODUCTION',
    status varchar(16) NOT NULL DEFAULT 'ACTIVE',
    failure_count integer NOT NULL DEFAULT 0,
    last_success_at timestamptz,
    last_failure_at timestamptz,
    last_failure_code varchar(80),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT device_push_provider_valid CHECK (provider IN ('FCM','APNS','UNIFIEDPUSH')),
    CONSTRAINT device_push_environment_valid CHECK (environment IN ('PRODUCTION','SANDBOX')),
    CONSTRAINT device_push_status_valid CHECK (status IN ('ACTIVE','INVALID','DISABLED')),
    CONSTRAINT device_push_endpoint_hash_length CHECK (octet_length(endpoint_hash)=32),
    CONSTRAINT device_push_failure_count_nonnegative CHECK (failure_count >= 0),
    CONSTRAINT device_push_endpoint_nonempty CHECK (char_length(btrim(endpoint)) BETWEEN 1 AND 4096)
);
CREATE UNIQUE INDEX device_push_device_provider_uidx
    ON device_push_endpoints(device_id,provider);
CREATE UNIQUE INDEX device_push_provider_endpoint_uidx
    ON device_push_endpoints(provider,endpoint_hash);
CREATE INDEX device_push_active_device_idx
    ON device_push_endpoints(device_id,id)
    WHERE status='ACTIVE';

CREATE TABLE push_jobs (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    recipient_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    event_type varchar(64) NOT NULL,
    resource_id uuid,
    conversation_id uuid REFERENCES conversations(id) ON DELETE CASCADE,
    actor_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    dedupe_key varchar(200) NOT NULL,
    payload_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    status varchar(16) NOT NULL DEFAULT 'PENDING',
    attempts integer NOT NULL DEFAULT 0,
    available_at timestamptz NOT NULL DEFAULT now(),
    last_error varchar(1000),
    created_at timestamptz NOT NULL DEFAULT now(),
    sent_at timestamptz,
    CONSTRAINT push_jobs_event_type_nonempty CHECK (char_length(btrim(event_type)) BETWEEN 1 AND 64),
    CONSTRAINT push_jobs_status_valid CHECK (status IN ('PENDING','SENT','DROPPED')),
    CONSTRAINT push_jobs_attempts_nonnegative CHECK (attempts >= 0),
    CONSTRAINT push_jobs_dedupe_nonempty CHECK (char_length(btrim(dedupe_key)) BETWEEN 1 AND 200)
);
CREATE UNIQUE INDEX push_jobs_dedupe_uidx ON push_jobs(dedupe_key);
CREATE INDEX push_jobs_pending_idx
    ON push_jobs(available_at,created_at,id)
    WHERE status='PENDING';
CREATE INDEX push_jobs_recipient_idx
    ON push_jobs(recipient_user_id,created_at DESC);
