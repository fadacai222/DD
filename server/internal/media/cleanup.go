package media

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const (
	defaultCleanupBatch = 100
	maxCleanupBatch     = 500
)

// CleanupExpiredUploads removes object-storage data and database reservations for
// uploads that were never completed before their reservation expired. READY media
// can never match this query, so cleanup cannot delete a message-visible object.
func (service *Service) CleanupExpiredUploads(ctx context.Context, limit int) (int, error) {
	if limit <= 0 {
		limit = defaultCleanupBatch
	}
	if limit > maxCleanupBatch {
		limit = maxCleanupBatch
	}

	rows, err := service.pool.Query(ctx, `
		SELECT u.id
		FROM media_uploads u
		JOIN media_objects m ON m.id=u.media_id
		WHERE u.completed_at IS NULL
		  AND u.expires_at <= $1
		  AND m.status='UPLOADING'
		ORDER BY u.expires_at, u.id
		LIMIT $2
	`, service.now().UTC(), limit)
	if err != nil {
		return 0, fmt.Errorf("list expired media uploads: %w", err)
	}
	var uploadIDs []uuid.UUID
	for rows.Next() {
		var uploadID uuid.UUID
		if err := rows.Scan(&uploadID); err != nil {
			rows.Close()
			return 0, fmt.Errorf("scan expired media upload: %w", err)
		}
		uploadIDs = append(uploadIDs, uploadID)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, fmt.Errorf("iterate expired media uploads: %w", err)
	}
	rows.Close()

	processed := 0
	var cleanupErr error
	for _, uploadID := range uploadIDs {
		removed, err := service.cleanupExpiredUpload(ctx, uploadID)
		if err != nil {
			cleanupErr = errors.Join(cleanupErr, err)
			continue
		}
		if removed {
			processed++
		}
	}
	return processed, cleanupErr
}

func (service *Service) CleanupOrphanedChatMedia(ctx context.Context, limit int, minimumAge time.Duration) (int, error) {
	if limit <= 0 {
		limit = defaultCleanupBatch
	}
	if limit > maxCleanupBatch {
		limit = maxCleanupBatch
	}
	if minimumAge < 24*time.Hour {
		minimumAge = 30 * 24 * time.Hour
	}
	cutoff := service.now().UTC().Add(-minimumAge)
	rows, err := service.pool.Query(ctx, `
		SELECT m.id
		FROM media_objects m
		WHERE m.purpose IN ('CHAT_IMAGE','CHAT_VIDEO','CHAT_FILE','CHAT_VOICE','GIF','STICKER','MOMENT_IMAGE','MOMENT_VIDEO')
		  AND m.status='READY'
		  AND m.created_at <= $1
		  AND m.deleted_at IS NULL
		  AND NOT EXISTS(SELECT 1 FROM telegram_sticker_items i WHERE i.media_id=m.id)
		  AND NOT EXISTS(SELECT 1 FROM custom_stickers c WHERE c.media_id=m.id AND c.deleted_at IS NULL)
		  AND NOT EXISTS(SELECT 1 FROM message_media mm WHERE mm.media_id=m.id)
		  AND NOT EXISTS(SELECT 1 FROM moment_media mmoment WHERE mmoment.media_id=m.id)
		ORDER BY m.created_at,m.id
		LIMIT $2
	`, cutoff, limit)
	if err != nil {
		return 0, fmt.Errorf("list orphaned managed stickers: %w", err)
	}
	var mediaIDs []uuid.UUID
	for rows.Next() {
		var mediaID uuid.UUID
		if err := rows.Scan(&mediaID); err != nil {
			rows.Close()
			return 0, fmt.Errorf("scan orphaned managed sticker: %w", err)
		}
		mediaIDs = append(mediaIDs, mediaID)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, fmt.Errorf("iterate orphaned managed stickers: %w", err)
	}
	rows.Close()

	processed := 0
	var cleanupErr error
	for _, mediaID := range mediaIDs {
		removed, err := service.cleanupOrphanedManagedSticker(ctx, mediaID, cutoff)
		if err != nil {
			cleanupErr = errors.Join(cleanupErr, err)
			continue
		}
		if removed {
			processed++
		}
	}
	return processed, cleanupErr
}

func (service *Service) cleanupOrphanedManagedSticker(ctx context.Context, mediaID uuid.UUID, cutoff time.Time) (bool, error) {
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return false, fmt.Errorf("begin managed sticker cleanup: %w", err)
	}
	defer tx.Rollback(ctx)

	var storageKey string
	err = tx.QueryRow(ctx, `
		SELECT m.storage_key
		FROM media_objects m
		WHERE m.id=$1
		  AND m.purpose IN ('CHAT_IMAGE','CHAT_VIDEO','CHAT_FILE','CHAT_VOICE','GIF','STICKER','MOMENT_IMAGE','MOMENT_VIDEO')
		  AND m.status='READY'
		  AND m.created_at <= $2
		  AND m.deleted_at IS NULL
		  AND NOT EXISTS(SELECT 1 FROM telegram_sticker_items i WHERE i.media_id=m.id)
		  AND NOT EXISTS(SELECT 1 FROM custom_stickers c WHERE c.media_id=m.id AND c.deleted_at IS NULL)
		  AND NOT EXISTS(SELECT 1 FROM message_media mm WHERE mm.media_id=m.id)
		  AND NOT EXISTS(SELECT 1 FROM moment_media mmoment WHERE mmoment.media_id=m.id)
		FOR UPDATE OF m
	`, mediaID, cutoff).Scan(&storageKey)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("lock orphaned managed sticker %s: %w", mediaID, err)
	}
	if err := service.store.Delete(ctx, storageKey); err != nil {
		return false, fmt.Errorf("delete orphaned managed sticker object %s: %w", mediaID, err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM media_objects WHERE id=$1`, mediaID); err != nil {
		return false, fmt.Errorf("delete orphaned managed sticker row %s: %w", mediaID, err)
	}
	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("commit managed sticker cleanup %s: %w", mediaID, err)
	}
	return true, nil
}

func (service *Service) cleanupExpiredUpload(ctx context.Context, uploadID uuid.UUID) (bool, error) {
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return false, fmt.Errorf("begin expired media cleanup: %w", err)
	}
	defer tx.Rollback(ctx)

	var mediaID uuid.UUID
	var storageKey string
	err = tx.QueryRow(ctx, `
		SELECT m.id,m.storage_key
		FROM media_uploads u
		JOIN media_objects m ON m.id=u.media_id
		WHERE u.id=$1
		  AND u.completed_at IS NULL
		  AND u.expires_at <= $2
		  AND m.status='UPLOADING'
		FOR UPDATE OF u,m
	`, uploadID, service.now().UTC()).Scan(&mediaID, &storageKey)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("lock expired media upload %s: %w", uploadID, err)
	}

	if err := service.store.Delete(ctx, storageKey); err != nil {
		return false, fmt.Errorf("delete expired media object %s: %w", mediaID, err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM media_objects WHERE id=$1 AND status='UPLOADING'`, mediaID); err != nil {
		return false, fmt.Errorf("delete expired media reservation %s: %w", mediaID, err)
	}
	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("commit expired media cleanup %s: %w", mediaID, err)
	}
	return true, nil
}
