package media

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	defaultUploadTTL           = 10 * time.Minute
	defaultDownloadTTL         = 5 * time.Minute
	maxActiveUploadsPerUser    = 32
	maxReservedUploadBytesUser = int64(512 * 1024 * 1024)
)

type Service struct {
	pool        *pgxpool.Pool
	store       ObjectStore
	httpClient  *http.Client
	now         func() time.Time
	uploadTTL   time.Duration
	downloadTTL time.Duration
}

type Config struct {
	Pool        *pgxpool.Pool
	Store       ObjectStore
	HTTPClient  *http.Client
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
	httpClient := config.HTTPClient
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 30 * time.Second}
	}
	return &Service{
		pool:        config.Pool,
		store:       config.Store,
		httpClient:  httpClient,
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

// CancelUpload releases an unfinished upload reservation immediately. Clients call
// this on failed/retried/cancelled transfers so transient failures cannot consume
// the per-user active-upload quota for the full reservation TTL.
func (service *Service) CancelUpload(ctx context.Context, principal account.Principal, uploadID uuid.UUID) error {
	if uploadID == uuid.Nil {
		return ErrInvalidInput
	}
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("begin media upload cancel: %w", err)
	}
	defer tx.Rollback(ctx)

	var mediaID uuid.UUID
	var storageKey string
	err = tx.QueryRow(ctx, `
		SELECT m.id,m.storage_key
		FROM media_uploads u
		JOIN media_objects m ON m.id=u.media_id
		WHERE u.id=$1 AND u.owner_user_id=$2
		  AND u.completed_at IS NULL
		  AND m.status='UPLOADING'
		FOR UPDATE OF u,m
	`, uploadID, principal.UserID).Scan(&mediaID, &storageKey)
	if errors.Is(err, pgx.ErrNoRows) {
		// A completion response can be lost after the server committed READY.
		// Treat an already-finalized own reservation as an idempotent no-op, but
		// keep unknown/foreign upload IDs indistinguishable from not found.
		var own bool
		if lookupErr := tx.QueryRow(ctx, `
			SELECT EXISTS(
				SELECT 1 FROM media_uploads WHERE id=$1 AND owner_user_id=$2
			)
		`, uploadID, principal.UserID).Scan(&own); lookupErr != nil {
			return fmt.Errorf("check media upload cancel ownership: %w", lookupErr)
		}
		if own {
			return tx.Commit(ctx)
		}
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("lock media upload cancel: %w", err)
	}

	if err := service.store.Delete(ctx, storageKey); err != nil {
		return fmt.Errorf("delete canceled media object %s: %w", mediaID, err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM media_objects WHERE id=$1 AND status='UPLOADING'`, mediaID); err != nil {
		return fmt.Errorf("delete canceled media reservation %s: %w", mediaID, err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit media upload cancel: %w", err)
	}
	return nil
}

func (service *Service) ImportManagedSticker(ctx context.Context, input ManagedStickerInput) (MediaObject, error) {
	if len(input.Bytes) == 0 {
		return MediaObject{}, ErrInvalidInput
	}
	digest := sha256.Sum256(input.Bytes)
	validated := normalizeUploadInput(CreateUploadInput{
		FileName: input.FileName,
		Size:     int64(len(input.Bytes)),
		MIMEType: input.MIMEType,
		SHA256:   hex.EncodeToString(digest[:]),
		Purpose:  PurposeSticker,
	})
	if err := validateUploadInput(validated); err != nil {
		return MediaObject{}, err
	}
	key, err := newStorageKey(PurposeSticker)
	if err != nil {
		return MediaObject{}, fmt.Errorf("generate managed sticker storage key: %w", err)
	}
	uploadURL, requiredHeaders, _, err := service.store.PresignPut(
		key,
		validated.MIMEType,
		validated.SHA256,
		service.uploadTTL,
	)
	if err != nil {
		return MediaObject{}, fmt.Errorf("presign managed sticker upload: %w", err)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPut, uploadURL, bytes.NewReader(input.Bytes))
	if err != nil {
		return MediaObject{}, fmt.Errorf("create managed sticker upload request: %w", err)
	}
	for name, value := range requiredHeaders {
		request.Header.Set(name, value)
	}
	response, err := service.httpClient.Do(request)
	if err != nil {
		return MediaObject{}, fmt.Errorf("upload managed sticker: %w", err)
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
	response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return MediaObject{}, fmt.Errorf("upload managed sticker: storage returned %d", response.StatusCode)
	}
	removeObject := true
	defer func() {
		if removeObject {
			_ = service.store.Delete(context.Background(), key)
		}
	}()
	objectInfo, err := service.store.Stat(ctx, key)
	if err != nil {
		return MediaObject{}, fmt.Errorf("verify managed sticker: %w", err)
	}
	if objectInfo.Size != validated.Size ||
		!strings.EqualFold(strings.TrimSpace(objectInfo.ContentType), validated.MIMEType) ||
		!strings.EqualFold(strings.TrimSpace(objectInfo.SHA256), validated.SHA256) {
		return MediaObject{}, ErrObjectMismatch
	}
	now := service.now().UTC()
	mediaID := uuid.New()
	if _, err := service.pool.Exec(ctx, `
		INSERT INTO media_objects(
			id,owner_user_id,storage_key,original_name,mime_type,size_bytes,sha256,purpose,status,encryption_mode,created_at,ready_at
		)
		VALUES($1,NULL,$2,$3,$4,$5,$6,'STICKER','READY','NONE',$7,$7)
	`, mediaID, key, validated.FileName, validated.MIMEType, validated.Size, validated.SHA256, now); err != nil {
		return MediaObject{}, fmt.Errorf("persist managed sticker: %w", err)
	}
	removeObject = false
	return MediaObject{
		ID:             mediaID.String(),
		OriginalName:   validated.FileName,
		MIMEType:       validated.MIMEType,
		SizeBytes:      validated.Size,
		SHA256:         validated.SHA256,
		Purpose:        PurposeSticker,
		Status:         StatusReady,
		EncryptionMode: "NONE",
		CreatedAt:      now,
		ReadyAt:        &now,
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
	var ownerID string
	var purpose Purpose
	var status Status
	var canAccess bool
	err := service.pool.QueryRow(ctx, `
		SELECT m.id,COALESCE(m.owner_user_id::text,''),m.original_name,m.mime_type,m.size_bytes,m.sha256,m.purpose,m.status,m.encryption_mode,m.created_at,m.ready_at,
		       (m.owner_user_id=$2 OR EXISTS(
				SELECT 1
				FROM message_media mm
				JOIN messages msg ON msg.id=mm.message_id AND msg.deleted_at IS NULL AND msg.recalled_at IS NULL
				JOIN conversation_members cm ON cm.conversation_id=msg.conversation_id AND cm.user_id=$2 AND cm.status='ACTIVE'
				LEFT JOIN message_local_deletions ld ON ld.message_id=msg.id AND ld.user_id=$2
				WHERE mm.media_id=m.id AND ld.message_id IS NULL
		   ) OR EXISTS(
				SELECT 1 FROM custom_stickers cs
				WHERE cs.owner_user_id=$2 AND cs.media_id=m.id AND cs.deleted_at IS NULL
		   ) OR EXISTS(
				SELECT 1
				FROM telegram_sticker_items tsi
				JOIN user_sticker_packs usp ON usp.pack_id=tsi.pack_id AND usp.user_id=$2
				WHERE tsi.media_id=m.id
		   ) OR EXISTS(
				SELECT 1
				FROM groups gavatar
				JOIN conversation_members gmember ON gmember.conversation_id=gavatar.conversation_id
				WHERE gavatar.avatar_media_id=m.id AND gavatar.status='ACTIVE'
				  AND gmember.user_id=$2 AND gmember.status='ACTIVE'
		   ) OR EXISTS(
				SELECT 1 FROM users cover_user
				WHERE cover_user.moment_cover_media_id=m.id AND cover_user.status='ACTIVE' AND (
				  cover_user.id=$2 OR (
				    EXISTS(SELECT 1 FROM contacts c WHERE c.owner_user_id=$2 AND c.contact_user_id=cover_user.id)
				    AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.owner_user_id=$2 AND b.blocked_user_id=cover_user.id) OR (b.owner_user_id=cover_user.id AND b.blocked_user_id=$2))
				    AND NOT EXISTS(SELECT 1 FROM moment_relationship_preferences p WHERE p.owner_user_id=$2 AND p.target_user_id=cover_user.id AND p.hide_target=true)
				    AND NOT EXISTS(SELECT 1 FROM moment_relationship_preferences p WHERE p.owner_user_id=cover_user.id AND p.target_user_id=$2 AND p.hide_from_target=true)
				  )
				)
		   ) OR EXISTS(
				SELECT 1 FROM moment_media mmoment
				JOIN moments moment ON moment.id=mmoment.moment_id AND moment.status='ACTIVE'
				WHERE mmoment.media_id=m.id AND (
				  moment.author_user_id=$2 OR (
				    EXISTS(SELECT 1 FROM contacts c WHERE c.owner_user_id=$2 AND c.contact_user_id=moment.author_user_id)
				    AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.owner_user_id=$2 AND b.blocked_user_id=moment.author_user_id) OR (b.owner_user_id=moment.author_user_id AND b.blocked_user_id=$2))
				    AND NOT EXISTS(SELECT 1 FROM moment_relationship_preferences p WHERE p.owner_user_id=$2 AND p.target_user_id=moment.author_user_id AND p.hide_target=true)
				    AND NOT EXISTS(SELECT 1 FROM moment_relationship_preferences p WHERE p.owner_user_id=moment.author_user_id AND p.target_user_id=$2 AND p.hide_from_target=true)
				    AND (moment.visibility='ALL_CONTACTS'
				      OR (moment.visibility='PRIVATE' AND EXISTS(SELECT 1 FROM moment_visibility_users v WHERE v.moment_id=moment.id AND v.user_id=$2 AND v.mode='INCLUDED'))
				      OR (moment.visibility='EXCLUDE' AND NOT EXISTS(SELECT 1 FROM moment_visibility_users v WHERE v.moment_id=moment.id AND v.user_id=$2 AND v.mode='EXCLUDED')))
				  )
				)
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
	result.OwnerUserID = ownerID
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
		   ) OR EXISTS(
				SELECT 1 FROM custom_stickers cs
				WHERE cs.owner_user_id=$2 AND cs.media_id=m.id AND cs.deleted_at IS NULL
		   ) OR EXISTS(
				SELECT 1
				FROM telegram_sticker_items tsi
				JOIN user_sticker_packs usp ON usp.pack_id=tsi.pack_id AND usp.user_id=$2
				WHERE tsi.media_id=m.id
		   ) OR EXISTS(
				SELECT 1
				FROM groups gavatar
				JOIN conversation_members gmember ON gmember.conversation_id=gavatar.conversation_id
				WHERE gavatar.avatar_media_id=m.id AND gavatar.status='ACTIVE'
				  AND gmember.user_id=$2 AND gmember.status='ACTIVE'
		   ) OR EXISTS(
				SELECT 1 FROM users cover_user
				WHERE cover_user.moment_cover_media_id=m.id AND cover_user.status='ACTIVE' AND (
				  cover_user.id=$2 OR (
				    EXISTS(SELECT 1 FROM contacts c WHERE c.owner_user_id=$2 AND c.contact_user_id=cover_user.id)
				    AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.owner_user_id=$2 AND b.blocked_user_id=cover_user.id) OR (b.owner_user_id=cover_user.id AND b.blocked_user_id=$2))
				    AND NOT EXISTS(SELECT 1 FROM moment_relationship_preferences p WHERE p.owner_user_id=$2 AND p.target_user_id=cover_user.id AND p.hide_target=true)
				    AND NOT EXISTS(SELECT 1 FROM moment_relationship_preferences p WHERE p.owner_user_id=cover_user.id AND p.target_user_id=$2 AND p.hide_from_target=true)
				  )
				)
		   ) OR EXISTS(
				SELECT 1 FROM moment_media mmoment
				JOIN moments moment ON moment.id=mmoment.moment_id AND moment.status='ACTIVE'
				WHERE mmoment.media_id=m.id AND (
				  moment.author_user_id=$2 OR (
				    EXISTS(SELECT 1 FROM contacts c WHERE c.owner_user_id=$2 AND c.contact_user_id=moment.author_user_id)
				    AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.owner_user_id=$2 AND b.blocked_user_id=moment.author_user_id) OR (b.owner_user_id=moment.author_user_id AND b.blocked_user_id=$2))
				    AND NOT EXISTS(SELECT 1 FROM moment_relationship_preferences p WHERE p.owner_user_id=$2 AND p.target_user_id=moment.author_user_id AND p.hide_target=true)
				    AND NOT EXISTS(SELECT 1 FROM moment_relationship_preferences p WHERE p.owner_user_id=moment.author_user_id AND p.target_user_id=$2 AND p.hide_from_target=true)
				    AND (moment.visibility='ALL_CONTACTS'
				      OR (moment.visibility='PRIVATE' AND EXISTS(SELECT 1 FROM moment_visibility_users v WHERE v.moment_id=moment.id AND v.user_id=$2 AND v.mode='INCLUDED'))
				      OR (moment.visibility='EXCLUDE' AND NOT EXISTS(SELECT 1 FROM moment_visibility_users v WHERE v.moment_id=moment.id AND v.user_id=$2 AND v.mode='EXCLUDED')))
				  )
				)
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
