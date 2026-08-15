CREATE TABLE admin_runtime_settings (
    key varchar(64) PRIMARY KEY,
    value_text varchar(256) NOT NULL,
    updated_by_admin_id uuid REFERENCES admin_accounts(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT admin_runtime_settings_key_valid CHECK (key IN ('REGISTRATION_MODE')),
    CONSTRAINT admin_runtime_settings_value_nonempty CHECK (char_length(btrim(value_text)) BETWEEN 1 AND 256)
);
