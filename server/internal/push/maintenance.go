package push

import (
	"context"
	"fmt"
	"time"
)

// CleanupInvalidEndpoints physically removes provider tokens that have already been
// quarantined as INVALID for the retention period. INVALID endpoints are excluded
// from delivery immediately; this cleanup only controls long-term database growth.
func (service *Service) CleanupInvalidEndpoints(ctx context.Context, limit int, retention time.Duration) (int64, error) {
	if limit == 0 {
		limit = 200
	}
	if limit < 1 || limit > 1000 || retention < 24*time.Hour {
		return 0, ErrInvalidInput
	}
	cutoff := service.now().UTC().Add(-retention)
	command, err := service.pool.Exec(ctx, `
		WITH expired AS (
			SELECT id
			FROM device_push_endpoints
			WHERE status='INVALID' AND updated_at < $1
			ORDER BY updated_at, id
			LIMIT $2
		)
		DELETE FROM device_push_endpoints e
		USING expired
		WHERE e.id=expired.id
	`, cutoff, limit)
	if err != nil {
		return 0, fmt.Errorf("cleanup invalid push endpoints: %w", err)
	}
	return command.RowsAffected(), nil
}
