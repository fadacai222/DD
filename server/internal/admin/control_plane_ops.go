package admin

import (
	"context"
	"fmt"
)

func (service *Service) StorageSnapshot(ctx context.Context, _ Principal) (StorageSnapshot, error) {
	now := service.now().UTC()
	snapshot := StorageSnapshot{GeneratedAt: now}
	if err := service.pool.QueryRow(ctx, `
		SELECT
			count(*) FILTER (WHERE status='READY'),
			COALESCE(sum(size_bytes) FILTER (WHERE status='READY'),0),
			count(*) FILTER (WHERE status='UPLOADING'),
			count(*) FILTER (WHERE status='FAILED'),
			count(*) FILTER (WHERE status='QUARANTINED'),
			count(*) FILTER (WHERE status='DELETED'),
			(SELECT count(*) FROM media_uploads WHERE completed_at IS NULL AND expires_at < $1)
		FROM media_objects
	`, now).Scan(
		&snapshot.ReadyObjects, &snapshot.ReadyBytes, &snapshot.UploadingObjects, &snapshot.FailedObjects,
		&snapshot.QuarantinedObjects, &snapshot.DeletedObjects, &snapshot.ExpiredIncompleteUploads,
	); err != nil {
		return StorageSnapshot{}, fmt.Errorf("load admin storage summary: %w", err)
	}
	rows, err := service.pool.Query(ctx, `
		SELECT purpose,count(*),COALESCE(sum(size_bytes),0)
		FROM media_objects WHERE status='READY'
		GROUP BY purpose ORDER BY sum(size_bytes) DESC,purpose
	`)
	if err != nil {
		return StorageSnapshot{}, fmt.Errorf("load admin storage buckets: %w", err)
	}
	defer rows.Close()
	snapshot.ByPurpose = make([]StorageBucket, 0)
	for rows.Next() {
		var item StorageBucket
		if err := rows.Scan(&item.Purpose, &item.ObjectCount, &item.Bytes); err != nil {
			return StorageSnapshot{}, fmt.Errorf("scan admin storage bucket: %w", err)
		}
		snapshot.ByPurpose = append(snapshot.ByPurpose, item)
	}
	if err := rows.Err(); err != nil {
		return StorageSnapshot{}, fmt.Errorf("iterate admin storage buckets: %w", err)
	}
	return snapshot, nil
}

func (service *Service) PushSnapshot(ctx context.Context, _ Principal) (PushSnapshot, error) {
	now := service.now().UTC()
	snapshot := PushSnapshot{GeneratedAt: now}
	if err := service.pool.QueryRow(ctx, `
		SELECT
			count(*) FILTER (WHERE status='PENDING'),
			count(*) FILTER (WHERE status='PENDING' AND attempts > 0),
			count(*) FILTER (WHERE status='SENT' AND sent_at >= $1::timestamptz - interval '24 hours'),
			count(*) FILTER (WHERE status='DROPPED' AND created_at >= $1::timestamptz - interval '24 hours'),
			min(created_at) FILTER (WHERE status='PENDING')
		FROM push_jobs
	`, now).Scan(&snapshot.PendingJobs, &snapshot.RetryingJobs, &snapshot.SentJobs24h, &snapshot.DroppedJobs24h, &snapshot.OldestPendingAt); err != nil {
		return PushSnapshot{}, fmt.Errorf("load admin push queue summary: %w", err)
	}
	if err := service.pool.QueryRow(ctx, `
		SELECT count(*) FROM device_push_endpoints WHERE last_failure_at >= $1::timestamptz - interval '24 hours'
	`, now).Scan(&snapshot.EndpointFailures24h); err != nil {
		return PushSnapshot{}, fmt.Errorf("load admin push endpoint failures: %w", err)
	}
	rows, err := service.pool.Query(ctx, `
		SELECT provider,status,count(*) FROM device_push_endpoints
		GROUP BY provider,status ORDER BY provider,status
	`)
	if err != nil {
		return PushSnapshot{}, fmt.Errorf("load admin push endpoint buckets: %w", err)
	}
	defer rows.Close()
	snapshot.Endpoints = make([]PushEndpointBucket, 0)
	for rows.Next() {
		var item PushEndpointBucket
		if err := rows.Scan(&item.Provider, &item.Status, &item.Count); err != nil {
			return PushSnapshot{}, fmt.Errorf("scan admin push endpoint bucket: %w", err)
		}
		snapshot.Endpoints = append(snapshot.Endpoints, item)
	}
	if err := rows.Err(); err != nil {
		return PushSnapshot{}, fmt.Errorf("iterate admin push endpoint buckets: %w", err)
	}
	return snapshot, nil
}

func (service *Service) RTCSnapshot(ctx context.Context, _ Principal) (RTCSnapshot, error) {
	now := service.now().UTC()
	snapshot := RTCSnapshot{GeneratedAt: now}
	if err := service.pool.QueryRow(ctx, `
		SELECT
			count(*) FILTER (WHERE created_at >= date_trunc('day',$1::timestamptz)),
			count(*) FILTER (WHERE status IN ('ringing','accepted')),
			count(*) FILTER (WHERE accepted_at >= $1 - interval '24 hours'),
			COALESCE(avg(EXTRACT(EPOCH FROM (ended_at-accepted_at))) FILTER (WHERE accepted_at IS NOT NULL AND ended_at IS NOT NULL AND ended_at >= $1 - interval '24 hours'),0)
		FROM calls
	`, now).Scan(&snapshot.DirectCallsToday, &snapshot.ActiveDirectCalls, &snapshot.AcceptedDirectCalls24h, &snapshot.AverageDirectSeconds24h); err != nil {
		return RTCSnapshot{}, fmt.Errorf("load admin direct call stats: %w", err)
	}
	if err := service.pool.QueryRow(ctx, `
		SELECT
			count(*) FILTER (WHERE started_at >= date_trunc('day',$1::timestamptz)),
			count(*) FILTER (WHERE status='ACTIVE'),
			(SELECT count(*) FROM group_call_participants p JOIN group_call_sessions s ON s.id=p.session_id WHERE s.status='ACTIVE' AND p.left_at IS NULL)
		FROM group_call_sessions
	`, now).Scan(&snapshot.GroupCallsToday, &snapshot.ActiveGroupCalls, &snapshot.ActiveGroupParticipants); err != nil {
		return RTCSnapshot{}, fmt.Errorf("load admin group call stats: %w", err)
	}
	return snapshot, nil
}
