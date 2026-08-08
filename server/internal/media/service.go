package media

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	defaultUploadTTL            = 10 * time.Minute
	defaultDownloadTTL          = 5 * time.Minute
	maxActiveUploadsPerUser     = 32
	maxReservedUploadBytesUser  = int64(512 * 1024 * 1024)
)

type Service struct {
	pool        *pgxpool.Pool
	store       ObjectStore
	now         func() time.Time
	uploadTTL   time.Duration
	downloadTTL time.Duration
}

type Config struct {
	Pool        *pgxpool.Pool
	Store       ObjectStore
	Now         func() time.Time
	UploadTTL   time.Duration
	DownloadTTL time.Duration
}

func NewService(config Config) (*Service, error) {
	if config.Pool == nil || config.Store == nil {
		return nil, ErrUnavailable
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	uploadTTL := config.UploadTTL
	if uploadTTL <= 0 || uploadTTL > 15*time.Minute {
		uploadTTL = defaultUploadTTL
	}
	downloadTTL := config.DownloadTTL
	if downloadTTL <= 0 || downloadTTL > 15*time.Minute {
		downloadTTL = defaultDownloadTTL
	}
	return &Service{
		pool:        config.Pool,
		store:       config.Store,
		now:         now,
		uploadTTL:   uploadTTL,
		downloadTTL: downloadTTL,
	}, nil
}

func (service *Service) CreateUpload(ctx context.Context, principal account.Principal, input CreateUploadInput) (UploadGrant, error) {
	input = normalizeUploadInput(input)
	if err := validateUploadInput(input); err != nil {
		return UploadGrant{}, err
	}
	key, err := newStorageKey(input.Purpose)
	if err != nil {
		return UploadGrant{}, fmt.Errorf("generate media storage key: %w", err)
	}
	uploadURL, requiredHeaders, expiresAt, err := service.store.PresignPut(key, input.MIMEType, input.SHA256, service.uploadTTL)
	if err != nil {
		return UploadGrant{}, fmt.Errorf("presign media upload: %w", err)
	}

	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return UploadGrant{}, fmt.Errorf("begin media upload reservation: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, principal.UserID.String()); err != nil {
		return UploadGrant{}, fmt.Errorf("lock media quota: %w", err)
	}

	var activeCount int
	var reservedBytes int64
	if err := tx.QueryRow(ctx, `
		SELECT count(*), COALESCE(sum(u.expected_size),0)
		FROM media_uploads u
		JOIN media_objects m ON m.id=u.media_id
		WHERE u.owner_user_id=$1
		  AND u.completed_at IS NULL
		  AND u.expires_at>$2
		  AND m.status='UPLOADING'
	`, principal.UserID, now).Scan(&activeCount, &reservedBytes); err != nil {
		return UploadGrant{}, fmt.Errorf("load media quota reservation: %w", err)
	}
	if activeCount >= maxActiveUploadsPerUser || reservedBytes > maxReservedUploadBytesUser-input.Size {
		return UploadGrant{}, ErrQuotaExceeded
	}

	mediaID := uuid.New()
	uploadID := uuid.New()
	if _, err := tx.Exec(ctx, `
		INSERT INTO media_objects(id,owner_user_id,storage_key,original_name,mime_type,size_bytes,sha256,purpose,status,encryption_mode,created_at)
		VALUES($1,$2,$3,$4,$5,$6,$7,$8,'UPLOADING','NONE',$9)
	`, mediaID, principal.UserID, key, input.FileName, input.MIMEType, input.Size, input.SHA256, input.Purpose, now); err != nil {
		return UploadGrant{}, fmt.Errorf("create media object: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO media_uploads(id,media_id,owner_user_id,expected_size,expected_sha256,expires_at,created_at)
		VALUES($1,$2,$3,$4,$5,$6,$7)
	`, uploadID, mediaID, principal.UserID, input.Size, input.SHA256, expiresAt, now); err != nil {
		return UploadGrant{}, fmt.Errorf("create media upload reservation: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return UploadGrant{}, fmt.Errorf("commit media upload reservation: %w", err)
	}
	return UploadGrant{
		UploadID:        uploadID.String(),
		MediaID:         mediaID.String(),
		UploadURL:       uploadURL,
		ExpiresAt:       expiresAt,
		RequiredHeaders: requiredHeaders,
	}, nil
}

func (service *Service) CompleteUpload(ctx context.Context, principal account.Principal, uploadID uuid.UUID) (CompleteUploadResult, error) {
	if uploadID == uuid.Nil {
		return CompleteUploadResult{}, ErrInvalidInput
	}
	type reservation struct {
		mediaID        uuid.UUID
		storageKey     string
		originalName   string
		mimeType       string
		expectedSize   int64
		expectedSHA256 string
		purpose        Purpose
		status         Status
		expiresAt      time.Time
		completedAt    *time.Time
		createdAt      time.Time
	}
	loadReservation := func(queryer interface {
		QueryRow(context.Context, string, ...any) pgx.Row
	}, suffix string) (reservation, error) {
		var item reservation
		err := queryer.QueryRow(ctx, `
			SELECT u.media_id,m.storage_key,m.original_name,m.mime_type,u.expected_size,u.expected_sha256,
			       m.purpose,m.status,u.expires_at,u.completed_at,m.created_at
			FROM media_uploads u
			JOIN media_objects m ON m.id=u.media_id
			WHERE u.id=$1 AND u.owner_user_id=$2 `+suffix,
			uploadID, principal.UserID,
		).Scan(&item.mediaID, &item.storageKey, &item.originalName, &item.mimeType, &item.expectedSize,
			&item.expectedSHA256, &item.purpose, &item.status, &item.expiresAt, &item.completedAt, &item.createdAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return reservation{}, ErrNotFound
		}
		if err != nil {
			return reservation{}, fmt.Errorf("load media upload: %w", err)
		}
		return item, nil
	}

	reservationSnapshot, err := loadReservation(service.pool, "")
	if err != nil {
		return CompleteUploadResult{}, err
	}
	if reservationSnapshot.status == StatusReady && reservationSnapshot.completedAt != nil {
		return CompleteUploadResult{Media: mediaFromReservation(reservationSnapshot.mediaID, principal.UserID, reservationSnapshot.originalName, reservationSnapshot.mimeType, reservationSnapshot.expectedSize, reservationSnapshot.expectedSHA256, reservationSnapshot.purpose, reservationSnapshot.status, reservationSnapshot.createdAt, reservationSnapshot.completedAt)}, nil
	}
	if reservationSnapshot.status != StatusUploading {
		return CompleteUploadResult{}, ErrConflict
	}
	if !service.now().UTC().Before(reservationSnapshot.expiresAt) {
		return CompleteUploadResult{}, ErrUploadExpired
	}
	object, err := service.store.Stat(ctx, reservationSnapshot.storageKey)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return CompleteUploadResult{}, ErrObjectMismatch
		}
		return CompleteUploadResult{}, fmt.Errorf("inspect uploaded media object: %w", err)
	}
	if object.Size != reservationSnapshot.expectedSize || !strings.EqualFold(object.ContentType, reservationSnapshot.mimeType) || object.SHA256 == "" || !strings.EqualFold(object.SHA256, reservationSnapshot.expectedSHA256) {
		return CompleteUploadResult{}, ErrObjectMismatch
	}

	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return CompleteUploadResult{}, fmt.Errorf("begin media completion: %w", err)
	}
	defer tx.Rollback(ctx)
	locked, err := loadReservation(tx, "FOR UPDATE")
	if err != nil {
		return CompleteUploadResult{}, err
	}
	if locked.status == StatusReady && locked.completedAt != nil {
		return CompleteUploadResult{Media: mediaFromReservation(locked.mediaID, principal.UserID, locked.originalName, locked.mimeType, locked.expectedSize, locked.expectedSHA256, locked.purpose, locked.status, locked.createdAt, locked.completedAt)}, nil
	}
	if locked.status != StatusUploading || !service.now().UTC().Before(locked.expiresAt) {
		return CompleteUploadResult{}, ErrConflict
	}
	readyAt := service.now().UTC()
	if _, err := tx.Exec(ctx, `UPDATE media_objects SET status='READY',ready_at=$2 WHERE id=$1 AND status='UPLOADING'`, locked.mediaID, readyAt); err != nil {
		return CompleteUploadResult{}, fmt.Errorf("mark media ready: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE media_uploads SET completed_at=$2 WHERE id=$1 AND completed_at IS NULL`, uploadID, readyAt); err != nil {
		return CompleteUploadResult{}, fmt.Errorf("complete media upload: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return CompleteUploadResult{}, fmt.Errorf("commit media completion: %w", err)
	}
	return CompleteUploadResult{Media: mediaFromReservation(locked.mediaID, principal.UserID, locked.originalName, locked.mimeType, locked.expectedSize, locked.expectedSHA256, locked.purpose, StatusReady, locked.createdAt, &readyAt)}, nil
}

func (service *Service) GetMedia(ctx context.Context, principal account.Principal, mediaID uuid.UUID) (MediaObject, error) {
	if mediaID == uuid.Nil {
		return MediaObject{}, ErrInvalidInput
	}
	var result MediaObject
	var readyAt *time.Time
	var ownerID uuid.UUID
	var purpose Purpose
	var status Status
	var canAccess bool
	err := service.pool.QueryRow(ctx, `
		SELECT m.id,m.owner_user_id,m.original_name,m.mime_type,m.size_bytes,m.sha256,m.purpose,m.status,m.encryption_mode,m.created_at,m.ready_at,
		       (m.owner_user_id=$2 OR EXISTS(
				SELECT 1
				FROM message_media mm
				JOIN messages msg ON msg.id=mm.message_id AND msg.deleted_at IS NULL AND msg.recalled_at IS NULL
				JOIN conversation_members cm ON cm.conversation_id=msg.conversation_id AND cm.user_id=$2 AND cm.status='ACTIVE'
				LEFT JOIN message_local_deletions ld ON ld.message_id=msg.id AND ld.user_id=$2
				WHERE mm.media_id=m.id AND ld.message_id IS NULL
		   )) AS can_access
		FROM media_objects m
		WHERE m.id=$1 AND m.deleted_at IS NULL
	`, mediaID, principal.UserID).Scan(&result.ID, &ownerID, &result.OriginalName, &result.MIMEType, &result.SizeBytes, &result.SHA256, &purpose, &status, &result.EncryptionMode, &result.CreatedAt, &readyAt, &canAccess)
	if errors.Is(err, pgx.ErrNoRows) {
		return MediaObject{}, ErrNotFound
	}
	if err != nil {
		return MediaObject{}, fmt.Errorf("load media object: %w", err)
	}
	if !canAccess {
		return MediaObject{}, ErrForbidden
	}
	result.OwnerUserID = ownerID.String()
	result.Purpose = purpose
	result.Status = status
	result.ReadyAt = readyAt
	return result, nil
}

func (service *Service) CreateDownloadURL(ctx context.Context, principal account.Principal, mediaID uuid.UUID) (string, time.Time, error) {
	if mediaID == uuid.Nil {
		return "", time.Time{}, ErrInvalidInput
	}
	var key string
	var status Status
	var canAccess bool
	err := service.pool.QueryRow(ctx, `
		SELECT m.storage_key,m.status,
		       (m.owner_user_id=$2 OR EXISTS(
				SELECT 1
				FROM message_media mm
				JOIN messages msg ON msg.id=mm.message_id AND msg.deleted_at IS NULL AND msg.recalled_at IS NULL
				JOIN conversation_members cm ON cm.conversation_id=msg.conversation_id AND cm.user_id=$2 AND cm.status='ACTIVE'
				LEFT JOIN message_local_deletions ld ON ld.message_id=msg.id AND ld.user_id=$2
				WHERE mm.media_id=m.id AND ld.message_id IS NULL
		   )) AS can_access
		FROM media_objects m
		WHERE m.id=$1 AND m.deleted_at IS NULL
	`, mediaID, principal.UserID).Scan(&key, &status, &canAccess)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", time.Time{}, ErrNotFound
	}
	if err != nil {
		return "", time.Time{}, fmt.Errorf("load media download: %w", err)
	}
	if !canAccess {
		return "", time.Time{}, ErrForbidden
	}
	if status != StatusReady {
		return "", time.Time{}, ErrConflict
	}
	return service.store.PresignGet(key, service.downloadTTL)
}

func mediaFromReservation(mediaID, ownerID uuid.UUID, originalName, mimeType string, size int64, sha string, purpose Purpose, status Status, createdAt time.Time, readyAt *time.Time) MediaObject {
	return MediaObject{
		ID:             mediaID.String(),
		OwnerUserID:    ownerID.String(),
		OriginalName:   originalName,
		MIMEType:       mimeType,
		SizeBytes:      size,
		SHA256:         sha,
		Purpose:        purpose,
		Status:         status,
		EncryptionMode: "NONE",
		CreatedAt:      createdAt,
		ReadyAt:        readyAt,
	}
}
