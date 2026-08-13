package transcription

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const maxVoiceBytes = int64(25 * 1024 * 1024)

type MediaGateway interface {
	CreateDownloadURL(ctx context.Context, principal account.Principal, mediaID uuid.UUID) (string, time.Time, error)
}

type Config struct {
	Pool       *pgxpool.Pool
	Provider   Provider
	Media      MediaGateway
	HTTPClient *http.Client
	Now        func() time.Time
}

type Service struct {
	pool       *pgxpool.Pool
	provider   Provider
	media      MediaGateway
	httpClient *http.Client
	now        func() time.Time
}

func NewService(config Config) (*Service, error) {
	if config.Pool == nil {
		return nil, ErrUnavailable
	}
	now := config.Now
	if now == nil { now = time.Now }
	httpClient := config.HTTPClient
	if httpClient == nil { httpClient = &http.Client{Timeout: 90 * time.Second} }
	return &Service{pool: config.Pool, provider: config.Provider, media: config.Media, httpClient: httpClient, now: now}, nil
}

func (service *Service) ProviderAvailable() bool {
	return service != nil && service.provider != nil && service.media != nil
}

func (service *Service) Request(ctx context.Context, principal account.Principal, messageID uuid.UUID) (Transcription, error) {
	if messageID == uuid.Nil { return Transcription{}, ErrInvalidInput }
	if _, err := service.loadAuthorizedVoice(ctx, principal, messageID); err != nil { return Transcription{}, err }
	if !service.ProviderAvailable() { return Transcription{}, ErrUnavailable }
	now := service.now().UTC()
	var id uuid.UUID
	if err := service.pool.QueryRow(ctx, `
		INSERT INTO voice_transcriptions(message_id,requested_by_user_id,status,available_at,created_at,updated_at)
		VALUES($1,$2,'PENDING',$3,$3,$3)
		ON CONFLICT(message_id) DO UPDATE SET message_id=EXCLUDED.message_id
		RETURNING id
	`, messageID, principal.UserID, now).Scan(&id); err != nil {
		return Transcription{}, fmt.Errorf("request voice transcription: %w", err)
	}
	return service.getByID(ctx, id)
}

func (service *Service) Get(ctx context.Context, principal account.Principal, messageID uuid.UUID) (Transcription, error) {
	if messageID == uuid.Nil { return Transcription{}, ErrInvalidInput }
	if _, err := service.loadAuthorizedVoice(ctx, principal, messageID); err != nil { return Transcription{}, err }
	var id uuid.UUID
	if err := service.pool.QueryRow(ctx, `SELECT id FROM voice_transcriptions WHERE message_id=$1`, messageID).Scan(&id); errors.Is(err, pgx.ErrNoRows) {
		return Transcription{}, ErrNotFound
	} else if err != nil {
		return Transcription{}, fmt.Errorf("load voice transcription id: %w", err)
	}
	return service.getByID(ctx, id)
}

func (service *Service) GetPreferences(ctx context.Context, principal account.Principal) (Preferences, error) {
	var enabled bool
	if err := service.pool.QueryRow(ctx, `
		INSERT INTO voice_transcription_preferences(user_id,auto_transcribe_enabled,enabled_at,updated_at)
		VALUES($1,false,NULL,$2)
		ON CONFLICT(user_id) DO UPDATE SET user_id=EXCLUDED.user_id
		RETURNING auto_transcribe_enabled
	`, principal.UserID, service.now().UTC()).Scan(&enabled); err != nil {
		return Preferences{}, fmt.Errorf("load voice transcription preferences: %w", err)
	}
	return Preferences{AutoTranscribeEnabled: enabled, ProviderAvailable: service.ProviderAvailable()}, nil
}

