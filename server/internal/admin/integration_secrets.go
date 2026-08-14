package admin

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

const IntegrationTelegramBotToken = "TELEGRAM_BOT_TOKEN"

func validIntegrationSecretKey(key string) bool {
	return strings.TrimSpace(key) == IntegrationTelegramBotToken
}

func (service *Service) LoadIntegrationSecret(ctx context.Context, key string) (IntegrationSecret, error) {
	key = strings.TrimSpace(key)
	if !validIntegrationSecretKey(key) {
		return IntegrationSecret{}, fmt.Errorf("%w: unsupported integration secret", ErrInvalidInput)
	}
	var ciphertext []byte
	var result IntegrationSecret
	err := service.pool.QueryRow(ctx, `
		SELECT key,secret_ciphertext,updated_at
		FROM admin_integration_secrets
		WHERE key=$1
	`, key).Scan(&result.Key, &ciphertext, &result.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return IntegrationSecret{}, ErrNotFound
	}
	if err != nil {
		return IntegrationSecret{}, fmt.Errorf("load admin integration secret: %w", err)
	}
	plaintext, err := service.integrationBox.decrypt(ciphertext)
	if err != nil {
		return IntegrationSecret{}, fmt.Errorf("decrypt admin integration secret: %w", err)
	}
	result.Value = string(plaintext)
	return result, nil
}

func (service *Service) SetIntegrationSecret(ctx context.Context, principal Principal, key, value string, client ClientContext) (IntegrationSecretStatus, error) {
	key = strings.TrimSpace(key)
	value = strings.TrimSpace(value)
	if !principal.Role.CanManageIntegrations() {
		service.auditBestEffort(ctx, &principal.AdminID, &principal.SessionID, principal.Role, "INTEGRATION_SECRET_UPDATE_DENIED", "INTEGRATION", key, "", nil, client)
		return IntegrationSecretStatus{}, ErrForbidden
	}
	if !validIntegrationSecretKey(key) || value == "" || len(value) > 512 {
		return IntegrationSecretStatus{}, fmt.Errorf("%w: integration secret is invalid", ErrInvalidInput)
	}
	ciphertext, err := service.integrationBox.encrypt([]byte(value))
	if err != nil {
		return IntegrationSecretStatus{}, fmt.Errorf("encrypt admin integration secret: %w", err)
	}
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return IntegrationSecretStatus{}, fmt.Errorf("begin integration secret update: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		INSERT INTO admin_integration_secrets(key,secret_ciphertext,updated_by_admin_id,created_at,updated_at)
		VALUES($1,$2,$3,$4,$4)
		ON CONFLICT(key) DO UPDATE SET
			secret_ciphertext=EXCLUDED.secret_ciphertext,
			updated_by_admin_id=EXCLUDED.updated_by_admin_id,
			updated_at=EXCLUDED.updated_at
	`, key, ciphertext, principal.AdminID, now); err != nil {
		return IntegrationSecretStatus{}, fmt.Errorf("store admin integration secret: %w", err)
	}
	if err := insertAudit(ctx, tx, &principal.AdminID, &principal.SessionID, principal.Role, "INTEGRATION_SECRET_UPDATED", "INTEGRATION", key, "", map[string]any{"configured": true}, client, now); err != nil {
		return IntegrationSecretStatus{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return IntegrationSecretStatus{}, fmt.Errorf("commit integration secret update: %w", err)
	}
	return IntegrationSecretStatus{Key: key, Configured: true, UpdatedAt: now}, nil
}
