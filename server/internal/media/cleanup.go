package media

import (
	"context"
	"errors"
	"fmt"

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
