CREATE TABLE media_objects (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    storage_key text NOT NULL UNIQUE,
    original_name text NOT NULL,
    mime_type text NOT NULL,
    size_bytes bigint NOT NULL,
    sha256 char(64) NOT NULL,
    purpose text NOT NULL,
    status text NOT NULL DEFAULT 'UPLOADING',
    encryption_mode text NOT NULL DEFAULT 'NONE',
    created_at timestamptz NOT NULL DEFAULT now(),
    ready_at timestamptz,
    deleted_at timestamptz,
    CONSTRAINT media_objects_name_length CHECK (char_length(original_name) BETWEEN 1 AND 255),
    CONSTRAINT media_objects_mime_length CHECK (char_length(mime_type) BETWEEN 3 AND 120),
    CONSTRAINT media_objects_size_positive CHECK (size_bytes > 0),
    CONSTRAINT media_objects_sha256_hex CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT media_objects_purpose_valid CHECK (purpose IN ('CHAT_IMAGE','CHAT_FILE','CHAT_VOICE','STICKER','GIF')),
    CONSTRAINT media_objects_status_valid CHECK (status IN ('UPLOADING','READY','QUARANTINED','FAILED','DELETED')),
    CONSTRAINT media_objects_encryption_valid CHECK (encryption_mode IN ('NONE','E2EE')),
    CONSTRAINT media_objects_ready_consistent CHECK ((status = 'READY') = (ready_at IS NOT NULL) OR status IN ('QUARANTINED','FAILED','DELETED'))
);

CREATE INDEX media_objects_owner_status_created_idx
    ON media_objects(owner_user_id, status, created_at DESC);
CREATE INDEX media_objects_cleanup_idx
    ON media_objects(status, created_at)
    WHERE status IN ('UPLOADING','FAILED','DELETED');

CREATE TABLE media_uploads (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    media_id uuid NOT NULL UNIQUE REFERENCES media_objects(id) ON DELETE CASCADE,
    owner_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expected_size bigint NOT NULL,
    expected_sha256 char(64) NOT NULL,
    expires_at timestamptz NOT NULL,
    completed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT media_uploads_size_positive CHECK (expected_size > 0),
    CONSTRAINT media_uploads_sha256_hex CHECK (expected_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT media_uploads_expiry_after_create CHECK (expires_at > created_at)
);

CREATE INDEX media_uploads_owner_active_idx
    ON media_uploads(owner_user_id, expires_at)
    WHERE completed_at IS NULL;

CREATE TABLE media_variants (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    media_id uuid NOT NULL REFERENCES media_objects(id) ON DELETE CASCADE,
    variant_type text NOT NULL,
    storage_key text NOT NULL UNIQUE,
    mime_type text NOT NULL,
    size_bytes bigint NOT NULL,
    width integer,
    height integer,
    duration_ms integer,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT media_variants_type_nonempty CHECK (char_length(btrim(variant_type)) BETWEEN 1 AND 40),
    CONSTRAINT media_variants_size_positive CHECK (size_bytes > 0),
    CONSTRAINT media_variants_dimensions_positive CHECK ((width IS NULL OR width > 0) AND (height IS NULL OR height > 0)),
    CONSTRAINT media_variants_duration_nonnegative CHECK (duration_ms IS NULL OR duration_ms >= 0),
    UNIQUE(media_id, variant_type)
);
