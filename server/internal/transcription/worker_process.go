package transcription

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const jobLease = 3 * time.Minute
const maxProviderAttempts = 3

type claimedJob struct {
	ID uuid.UUID
	MessageID uuid.UUID
	RequesterID uuid.UUID
	Attempts int
}

func (service *Service) ProcessJobs(ctx context.Context, limit int) (int, error) {
	if !service.ProviderAvailable() { return 0, nil }
	if limit <= 0 || limit > 20 { limit = 2 }
	processed := 0
	for processed < limit {
		job, ok, err := service.claim(ctx)
		if err != nil { return processed, err }
		if !ok { break }
		processed++
		service.runClaimed(ctx, job)
	}
	return processed, nil
}

func (service *Service) claim(ctx context.Context) (claimedJob, bool, error) {
	now := service.now().UTC()
	var job claimedJob
	err := service.pool.QueryRow(ctx, `
		WITH candidate AS (
			SELECT id FROM voice_transcriptions
			WHERE (status='PENDING' AND available_at<=$1) OR (status='RUNNING' AND lease_expires_at<=$1)
			ORDER BY available_at,created_at,id FOR UPDATE SKIP LOCKED LIMIT 1
		)
		UPDATE voice_transcriptions job
		SET status='RUNNING',attempts=attempts+1,started_at=COALESCE(started_at,$1),lease_expires_at=$2,updated_at=$1
		FROM candidate WHERE job.id=candidate.id
		RETURNING job.id,job.message_id,job.requested_by_user_id,job.attempts
	`, now, now.Add(jobLease)).Scan(&job.ID, &job.MessageID, &job.RequesterID, &job.Attempts)
	if errors.Is(err, pgx.ErrNoRows) { return claimedJob{}, false, nil }
	if err != nil { return claimedJob{}, false, fmt.Errorf("claim voice transcription: %w", err) }
	return job, true, nil
}

func (service *Service) finishRetry(ctx context.Context, job claimedJob, category string) {
	if job.Attempts >= maxProviderAttempts {
		service.finishFailure(ctx, job, category, true)
		return
	}
	now := service.now().UTC()
	_, _ = service.pool.Exec(ctx, `
		UPDATE voice_transcriptions
		SET status='PENDING',error_category=$2,retryable=true,available_at=$3,lease_expires_at=NULL,updated_at=$4,completed_at=NULL
		WHERE id=$1 AND status='RUNNING'
	`, job.ID, category, now.Add(5*time.Second), now)
}

func (service *Service) finishFailure(ctx context.Context, job claimedJob, category string, retryable bool) {
	now := service.now().UTC()
	_, _ = service.pool.Exec(ctx, `
		UPDATE voice_transcriptions
		SET status='FAILED',transcript=NULL,error_category=$2,retryable=$3,lease_expires_at=NULL,updated_at=$4,completed_at=$4
		WHERE id=$1 AND status='RUNNING'
	`, job.ID, category, retryable, now)
}
