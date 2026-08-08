CREATE TABLE profile_avatars (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    content_type varchar(32) NOT NULL,
    image_bytes bytea NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT profile_avatars_content_type_valid CHECK (
        content_type IN ('image/jpeg', 'image/png', 'image/webp')
    ),
    CONSTRAINT profile_avatars_size_valid CHECK (
        octet_length(image_bytes) BETWEEN 1 AND 2097152
    )
);

CREATE INDEX profile_avatars_updated_idx ON profile_avatars(updated_at DESC);
