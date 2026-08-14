package admin

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

const SettingRegistrationMode = "REGISTRATION_MODE"

type RuntimeSetting struct {
	Key       string    `json:"key"`
	Value     string    `json:"value"`
	UpdatedAt time.Time `json:"updatedAt"`
}

func (service *Service) LoadRuntimeSetting(ctx context.Context, key string) (RuntimeSetting, error) {
	key = strings.ToUpper(strings.TrimSpace(key))
	if key != SettingRegistrationMode {
		return RuntimeSetting{}, fmt.Errorf("%w: unsupported runtime setting", ErrInvalidInput)
	}
	var item RuntimeSetting
	item.Key = key
	if err := service.pool.QueryRow(ctx, `SELECT value_text,updated_at FROM admin_runtime_settings WHERE key=$1`, key).Scan(&item.Value, &item.UpdatedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return RuntimeSetting{}, ErrNotFound
		}
		return RuntimeSetting{}, fmt.Errorf("load runtime setting: %w", err)
	}
	return item, nil
}

func (service *Service) SetRegistrationMode(ctx context.Context, principal Principal, mode, reason string, client ClientContext) (RuntimeSetting, error) {
	if !principal.Role.CanManageAdmins() {
		service.auditBestEffort(ctx, &principal.AdminID, &principal.SessionID, principal.Role, "REGISTRATION_MODE_CHANGE_DENIED", "SYSTEM_SETTING", SettingRegistrationMode, "", nil, client)
		return RuntimeSetting{}, ErrForbidden
	}
	mode = strings.ToLower(strings.TrimSpace(mode))
	reason = strings.TrimSpace(reason)
	if (mode != "open" && mode != "closed") || len(reason) < 3 || len(reason) > 500 {
		return RuntimeSetting{}, fmt.Errorf("%w: invalid registration mode update", ErrInvalidInput)
	}
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return RuntimeSetting{}, fmt.Errorf("begin registration setting update: %w", err)
	}
	defer tx.Rollback(ctx)
	var previous string
	if err := tx.QueryRow(ctx, `SELECT value_text FROM admin_runtime_settings WHERE key=$1 FOR UPDATE`, SettingRegistrationMode).Scan(&previous); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return RuntimeSetting{}, fmt.Errorf("load previous registration mode: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO admin_runtime_settings(key,value_text,updated_by_admin_id,created_at,updated_at)
		VALUES($1,$2,$3,$4,$4)
		ON CONFLICT(key) DO UPDATE SET value_text=EXCLUDED.value_text,updated_by_admin_id=EXCLUDED.updated_by_admin_id,updated_at=EXCLUDED.updated_at
	`, SettingRegistrationMode, mode, principal.AdminID, now); err != nil {
		return RuntimeSetting{}, fmt.Errorf("persist registration mode: %w", err)
	}
	if err := insertAudit(ctx, tx, &principal.AdminID, &principal.SessionID, principal.Role, "REGISTRATION_MODE_CHANGED", "SYSTEM_SETTING", SettingRegistrationMode, reason,
		map[string]any{"previous": previous, "current": mode}, client, now); err != nil {
		return RuntimeSetting{}, fmt.Errorf("audit registration mode: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return RuntimeSetting{}, fmt.Errorf("commit registration mode: %w", err)
	}
	return RuntimeSetting{Key: SettingRegistrationMode, Value: mode, UpdatedAt: now}, nil
}
