package push

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Service struct {
	pool              *pgxpool.Pool
	now               func() time.Time
	publicBaseURL     string
	avatarTokenSecret string
	observer          Observer
}

type Config struct {
	Pool              *pgxpool.Pool
	Now               func() time.Time
	PublicBaseURL     string
	AvatarTokenSecret string
	Observer          Observer
}

func NewService(config Config) (*Service, error) {
	if config.Pool == nil {
		return nil, ErrUnavailable
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	return &Service{
		pool:              config.Pool,
		now:               now,
		publicBaseURL:     strings.TrimRight(strings.TrimSpace(config.PublicBaseURL), "/"),
		avatarTokenSecret: strings.TrimSpace(config.AvatarTokenSecret),
		observer:          config.Observer,
	}, nil
}

func (service *Service) GetPreferences(ctx context.Context, principal account.Principal) (Preferences, error) {
	var result Preferences
	err := service.pool.QueryRow(ctx, `
		INSERT INTO user_notification_preferences(user_id)
		VALUES($1)
		ON CONFLICT(user_id) DO UPDATE SET user_id=EXCLUDED.user_id
		RETURNING push_enabled,preview_mode,updated_at
	`, principal.UserID).Scan(&result.PushEnabled, &result.PreviewMode, &result.UpdatedAt)
	if err != nil {
		return Preferences{}, fmt.Errorf("load push preferences: %w", err)
	}
	result.UpdatedAt = result.UpdatedAt.UTC()
	return result, nil
}

func (service *Service) UpdatePreferences(ctx context.Context, principal account.Principal, input UpdatePreferencesInput) (Preferences, error) {
	preview := normalizePreviewMode(input.PreviewMode)
	if preview == "" {
		return Preferences{}, ErrInvalidInput
	}
	now := service.now().UTC()
	var result Preferences
	err := service.pool.QueryRow(ctx, `
		INSERT INTO user_notification_preferences(user_id,push_enabled,preview_mode,updated_at)
		VALUES($1,$2,$3,$4)
		ON CONFLICT(user_id) DO UPDATE
		SET push_enabled=EXCLUDED.push_enabled,preview_mode=EXCLUDED.preview_mode,updated_at=EXCLUDED.updated_at
		RETURNING push_enabled,preview_mode,updated_at
	`, principal.UserID, input.PushEnabled, preview, now).Scan(&result.PushEnabled, &result.PreviewMode, &result.UpdatedAt)
	if err != nil {
		return Preferences{}, fmt.Errorf("update push preferences: %w", err)
	}
	return result, nil
}

func (service *Service) RegisterEndpoint(ctx context.Context, principal account.Principal, input RegisterEndpointInput) (Endpoint, error) {
	provider := normalizeProvider(input.Provider)
	environment := normalizeEnvironment(input.Environment)
	endpoint := strings.TrimSpace(input.Endpoint)
	appID := strings.TrimSpace(input.AppID)
	if provider == "" || environment == "" || len(endpoint) == 0 || len(endpoint) > 4096 || len(appID) > 160 {
		return Endpoint{}, ErrInvalidInput
	}
	if provider == ProviderUnifiedPush {
		parsed, err := url.Parse(endpoint)
		if err != nil || parsed.Host == "" || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.User != nil {
			return Endpoint{}, ErrInvalidInput
		}
	} else if strings.ContainsAny(endpoint, "\r\n\t ") {
		return Endpoint{}, ErrInvalidInput
	}
	hash := sha256.Sum256([]byte(endpoint))
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return Endpoint{}, fmt.Errorf("begin push endpoint registration: %w", err)
	}
	defer tx.Rollback(ctx)

	var ownsDevice bool
	if err := tx.QueryRow(ctx, `
		SELECT EXISTS(
		  SELECT 1 FROM devices
		  WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL
		)
	`, principal.DeviceID, principal.UserID).Scan(&ownsDevice); err != nil {
		return Endpoint{}, fmt.Errorf("authorize push device: %w", err)
	}
	if !ownsDevice {
		return Endpoint{}, ErrForbidden
	}

	var existingOwner *uuid.UUID
	err = tx.QueryRow(ctx, `
		SELECT d.user_id
		FROM device_push_endpoints e
		JOIN devices d ON d.id=e.device_id
		WHERE e.provider=$1 AND e.endpoint_hash=$2
		FOR UPDATE OF e
	`, provider, hash[:]).Scan(&existingOwner)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return Endpoint{}, fmt.Errorf("check push endpoint ownership: %w", err)
	}
	if err == nil && existingOwner != nil && *existingOwner != principal.UserID {
		return Endpoint{}, ErrConflict
	}
	if err == nil {
		if _, err := tx.Exec(ctx, `DELETE FROM device_push_endpoints WHERE provider=$1 AND endpoint_hash=$2`, provider, hash[:]); err != nil {
			return Endpoint{}, fmt.Errorf("move existing push endpoint: %w", err)
		}
	}

	var id uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO device_push_endpoints(
		  device_id,provider,endpoint,endpoint_hash,app_id,environment,status,
		  failure_count,last_success_at,last_failure_at,last_failure_code,created_at,updated_at
		) VALUES($1,$2,$3,$4,$5,$6,'ACTIVE',0,NULL,NULL,NULL,$7,$7)
		ON CONFLICT(device_id,provider) DO UPDATE
		SET endpoint=EXCLUDED.endpoint,endpoint_hash=EXCLUDED.endpoint_hash,app_id=EXCLUDED.app_id,
		    environment=EXCLUDED.environment,status='ACTIVE',failure_count=0,last_failure_at=NULL,
		    last_failure_code=NULL,updated_at=EXCLUDED.updated_at
		RETURNING id
	`, principal.DeviceID, provider, endpoint, hash[:], appID, environment, now).Scan(&id); err != nil {
		return Endpoint{}, fmt.Errorf("register push endpoint: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Endpoint{}, fmt.Errorf("commit push endpoint registration: %w", err)
	}
	return service.getEndpoint(ctx, principal, id)
}

func (service *Service) ListEndpoints(ctx context.Context, principal account.Principal) ([]Endpoint, error) {
	rows, err := service.pool.Query(ctx, `
		SELECT e.id::text,e.provider,e.app_id,e.environment,e.status,e.failure_count,
		       e.last_success_at,e.last_failure_at,COALESCE(e.last_failure_code,''),e.updated_at
		FROM device_push_endpoints e
		JOIN devices d ON d.id=e.device_id
		WHERE e.device_id=$1 AND d.user_id=$2
		ORDER BY e.provider,e.updated_at DESC
	`, principal.DeviceID, principal.UserID)
	if err != nil {
		return nil, fmt.Errorf("list push endpoints: %w", err)
	}
	defer rows.Close()
	items := make([]Endpoint, 0, 3)
	for rows.Next() {
		var item Endpoint
		if err := rows.Scan(&item.ID, &item.Provider, &item.AppID, &item.Environment, &item.Status, &item.FailureCount, &item.LastSuccessAt, &item.LastFailureAt, &item.LastFailureCode, &item.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scan push endpoint: %w", err)
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate push endpoints: %w", err)
	}
	return items, nil
}

func (service *Service) DeleteEndpoint(ctx context.Context, principal account.Principal, providerRaw string) error {
	provider := normalizeProvider(providerRaw)
	if provider == "" {
		return ErrInvalidInput
	}
	command, err := service.pool.Exec(ctx, `
		DELETE FROM device_push_endpoints e
		USING devices d
		WHERE e.device_id=d.id AND e.device_id=$1 AND d.user_id=$2 AND e.provider=$3
	`, principal.DeviceID, principal.UserID, provider)
	if err != nil {
		return fmt.Errorf("delete push endpoint: %w", err)
	}
	if command.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (service *Service) EnqueueTest(ctx context.Context, principal account.Principal) error {
	now := service.now().UTC()
	_, err := service.pool.Exec(ctx, `
		INSERT INTO push_jobs(recipient_user_id,event_type,dedupe_key,payload_json,status,available_at,created_at)
		VALUES($1,'PUSH_TEST',$2,$3::jsonb,'PENDING',$4,$4)
	`, principal.UserID, "push-test:"+uuid.NewString(), `{"title":"DD Push 测试","body":"如果你看到这条通知，当前设备的 Push 链路已打通。"}`, now)
	if err != nil {
		return fmt.Errorf("enqueue push test: %w", err)
	}
	return nil
}

func (service *Service) getEndpoint(ctx context.Context, principal account.Principal, id uuid.UUID) (Endpoint, error) {
	var item Endpoint
	err := service.pool.QueryRow(ctx, `
		SELECT e.id::text,e.provider,e.app_id,e.environment,e.status,e.failure_count,
		       e.last_success_at,e.last_failure_at,COALESCE(e.last_failure_code,''),e.updated_at
		FROM device_push_endpoints e
		JOIN devices d ON d.id=e.device_id
		WHERE e.id=$1 AND e.device_id=$2 AND d.user_id=$3
	`, id, principal.DeviceID, principal.UserID).Scan(&item.ID, &item.Provider, &item.AppID, &item.Environment, &item.Status, &item.FailureCount, &item.LastSuccessAt, &item.LastFailureAt, &item.LastFailureCode, &item.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Endpoint{}, ErrNotFound
	}
	if err != nil {
		return Endpoint{}, fmt.Errorf("load push endpoint: %w", err)
	}
	return item, nil
}

func normalizeProvider(raw string) string {
	switch strings.ToUpper(strings.TrimSpace(raw)) {
	case ProviderFCM:
		return ProviderFCM
	case ProviderAPNS:
		return ProviderAPNS
	case ProviderUnifiedPush:
		return ProviderUnifiedPush
	default:
		return ""
	}
}

func normalizePreviewMode(raw string) string {
	switch strings.ToUpper(strings.TrimSpace(raw)) {
	case PreviewFull:
		return PreviewFull
	case PreviewSenderOnly:
		return PreviewSenderOnly
	case PreviewHidden:
		return PreviewHidden
	default:
		return ""
	}
}

func normalizeEnvironment(raw string) string {
	value := strings.ToUpper(strings.TrimSpace(raw))
	if value == "" {
		value = "PRODUCTION"
	}
	if value == "PRODUCTION" || value == "SANDBOX" {
		return value
	}
	return ""
}
