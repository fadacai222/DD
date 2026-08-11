CREATE TABLE data_export_requests (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    idempotency_key varchar(128),
    status varchar(24) NOT NULL DEFAULT 'QUEUED',
    requested_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    completed_at timestamptz,
    expires_at timestamptz,
    artifact_object_key text,
    artifact_size_bytes bigint,
    artifact_sha256 varchar(64),
    attempt_count integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    lease_expires_at timestamptz,
    last_error text,
    CONSTRAINT data_export_status_valid CHECK (status IN ('QUEUED','PROCESSING','COMPLETED','FAILED','EXPIRED')),
    CONSTRAINT data_export_attempt_nonnegative CHECK (attempt_count >= 0),
    CONSTRAINT data_export_artifact_size_nonnegative CHECK (artifact_size_bytes IS NULL OR artifact_size_bytes >= 0),
    CONSTRAINT data_export_sha256_valid CHECK (artifact_sha256 IS NULL OR artifact_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT data_export_completed_consistent CHECK (
        (status = 'COMPLETED' AND completed_at IS NOT NULL AND expires_at IS NOT NULL AND artifact_object_key IS NOT NULL AND artifact_size_bytes IS NOT NULL AND artifact_sha256 IS NOT NULL)
        OR status <> 'COMPLETED'
    )
);
CREATE UNIQUE INDEX data_export_idempotency_uidx
    ON data_export_requests(user_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;
CREATE INDEX data_export_user_time_idx ON data_export_requests(user_id, requested_at DESC, id DESC);
CREATE INDEX data_export_worker_idx
    ON data_export_requests(next_attempt_at, requested_at, id)
    WHERE status IN ('QUEUED','PROCESSING','FAILED');
CREATE UNIQUE INDEX data_export_single_active_uidx
    ON data_export_requests(user_id)
    WHERE status IN ('QUEUED','PROCESSING');

CREATE TABLE account_deletion_requests (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    request_device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
    idempotency_key varchar(128),
    status varchar(24) NOT NULL DEFAULT 'REQUESTED',
    requested_at timestamptz NOT NULL DEFAULT now(),
    cooling_off_until timestamptz NOT NULL,
    execution_started_at timestamptz,
    completed_at timestamptz,
    cancelled_at timestamptz,
    failed_at timestamptz,
    attempt_count integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL,
    lease_expires_at timestamptz,
    last_error text,
    retention_policy_version varchar(32) NOT NULL DEFAULT 'data-rights-v1',
    CONSTRAINT account_deletion_status_valid CHECK (status IN ('REQUESTED','COOLING_OFF','EXECUTING','COMPLETED','CANCELLED','FAILED')),
    CONSTRAINT account_deletion_attempt_nonnegative CHECK (attempt_count >= 0),
    CONSTRAINT account_deletion_cooling_after_request CHECK (cooling_off_until > requested_at),
    CONSTRAINT account_deletion_terminal_timestamps CHECK (
        (status='COMPLETED' AND completed_at IS NOT NULL)
        OR (status='CANCELLED' AND cancelled_at IS NOT NULL)
        OR (status='FAILED' AND failed_at IS NOT NULL)
        OR status IN ('REQUESTED','COOLING_OFF','EXECUTING')
    )
);
CREATE UNIQUE INDEX account_deletion_idempotency_uidx
    ON account_deletion_requests(user_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;
CREATE UNIQUE INDEX account_deletion_single_active_uidx
    ON account_deletion_requests(user_id)
    WHERE status IN ('REQUESTED','COOLING_OFF','EXECUTING','FAILED');
CREATE INDEX account_deletion_worker_idx
    ON account_deletion_requests(next_attempt_at, requested_at, id)
    WHERE status IN ('REQUESTED','COOLING_OFF','EXECUTING','FAILED');
CREATE INDEX account_deletion_user_time_idx ON account_deletion_requests(user_id, requested_at DESC, id DESC);

CREATE TABLE data_rights_object_deletions (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    deletion_request_id uuid NOT NULL REFERENCES account_deletion_requests(id) ON DELETE CASCADE,
    media_id uuid REFERENCES media_objects(id) ON DELETE SET NULL,
    object_key text NOT NULL,
    status varchar(16) NOT NULL DEFAULT 'PENDING',
    attempt_count integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT data_rights_object_delete_status_valid CHECK (status IN ('PENDING','PROCESSING','COMPLETED','FAILED')),
    CONSTRAINT data_rights_object_delete_attempt_nonnegative CHECK (attempt_count >= 0),
    UNIQUE(deletion_request_id, object_key)
);
CREATE INDEX data_rights_object_delete_worker_idx
    ON data_rights_object_deletions(next_attempt_at, created_at, id)
    WHERE status IN ('PENDING','PROCESSING','FAILED');

CREATE TABLE data_rights_audit_events (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    request_id uuid NOT NULL,
    request_type varchar(24) NOT NULL,
    event_type varchar(48) NOT NULL,
    detail jsonb NOT NULL DEFAULT '{}'::jsonb,
    retention_class varchar(24) NOT NULL DEFAULT 'LEGAL_AUDIT',
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT data_rights_audit_request_type_valid CHECK (request_type IN ('EXPORT','ACCOUNT_DELETION')),
    CONSTRAINT data_rights_audit_event_nonempty CHECK (char_length(btrim(event_type)) BETWEEN 1 AND 48),
    CONSTRAINT data_rights_audit_retention_valid CHECK (retention_class IN ('LEGAL_AUDIT'))
);
CREATE INDEX data_rights_audit_user_time_idx ON data_rights_audit_events(user_id, created_at DESC);
CREATE INDEX data_rights_audit_request_idx ON data_rights_audit_events(request_id, created_at, id);
