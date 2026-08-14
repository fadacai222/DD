CREATE TABLE admin_integration_secrets (
    key varchar(64) PRIMARY KEY,
    secret_ciphertext bytea NOT NULL,
    updated_by_admin_id uuid REFERENCES admin_accounts(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT admin_integration_secrets_key_valid CHECK (key IN ('TELEGRAM_BOT_TOKEN')),
    CONSTRAINT admin_integration_secrets_ciphertext_nonempty CHECK (octet_length(secret_ciphertext) >= 32)
);