func (service *Service) UpdatePreferences(ctx context.Context, principal account.Principal, input UpdatePreferencesInput) (Preferences, error) {
	if input.AutoTranscribeEnabled && !service.ProviderAvailable() { return Preferences{}, ErrUnavailable }
	now := service.now().UTC()
	var enabled bool
	if err := service.pool.QueryRow(ctx, `
		INSERT INTO voice_transcription_preferences(user_id,auto_transcribe_enabled,enabled_at,updated_at)
		VALUES($1,$2,CASE WHEN $2 THEN $3::timestamptz ELSE NULL::timestamptz END,$3::timestamptz)
		ON CONFLICT(user_id) DO UPDATE SET
			auto_transcribe_enabled=EXCLUDED.auto_transcribe_enabled,
			enabled_at=CASE
				WHEN EXCLUDED.auto_transcribe_enabled=false THEN NULL
				WHEN voice_transcription_preferences.auto_transcribe_enabled=true THEN voice_transcription_preferences.enabled_at
				ELSE EXCLUDED.enabled_at
			END,
			updated_at=EXCLUDED.updated_at
		RETURNING auto_transcribe_enabled
	`, principal.UserID, input.AutoTranscribeEnabled, now).Scan(&enabled); err != nil {
		return Preferences{}, fmt.Errorf("update voice transcription preferences: %w", err)
	}
	return Preferences{AutoTranscribeEnabled: enabled, ProviderAvailable: service.ProviderAvailable()}, nil
}

type authorizedVoice struct {
	MediaID  uuid.UUID
	FileName string
	MIMEType string
}

func (service *Service) loadAuthorizedVoice(ctx context.Context, principal account.Principal, messageID uuid.UUID) (authorizedVoice, error) {
	var messageType string
	var result authorizedVoice
	err := service.pool.QueryRow(ctx, `
		SELECT m.type,COALESCE(mm.media_id,'00000000-0000-0000-0000-000000000000'::uuid),COALESCE(mo.original_name,''),COALESCE(mo.mime_type,'')
		FROM messages m
		JOIN conversation_members cm ON cm.conversation_id=m.conversation_id AND cm.user_id=$2 AND cm.status='ACTIVE'
		LEFT JOIN message_local_deletions ld ON ld.message_id=m.id AND ld.user_id=$2
		LEFT JOIN message_media mm ON mm.message_id=m.id AND mm.role='PRIMARY'
		LEFT JOIN media_objects mo ON mo.id=mm.media_id AND mo.status='READY' AND mo.deleted_at IS NULL
		WHERE m.id=$1 AND m.deleted_at IS NULL AND m.recalled_at IS NULL AND ld.message_id IS NULL
	`, messageID, principal.UserID).Scan(&messageType, &result.MediaID, &result.FileName, &result.MIMEType)
	if errors.Is(err, pgx.ErrNoRows) { return authorizedVoice{}, ErrNotFound }
	if err != nil { return authorizedVoice{}, fmt.Errorf("authorize voice transcription message: %w", err) }
	if messageType != "VOICE" { return authorizedVoice{}, ErrNotVoice }
	if result.MediaID == uuid.Nil { return authorizedVoice{}, ErrNotFound }
	return result, nil
}

func (service *Service) getByID(ctx context.Context, id uuid.UUID) (Transcription, error) {
	var result Transcription
	var startedAt, completedAt *time.Time
	var transcript, language, model, category *string
	err := service.pool.QueryRow(ctx, `
		SELECT id::text,message_id::text,status,transcript,language,model,error_category,retryable,attempts,
		       created_at,updated_at,started_at,completed_at
		FROM voice_transcriptions WHERE id=$1
	`, id).Scan(&result.ID, &result.MessageID, &result.Status, &transcript, &language, &model, &category, &result.Retryable, &result.Attempts, &result.CreatedAt, &result.UpdatedAt, &startedAt, &completedAt)
	if errors.Is(err, pgx.ErrNoRows) { return Transcription{}, ErrNotFound }
	if err != nil { return Transcription{}, fmt.Errorf("load voice transcription: %w", err) }
	if transcript != nil { result.Transcript = *transcript }
	if language != nil { result.Language = *language }
	if model != nil { result.Model = *model }
	if category != nil { result.ErrorCategory = *category }
	result.StartedAt = startedAt
	result.CompletedAt = completedAt
	result.CreatedAt = result.CreatedAt.UTC()
	result.UpdatedAt = result.UpdatedAt.UTC()
	return result, nil
}
