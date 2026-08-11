# Production secret files

This directory is deny-by-default in Git. Keep every real value outside version control and restrict permissions to the deployment account.

Required generated secrets:

- `postgres_password`
- `database_url`
- `redis_password`
- `redis_url`
- `minio_root_password` (bundled MinIO only)
- `media_s3_access_key`
- `media_s3_secret_key`
- `backup_s3_access_key`
- `backup_s3_secret_key`
- `livekit_api_key`
- `livekit_api_secret`
- `auth_token_secret`
- `email_code_pepper`

Required operator-supplied TURN/TLS certificate files:

- `turn_cert.pem` — trusted certificate chain for `DD_TURN_DOMAIN`
- `turn_key.pem` — matching private key

Optional integrations still need a file to exist; leave it empty when disabled:

- `smtp_password`
- `telegram_bot_token`
- `fcm_service_account_json`
- `apns_private_key`

Use `./scripts/init-secrets.sh` to generate the generated secrets and empty optional files. It intentionally does **not** generate a self-signed TURN certificate because self-signed TURN/TLS is not a production-valid fallback.
