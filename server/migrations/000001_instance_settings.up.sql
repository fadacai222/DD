CREATE TABLE instance_settings (
    key text PRIMARY KEY,
    value jsonb NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT instance_settings_key_length CHECK (char_length(key) BETWEEN 1 AND 100)
);
