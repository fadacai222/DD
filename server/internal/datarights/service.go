package datarights

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/auth/password"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrUnavailable        = errors.New("data rights service unavailable")
	ErrInvalidInput       = errors.New("invalid data rights request")
	ErrNotFound           = errors.New("data rights request not found")
	ErrNotReady           = errors.New("data export is not ready")
	ErrExpired            = errors.New("data export expired")
	ErrInvalidCredentials = errors.New("current password is invalid")
	ErrCancellationClosed = errors.New("account deletion can no longer be cancelled")
	ErrAccountNotActive   = errors.New("account is not active")
)

const (
	defaultCoolingOff     = 7 * 24 * time.Hour
	defaultExportTTL      = 7 * 24 * time.Hour
	defaultExportCooldown = 24 * time.Hour
	defaultDownloadTTL    = 5 * time.Minute
	jobLease              = 5 * time.Minute
)

type ArtifactStore interface {
	Put(ctx context.Context, key, contentType string, data []byte) error
	PresignGet(key string, ttl time.Duration) (string, time.Time, error)
	Delete(ctx context.Context, key string) error
}

type Config struct {
	Pool           *pgxpool.Pool
	Hasher         *password.Hasher
	Store          ArtifactStore
	Now            func() time.Time
	CoolingOff     time.Duration
	ExportTTL      time.Duration
	ExportCooldown time.Duration
	DownloadTTL    time.Duration
}

type Service struct {
	pool           *pgxpool.Pool
	hasher         *password.Hasher
	store          ArtifactStore
	now            func() time.Time
	coolingOff     time.Duration
	exportTTL      time.Duration
	exportCooldown time.Duration
	downloadTTL    time.Duration
}

func NewService(config Config) (*Service, error) {
	if config.Pool == nil || config.Hasher == nil {
		return nil, ErrUnavailable
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	coolingOff := config.CoolingOff
	if coolingOff <= 0 {
		coolingOff = defaultCoolingOff
	}
	exportTTL := config.ExportTTL
	if exportTTL <= 0 {
		exportTTL = defaultExportTTL
	}
	exportCooldown := config.ExportCooldown
	if exportCooldown <= 0 {
		exportCooldown = defaultExportCooldown
	}
	downloadTTL := config.DownloadTTL
	if downloadTTL <= 0 || downloadTTL > 15*time.Minute {
		downloadTTL = defaultDownloadTTL
	}
	return &Service{
		pool: config.Pool, hasher: config.Hasher, store: config.Store, now: now,
		coolingOff: coolingOff, exportTTL: exportTTL, exportCooldown: exportCooldown, downloadTTL: downloadTTL,
	}, nil
}

func normalizeIdempotencyKey(raw string) (string, error) {
	key := strings.TrimSpace(raw)
	if len(key) < 8 || len(key) > 128 {
		return "", ErrInvalidInput
	}
	for _, r := range key {
		if r < 0x21 || r > 0x7e {
			return "", ErrInvalidInput
		}
	}
	return key, nil
}

func (service *Service) RequestExport(ctx context.Context, principal account.Principal, rawIdempotencyKey string) (ExportRequest, error) {
	if service.store == nil {
		return ExportRequest{}, ErrUnavailable
	}
	key, err := normalizeIdempotencyKey(rawIdempotencyKey)
	if err != nil {
		return ExportRequest{}, err
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return ExportRequest{}, fmt.Errorf("begin export request: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, "data-export:"+principal.UserID.String()); err != nil {
		return ExportRequest{}, fmt.Errorf("lock export request: %w", err)
	}
	if result, found, err := loadExportByKey(ctx, tx, principal.UserID, key); err != nil {
		return ExportRequest{}, err
	} else if found {
		if err := tx.Commit(ctx); err != nil {
			return ExportRequest{}, err
		}
		return result, nil
	}
	if result, found, err := loadRecentExport(ctx, tx, principal.UserID, now.Add(-service.exportCooldown), now); err != nil {
		return ExportRequest{}, err
	} else if found {
		if err := tx.Commit(ctx); err != nil {
			return ExportRequest{}, err
		}
		return result, nil
	}
	var result ExportRequest
	if err := tx.QueryRow(ctx, `
		INSERT INTO data_export_requests(user_id,idempotency_key,status,requested_at,next_attempt_at)
		VALUES($1,$2,'QUEUED',$3,$3)
		RETURNING id,status,requested_at,started_at,completed_at,expires_at,artifact_size_bytes,COALESCE(artifact_sha256,''),true
	`, principal.UserID, key, now).Scan(
		&result.ID, &result.Status, &result.RequestedAt, &result.StartedAt, &result.CompletedAt,
		&result.ExpiresAt, &result.SizeBytes, &result.SHA256, &result.Retryable,
	); err != nil {
		return ExportRequest{}, fmt.Errorf("create export request: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO data_rights_audit_events(user_id,request_id,request_type,event_type,created_at)
		VALUES($1,$2,'EXPORT','REQUESTED',$3)
	`, principal.UserID, result.ID, now); err != nil {
		return ExportRequest{}, fmt.Errorf("audit export request: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return ExportRequest{}, fmt.Errorf("commit export request: %w", err)
	}
	return result, nil
}

func (service *Service) GetExport(ctx context.Context, principal account.Principal, requestID uuid.UUID) (ExportRequest, error) {
	var result ExportRequest
	var retryable bool
	err := service.pool.QueryRow(ctx, `
		SELECT id,status,requested_at,started_at,completed_at,expires_at,artifact_size_bytes,
		       COALESCE(artifact_sha256,''), status IN ('QUEUED','PROCESSING','FAILED')
		FROM data_export_requests WHERE id=$1 AND user_id=$2
	`, requestID, principal.UserID).Scan(
		&result.ID, &result.Status, &result.RequestedAt, &result.StartedAt, &result.CompletedAt,
		&result.ExpiresAt, &result.SizeBytes, &result.SHA256, &retryable,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return ExportRequest{}, ErrNotFound
	}
	if err != nil {
		return ExportRequest{}, fmt.Errorf("get export request: %w", err)
	}
	result.Retryable = retryable
	if result.Status == ExportCompleted && result.ExpiresAt != nil && !result.ExpiresAt.After(service.now().UTC()) {
		_, _ = service.pool.Exec(ctx, `UPDATE data_export_requests SET status='EXPIRED' WHERE id=$1 AND status='COMPLETED'`, requestID)
		result.Status = ExportExpired
		result.Retryable = false
	}
	return result, nil
}

func (service *Service) CreateExportDownload(ctx context.Context, principal account.Principal, requestID uuid.UUID) (ExportDownload, error) {
	if service.store == nil {
		return ExportDownload{}, ErrUnavailable
	}
	var status, objectKey, digest string
	var expiresAt time.Time
	var size int64
	err := service.pool.QueryRow(ctx, `
		SELECT status,COALESCE(artifact_object_key,''),COALESCE(expires_at,'epoch'::timestamptz),
		       COALESCE(artifact_size_bytes,0),COALESCE(artifact_sha256,'')
		FROM data_export_requests WHERE id=$1 AND user_id=$2
	`, requestID, principal.UserID).Scan(&status, &objectKey, &expiresAt, &size, &digest)
	if errors.Is(err, pgx.ErrNoRows) {
		return ExportDownload{}, ErrNotFound
	}
	if err != nil {
		return ExportDownload{}, fmt.Errorf("load export artifact: %w", err)
	}
	if status != ExportCompleted {
		if status == ExportExpired {
			return ExportDownload{}, ErrExpired
		}
		return ExportDownload{}, ErrNotReady
	}
	if !expiresAt.After(service.now().UTC()) {
		_, _ = service.pool.Exec(ctx, `UPDATE data_export_requests SET status='EXPIRED' WHERE id=$1 AND status='COMPLETED'`, requestID)
		return ExportDownload{}, ErrExpired
	}
	url, signedExpiresAt, err := service.store.PresignGet(objectKey, service.downloadTTL)
	if err != nil {
		return ExportDownload{}, fmt.Errorf("authorize export download: %w", err)
	}
	_, _ = service.pool.Exec(ctx, `
		INSERT INTO data_rights_audit_events(user_id,request_id,request_type,event_type,created_at)
		VALUES($1,$2,'EXPORT','DOWNLOAD_AUTHORIZED',$3)
	`, principal.UserID, requestID, service.now().UTC())
	return ExportDownload{
		DownloadURL: url, ExpiresAt: signedExpiresAt, FileName: "dd-data-export-" + requestID.String() + ".json.gz",
		SHA256: digest, SizeBytes: size,
	}, nil
}

func (service *Service) ProcessExportJobs(ctx context.Context, limit int) (int, error) {
	if service.store == nil {
		return 0, ErrUnavailable
	}
	if limit <= 0 || limit > 100 {
		limit = 10
	}
	processed := 0
	for processed < limit {
		requestID, userID, ok, err := service.claimExport(ctx)
		if err != nil {
			return processed, err
		}
		if !ok {
			break
		}
		artifact, err := service.buildExportArtifact(ctx, userID)
		if err == nil {
			key := fmt.Sprintf("data-exports/%s/%s/%s.json.gz", service.now().UTC().Format("2006/01"), userID.String(), requestID.String())
			err = service.store.Put(ctx, key, "application/gzip", artifact)
			if err == nil {
				digest := sha256.Sum256(artifact)
				now := service.now().UTC()
				_, err = service.pool.Exec(ctx, `
					UPDATE data_export_requests
					SET status='COMPLETED',completed_at=$2,expires_at=$3,artifact_object_key=$4,
					    artifact_size_bytes=$5,artifact_sha256=$6,lease_expires_at=NULL,last_error=NULL
					WHERE id=$1 AND status='PROCESSING'
				`, requestID, now, now.Add(service.exportTTL), key, int64(len(artifact)), hex.EncodeToString(digest[:]))
				if err == nil {
					_, _ = service.pool.Exec(ctx, `INSERT INTO data_rights_audit_events(user_id,request_id,request_type,event_type,created_at) VALUES($1,$2,'EXPORT','COMPLETED',$3)`, userID, requestID, now)
				}
			}
		}
		if err != nil {
			service.failExport(ctx, requestID, err)
		}
		processed++
	}
	return processed, nil
}

func (service *Service) CleanupExpiredExports(ctx context.Context, limit int) (int, error) {
	if service.store == nil {
		return 0, nil
	}
	if limit <= 0 || limit > 500 {
		limit = 50
	}
	rows, err := service.pool.Query(ctx, `
		SELECT id,user_id,artifact_object_key FROM data_export_requests
		WHERE status='COMPLETED' AND expires_at <= $1
		ORDER BY expires_at,id LIMIT $2
	`, service.now().UTC(), limit)
	if err != nil {
		return 0, fmt.Errorf("list expired exports: %w", err)
	}
	defer rows.Close()
	type expired struct {
		id, userID uuid.UUID
		key        string
	}
	items := make([]expired, 0, limit)
	for rows.Next() {
		var item expired
		if err := rows.Scan(&item.id, &item.userID, &item.key); err != nil {
			return 0, err
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	removed := 0
	for _, item := range items {
		if err := service.store.Delete(ctx, item.key); err != nil {
			continue
		}
		if _, err := service.pool.Exec(ctx, `
			UPDATE data_export_requests SET status='EXPIRED',artifact_object_key=NULL
			WHERE id=$1 AND status='COMPLETED'
		`, item.id); err != nil {
			return removed, err
		}
		removed++
	}
	return removed, nil
}

func (service *Service) RequestDeletion(ctx context.Context, principal account.Principal, input RequestDeletionInput, rawIdempotencyKey string) (DeletionRequest, error) {
	key, err := normalizeIdempotencyKey(rawIdempotencyKey)
	if err != nil {
		return DeletionRequest{}, err
	}
	if strings.TrimSpace(input.CurrentPassword) == "" {
		return DeletionRequest{}, ErrInvalidCredentials
	}
	verified, err := service.verifyPassword(ctx, principal.UserID, input.CurrentPassword)
	if err != nil {
		return DeletionRequest{}, err
	}
	if !verified {
		return DeletionRequest{}, ErrInvalidCredentials
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return DeletionRequest{}, fmt.Errorf("begin deletion request: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, "account-deletion:"+principal.UserID.String()); err != nil {
		return DeletionRequest{}, fmt.Errorf("lock deletion request: %w", err)
	}
	var userStatus string
	if err := tx.QueryRow(ctx, `SELECT status FROM users WHERE id=$1 FOR UPDATE`, principal.UserID).Scan(&userStatus); errors.Is(err, pgx.ErrNoRows) {
		return DeletionRequest{}, ErrAccountNotActive
	} else if err != nil {
		return DeletionRequest{}, err
	}
	if userStatus != "ACTIVE" {
		return DeletionRequest{}, ErrAccountNotActive
	}
	if result, found, err := loadDeletionByKey(ctx, tx, principal.UserID, key); err != nil {
		return DeletionRequest{}, err
	} else if found {
		if err := tx.Commit(ctx); err != nil {
			return DeletionRequest{}, err
		}
		return result, nil
	}
	if result, found, err := loadActiveDeletion(ctx, tx, principal.UserID); err != nil {
		return DeletionRequest{}, err
	} else if found {
		if err := tx.Commit(ctx); err != nil {
			return DeletionRequest{}, err
		}
		return result, nil
	}
	coolingUntil := now.Add(service.coolingOff)
	var id uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO account_deletion_requests(user_id,request_device_id,idempotency_key,status,requested_at,cooling_off_until,next_attempt_at)
		VALUES($1,$2,$3,'REQUESTED',$4,$5,$5) RETURNING id
	`, principal.UserID, principal.DeviceID, key, now, coolingUntil).Scan(&id); err != nil {
		return DeletionRequest{}, fmt.Errorf("create account deletion: %w", err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO data_rights_audit_events(user_id,request_id,request_type,event_type,created_at) VALUES($1,$2,'ACCOUNT_DELETION','REQUESTED',$3)`, principal.UserID, id, now); err != nil {
		return DeletionRequest{}, err
	}
	if _, err := tx.Exec(ctx, `UPDATE account_deletion_requests SET status='COOLING_OFF' WHERE id=$1`, id); err != nil {
		return DeletionRequest{}, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO data_rights_audit_events(user_id,request_id,request_type,event_type,created_at) VALUES($1,$2,'ACCOUNT_DELETION','COOLING_OFF_STARTED',$3)`, principal.UserID, id, now); err != nil {
		return DeletionRequest{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return DeletionRequest{}, err
	}
	return service.GetDeletion(ctx, principal, id)
}

func (service *Service) GetDeletion(ctx context.Context, principal account.Principal, requestID uuid.UUID) (DeletionRequest, error) {
	return service.getDeletionForUser(ctx, principal.UserID, requestID)
}

func (service *Service) CancelDeletion(ctx context.Context, principal account.Principal, requestID uuid.UUID) (DeletionRequest, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return DeletionRequest{}, err
	}
	defer tx.Rollback(ctx)
	var status string
	var coolingUntil time.Time
	err = tx.QueryRow(ctx, `
		SELECT status,cooling_off_until FROM account_deletion_requests
		WHERE id=$1 AND user_id=$2 FOR UPDATE
	`, requestID, principal.UserID).Scan(&status, &coolingUntil)
	if errors.Is(err, pgx.ErrNoRows) {
		return DeletionRequest{}, ErrNotFound
	}
	if err != nil {
		return DeletionRequest{}, err
	}
	if status == DeletionCancelled {
		if err := tx.Commit(ctx); err != nil {
			return DeletionRequest{}, err
		}
		return service.getDeletionForUser(ctx, principal.UserID, requestID)
	}
	if (status != DeletionRequested && status != DeletionCoolingOff) || !coolingUntil.After(now) {
		return DeletionRequest{}, ErrCancellationClosed
	}
	if _, err := tx.Exec(ctx, `UPDATE account_deletion_requests SET status='CANCELLED',cancelled_at=$2,lease_expires_at=NULL WHERE id=$1`, requestID, now); err != nil {
		return DeletionRequest{}, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO data_rights_audit_events(user_id,request_id,request_type,event_type,created_at) VALUES($1,$2,'ACCOUNT_DELETION','CANCELLED',$3)`, principal.UserID, requestID, now); err != nil {
		return DeletionRequest{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return DeletionRequest{}, err
	}
	return service.getDeletionForUser(ctx, principal.UserID, requestID)
}

func (service *Service) ProcessDeletionJobs(ctx context.Context, limit int) (int, error) {
	if limit <= 0 || limit > 100 {
		limit = 10
	}
	processed := 0
	for processed < limit {
		requestID, userID, ok, err := service.claimDeletion(ctx)
		if err != nil {
			return processed, err
		}
		if !ok {
			break
		}
		if err := service.executeDeletionDatabase(ctx, requestID, userID); err != nil {
			service.failDeletion(ctx, requestID, err)
			processed++
			continue
		}
		if err := service.processObjectDeletions(ctx, requestID); err != nil {
			service.failDeletion(ctx, requestID, err)
			processed++
			continue
		}
		if err := service.completeDeletion(ctx, requestID, userID); err != nil {
			service.failDeletion(ctx, requestID, err)
		}
		processed++
	}
	return processed, nil
}

func (service *Service) verifyPassword(ctx context.Context, userID uuid.UUID, rawPassword string) (bool, error) {
	var encoded string
	err := service.pool.QueryRow(ctx, `
		SELECT p.password_hash FROM auth_passwords p JOIN users u ON u.id=p.user_id
		WHERE p.user_id=$1 AND u.status='ACTIVE'
	`, userID).Scan(&encoded)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrAccountNotActive
	}
	if err != nil {
		return false, fmt.Errorf("load current password: %w", err)
	}
	result, err := service.hasher.Verify(encoded, rawPassword)
	if err != nil {
		return false, fmt.Errorf("verify current password: %w", err)
	}
	return result.Match, nil
}

func (service *Service) claimExport(ctx context.Context) (uuid.UUID, uuid.UUID, bool, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return uuid.Nil, uuid.Nil, false, err
	}
	defer tx.Rollback(ctx)
	var requestID, userID uuid.UUID
	err = tx.QueryRow(ctx, `
		SELECT id,user_id FROM data_export_requests
		WHERE (
			(status IN ('QUEUED','FAILED') AND next_attempt_at <= $1)
			OR (status='PROCESSING' AND lease_expires_at <= $1)
		)
		ORDER BY next_attempt_at,requested_at,id
		FOR UPDATE SKIP LOCKED LIMIT 1
	`, now).Scan(&requestID, &userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, uuid.Nil, false, nil
	}
	if err != nil {
		return uuid.Nil, uuid.Nil, false, err
	}
	if _, err := tx.Exec(ctx, `
		UPDATE data_export_requests SET status='PROCESSING',started_at=COALESCE(started_at,$2),
		attempt_count=attempt_count+1,lease_expires_at=$3,last_error=NULL WHERE id=$1
	`, requestID, now, now.Add(jobLease)); err != nil {
		return uuid.Nil, uuid.Nil, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return uuid.Nil, uuid.Nil, false, err
	}
	return requestID, userID, true, nil
}

func (service *Service) failExport(ctx context.Context, requestID uuid.UUID, cause error) {
	now := service.now().UTC()
	var attempts int
	_ = service.pool.QueryRow(ctx, `SELECT attempt_count FROM data_export_requests WHERE id=$1`, requestID).Scan(&attempts)
	backoff := retryBackoff(attempts)
	_, _ = service.pool.Exec(ctx, `
		UPDATE data_export_requests SET status='FAILED',next_attempt_at=$2,lease_expires_at=NULL,last_error=$3 WHERE id=$1
	`, requestID, now.Add(backoff), truncateError(cause))
}

func (service *Service) buildExportArtifact(ctx context.Context, userID uuid.UUID) ([]byte, error) {
	now := service.now().UTC()
	sections := map[string]json.RawMessage{}
	queries := map[string]string{
		"profile": `SELECT jsonb_build_object(
			'id',u.id,'email',u.email_normalized,'handle',u.handle_normalized,'displayName',u.display_name,'bio',u.bio,
			'createdAt',u.created_at,'updatedAt',u.updated_at,
			'privacy',jsonb_build_object('allowEmailSearch',p.allow_email_search,'allowStrangerMessages',p.allow_stranger_messages,
			'showOnlineStatus',p.show_online_status,'readReceiptsEnabled',p.read_receipts_enabled,'notificationPreviewEnabled',p.notification_preview_enabled)
		) FROM users u JOIN user_privacy_settings p ON p.user_id=u.id WHERE u.id=$1`,
		"contacts": `SELECT COALESCE(jsonb_agg(jsonb_build_object(
			'userId',c.contact_user_id,'handle',u.handle_normalized,'displayName',u.display_name,'remark',c.remark,
			'isStarred',c.is_starred,'createdAt',c.created_at,'updatedAt',c.updated_at) ORDER BY c.created_at,c.contact_user_id),'[]'::jsonb)
			FROM contacts c JOIN users u ON u.id=c.contact_user_id WHERE c.owner_user_id=$1`,
		"groups": `SELECT COALESCE(jsonb_agg(jsonb_build_object(
			'conversationId',g.conversation_id,'name',g.name,'announcement',g.announcement,'joinMode',g.join_mode,'status',g.status,
			'myRole',mine.role,'joinedAt',mine.joined_at,
			'members',(SELECT COALESCE(jsonb_agg(jsonb_build_object('userId',cm.user_id,'role',cm.role,'status',cm.status,'joinedAt',cm.joined_at,'leftAt',cm.left_at) ORDER BY cm.joined_at,cm.user_id),'[]'::jsonb) FROM conversation_members cm WHERE cm.conversation_id=g.conversation_id)
		) ORDER BY g.created_at,g.conversation_id),'[]'::jsonb)
		FROM conversation_members mine JOIN groups g ON g.conversation_id=mine.conversation_id
		WHERE mine.user_id=$1 AND mine.status='ACTIVE'`,
		"messages": `SELECT COALESCE(jsonb_agg(jsonb_build_object(
			'id',m.id,'conversationId',m.conversation_id,'sequence',m.sequence,'senderUserId',m.sender_user_id,
			'type',m.type,'content',m.content_json,'createdAt',m.created_at,'recalledAt',m.recalled_at,'deletedAt',m.deleted_at
		) ORDER BY m.conversation_id,m.sequence),'[]'::jsonb)
		FROM messages m JOIN conversation_members mine ON mine.conversation_id=m.conversation_id AND mine.user_id=$1 AND mine.status='ACTIVE'
		WHERE NOT EXISTS(SELECT 1 FROM message_local_deletions d WHERE d.user_id=$1 AND d.message_id=m.id)`,
		"moments": `SELECT jsonb_build_object(
			'authored',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',m.id,'text',m.text,'visibility',m.visibility,'status',m.status,'createdAt',m.created_at,'deletedAt',m.deleted_at) ORDER BY m.created_at,m.id) FROM moments m WHERE m.author_user_id=$1),'[]'::jsonb),
			'likes',COALESCE((SELECT jsonb_agg(jsonb_build_object('momentId',l.moment_id,'createdAt',l.created_at) ORDER BY l.created_at,l.moment_id) FROM moment_likes l WHERE l.user_id=$1),'[]'::jsonb),
			'comments',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',c.id,'momentId',c.moment_id,'replyToCommentId',c.reply_to_comment_id,'text',c.text,'createdAt',c.created_at,'deletedAt',c.deleted_at) ORDER BY c.created_at,c.id) FROM moment_comments c WHERE c.author_user_id=$1),'[]'::jsonb)
		)`,
		"stickers": `SELECT jsonb_build_object(
			'custom',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',s.id,'mediaId',s.media_id,'mimeType',s.mime_type,'sizeBytes',s.size_bytes,'sortOrder',s.sort_order,'createdAt',s.created_at) ORDER BY s.sort_order,s.created_at,s.id) FROM custom_stickers s WHERE s.owner_user_id=$1),'[]'::jsonb),
			'packs',COALESCE((SELECT jsonb_agg(jsonb_build_object('packId',usp.pack_id,'setName',p.set_name,'title',p.title,'sortOrder',usp.sort_order,'createdAt',usp.created_at) ORDER BY usp.sort_order,usp.created_at,usp.pack_id) FROM user_sticker_packs usp JOIN telegram_sticker_packs p ON p.id=usp.pack_id WHERE usp.user_id=$1),'[]'::jsonb)
		)`,
		"devices":                 `SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'name',name,'platform',platform,'appVersion',app_version,'isVerified',is_verified,'createdAt',created_at,'lastSeenAt',last_seen_at,'revokedAt',revoked_at) ORDER BY created_at,id),'[]'::jsonb) FROM devices WHERE user_id=$1`,
		"notificationPreferences": `SELECT COALESCE((SELECT to_jsonb(p)-'user_id' FROM user_notification_preferences p WHERE p.user_id=$1),'{}'::jsonb)`,
		"pushEndpoints":           `SELECT COALESCE(jsonb_agg(jsonb_build_object('id',e.id,'deviceId',e.device_id,'provider',e.provider,'appId',e.app_id,'environment',e.environment,'status',e.status,'createdAt',e.created_at,'updatedAt',e.updated_at) ORDER BY e.created_at,e.id),'[]'::jsonb) FROM device_push_endpoints e JOIN devices d ON d.id=e.device_id WHERE d.user_id=$1`,
	}
	order := []string{"profile", "contacts", "groups", "messages", "moments", "stickers", "devices", "notificationPreferences", "pushEndpoints"}
	for _, name := range order {
		var raw []byte
		if err := service.pool.QueryRow(ctx, queries[name], userID).Scan(&raw); err != nil {
			return nil, fmt.Errorf("export %s: %w", name, err)
		}
		if !json.Valid(raw) {
			return nil, fmt.Errorf("export %s returned invalid json", name)
		}
		sections[name] = append(json.RawMessage(nil), raw...)
	}
	payload := struct {
		FormatVersion string                     `json:"formatVersion"`
		GeneratedAt   time.Time                  `json:"generatedAt"`
		Scope         []string                   `json:"scope"`
		Data          map[string]json.RawMessage `json:"data"`
	}{
		FormatVersion: "1", GeneratedAt: now,
		Scope: []string{"profile", "contacts", "groups/member relationship", "messages", "moments", "sticker metadata", "devices", "notification preferences", "push endpoint metadata"},
		Data:  sections,
	}
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	encoder := json.NewEncoder(writer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(payload); err != nil {
		_ = writer.Close()
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return compressed.Bytes(), nil
}

func (service *Service) claimDeletion(ctx context.Context) (uuid.UUID, uuid.UUID, bool, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return uuid.Nil, uuid.Nil, false, err
	}
	defer tx.Rollback(ctx)
	var requestID, userID uuid.UUID
	err = tx.QueryRow(ctx, `
		SELECT id,user_id FROM account_deletion_requests
		WHERE cooling_off_until <= $1 AND (
			(status IN ('REQUESTED','COOLING_OFF','FAILED') AND next_attempt_at <= $1)
			OR (status='EXECUTING' AND lease_expires_at <= $1)
		)
		ORDER BY next_attempt_at,requested_at,id FOR UPDATE SKIP LOCKED LIMIT 1
	`, now).Scan(&requestID, &userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, uuid.Nil, false, nil
	}
	if err != nil {
		return uuid.Nil, uuid.Nil, false, err
	}
	if _, err := tx.Exec(ctx, `
		UPDATE account_deletion_requests SET status='EXECUTING',execution_started_at=COALESCE(execution_started_at,$2),
		attempt_count=attempt_count+1,lease_expires_at=$3,last_error=NULL,failed_at=NULL WHERE id=$1
	`, requestID, now, now.Add(jobLease)); err != nil {
		return uuid.Nil, uuid.Nil, false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE users SET status='DELETING',updated_at=$2 WHERE id=$1 AND status IN ('ACTIVE','DELETING')`, userID, now); err != nil {
		return uuid.Nil, uuid.Nil, false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE devices SET revoked_at=COALESCE(revoked_at,$2) WHERE user_id=$1`, userID, now); err != nil {
		return uuid.Nil, uuid.Nil, false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE refresh_tokens SET revoked_at=COALESCE(revoked_at,$2),revoke_reason=COALESCE(revoke_reason,'ACCOUNT_DELETION') WHERE user_id=$1`, userID, now); err != nil {
		return uuid.Nil, uuid.Nil, false, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM device_push_endpoints e USING devices d WHERE e.device_id=d.id AND d.user_id=$1`, userID); err != nil {
		return uuid.Nil, uuid.Nil, false, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO data_rights_audit_events(user_id,request_id,request_type,event_type,created_at) VALUES($1,$2,'ACCOUNT_DELETION','EXECUTION_STARTED',$3)`, userID, requestID, now); err != nil {
		return uuid.Nil, uuid.Nil, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return uuid.Nil, uuid.Nil, false, err
	}
	return requestID, userID, true, nil
}

func (service *Service) executeDeletionDatabase(ctx context.Context, requestID, userID uuid.UUID) error {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var email string
	if err := tx.QueryRow(ctx, `SELECT email_normalized FROM users WHERE id=$1 AND status IN ('DELETING','DELETED') FOR UPDATE`, userID).Scan(&email); err != nil {
		return fmt.Errorf("lock deleting user: %w", err)
	}
	// End active 1:1/group calls before revoking the user's remaining live presence.
	if _, err := tx.Exec(ctx, `UPDATE calls SET status='ended',ended_at=$2,end_reason='account_deleted',version=version+1 WHERE (caller_user_id=$1 OR callee_user_id=$1) AND status IN ('ringing','accepted')`, userID, now); err != nil {
		return fmt.Errorf("end calls: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE group_call_participants SET left_at=COALESCE(left_at,$2) WHERE user_id=$1 AND left_at IS NULL`, userID, now); err != nil {
		return fmt.Errorf("leave group calls: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE group_call_sessions SET status='ENDED',ended_at=$2 WHERE started_by_user_id=$1 AND status='ACTIVE'`, userID, now); err != nil {
		return fmt.Errorf("end owned group calls: %w", err)
	}

	// Transfer each active group ownership to an active admin/member. Dissolve only when no successor exists.
	rows, err := tx.Query(ctx, `SELECT conversation_id FROM conversation_members WHERE user_id=$1 AND role='OWNER' AND status='ACTIVE' FOR UPDATE`, userID)
	if err != nil {
		return fmt.Errorf("list owned groups: %w", err)
	}
	owned := make([]uuid.UUID, 0)
	for rows.Next() {
		var id uuid.UUID
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		owned = append(owned, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, conversationID := range owned {
		var successor uuid.UUID
		err := tx.QueryRow(ctx, `
			SELECT user_id FROM conversation_members
			WHERE conversation_id=$1 AND user_id<>$2 AND status='ACTIVE'
			ORDER BY CASE role WHEN 'ADMIN' THEN 0 ELSE 1 END, joined_at, user_id LIMIT 1 FOR UPDATE
		`, conversationID, userID).Scan(&successor)
		if errors.Is(err, pgx.ErrNoRows) {
			if _, err := tx.Exec(ctx, `UPDATE groups SET status='DISSOLVED',dissolved_at=COALESCE(dissolved_at,$2),updated_at=$2 WHERE conversation_id=$1 AND status='ACTIVE'`, conversationID, now); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `UPDATE conversation_members SET status='REMOVED',left_at=COALESCE(left_at,$2),role='MEMBER' WHERE conversation_id=$1 AND status='ACTIVE'`, conversationID, now); err != nil {
				return err
			}
		} else if err != nil {
			return err
		} else {
			if _, err := tx.Exec(ctx, `UPDATE conversation_members SET role='OWNER' WHERE conversation_id=$1 AND user_id=$2 AND status='ACTIVE'`, conversationID, successor); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `UPDATE conversation_members SET role='MEMBER',status='REMOVED',left_at=COALESCE(left_at,$3) WHERE conversation_id=$1 AND user_id=$2`, conversationID, userID, now); err != nil {
				return err
			}
		}
	}

	// Remove private/self-only material; shared messages remain for other conversation members under an anonymized sender identity.
	if _, err := tx.Exec(ctx, `DELETE FROM conversations c USING conversation_members cm WHERE c.id=cm.conversation_id AND c.type='SELF' AND cm.user_id=$1`, userID); err != nil {
		return fmt.Errorf("delete self conversations: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE conversation_members SET role='MEMBER',status='REMOVED',left_at=COALESCE(left_at,$2),muted_until=NULL,is_pinned=false WHERE user_id=$1 AND status='ACTIVE'`, userID, now); err != nil {
		return fmt.Errorf("leave conversations: %w", err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM contacts WHERE owner_user_id=$1 OR contact_user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM contact_requests WHERE sender_user_id=$1 OR receiver_user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM blocks WHERE owner_user_id=$1 OR blocked_user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM relationship_rate_events WHERE user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM group_join_requests WHERE requester_user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE group_join_requests SET resolved_by_user_id=NULL WHERE resolved_by_user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE qr_login_sessions SET status='EXPIRED' WHERE scanned_user_id=$1 AND status IN ('SCANNED','CONFIRMED')`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE group_qr_invites SET revoked_at=COALESCE(revoked_at,$2) WHERE created_by_user_id=$1`, userID, now); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM moment_activity_notifications WHERE recipient_user_id=$1 OR actor_user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM moment_likes WHERE user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM moment_comments WHERE author_user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM moment_relationship_preferences WHERE owner_user_id=$1 OR target_user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM moments WHERE author_user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM custom_stickers WHERE owner_user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM user_sticker_packs WHERE user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM sticker_rate_events WHERE user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM profile_avatars WHERE user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE users SET avatar_media_id=NULL,moment_cover_media_id=NULL,moment_cover_revision=0 WHERE id=$1`, userID); err != nil {
		return err
	}

	// Account deletion invalidates all export jobs and physically removes any generated export artifact.
	if _, err := tx.Exec(ctx, `
		INSERT INTO data_rights_object_deletions(deletion_request_id,media_id,object_key,created_at,next_attempt_at)
		SELECT $2,NULL,artifact_object_key,$3,$3 FROM data_export_requests
		WHERE user_id=$1 AND artifact_object_key IS NOT NULL
		ON CONFLICT(deletion_request_id,object_key) DO NOTHING
	`, userID, requestID, now); err != nil {
		return fmt.Errorf("queue data export artifacts: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE data_export_requests
		SET status='EXPIRED',artifact_object_key=NULL,lease_expires_at=NULL,last_error=NULL
		WHERE user_id=$1 AND status<>'EXPIRED'
	`, userID); err != nil {
		return fmt.Errorf("expire data exports: %w", err)
	}

	// Queue physical deletion only for objects that are no longer needed by a shared message/group/sticker-pack reference.
	if _, err := tx.Exec(ctx, `
		INSERT INTO data_rights_object_deletions(deletion_request_id,media_id,object_key,created_at,next_attempt_at)
		SELECT $2,mo.id,mo.storage_key,$3,$3 FROM media_objects mo
		WHERE mo.owner_user_id=$1
		  AND NOT EXISTS(SELECT 1 FROM message_media mm WHERE mm.media_id=mo.id)
		  AND NOT EXISTS(SELECT 1 FROM groups g WHERE g.avatar_media_id=mo.id)
		  AND NOT EXISTS(SELECT 1 FROM telegram_sticker_items tsi WHERE tsi.media_id=mo.id)
		ON CONFLICT(deletion_request_id,object_key) DO NOTHING
	`, userID, requestID, now); err != nil {
		return fmt.Errorf("queue media objects: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO data_rights_object_deletions(deletion_request_id,media_id,object_key,created_at,next_attempt_at)
		SELECT $2,mv.media_id,mv.storage_key,$3,$3 FROM media_variants mv JOIN media_objects mo ON mo.id=mv.media_id
		WHERE mo.owner_user_id=$1
		  AND NOT EXISTS(SELECT 1 FROM message_media mm WHERE mm.media_id=mo.id)
		  AND NOT EXISTS(SELECT 1 FROM groups g WHERE g.avatar_media_id=mo.id)
		  AND NOT EXISTS(SELECT 1 FROM telegram_sticker_items tsi WHERE tsi.media_id=mo.id)
		ON CONFLICT(deletion_request_id,object_key) DO NOTHING
	`, userID, requestID, now); err != nil {
		return fmt.Errorf("queue media variants: %w", err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM media_uploads WHERE owner_user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		DELETE FROM media_objects mo
		WHERE owner_user_id=$1
		  AND NOT EXISTS(SELECT 1 FROM message_media mm WHERE mm.media_id=mo.id)
		  AND NOT EXISTS(SELECT 1 FROM groups g WHERE g.avatar_media_id=mo.id)
		  AND NOT EXISTS(SELECT 1 FROM telegram_sticker_items tsi WHERE tsi.media_id=mo.id)
	`, userID); err != nil {
		return fmt.Errorf("delete private media metadata: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE media_objects SET owner_user_id=NULL,original_name='shared-media' WHERE owner_user_id=$1`, userID); err != nil {
		return fmt.Errorf("anonymize shared media: %w", err)
	}

	if _, err := tx.Exec(ctx, `DELETE FROM user_notification_preferences WHERE user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM device_push_endpoints e USING devices d WHERE e.device_id=d.id AND d.user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM push_jobs WHERE recipient_user_id=$1 OR actor_user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM sync_events WHERE user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM outbox_events WHERE target_user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM message_mentions WHERE mentioned_user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM message_local_deletions WHERE user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM saved_messages WHERE user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM user_privacy_settings WHERE user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM auth_passwords WHERE user_id=$1`, userID); err != nil {
		return err
	}
	if !strings.HasPrefix(email, "deleted-") {
		if _, err := tx.Exec(ctx, `DELETE FROM email_codes WHERE email_normalized=$1`, email); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM auth_login_attempts WHERE email_normalized=$1`, email); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, `DELETE FROM refresh_tokens WHERE user_id=$1`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		UPDATE devices SET name='Deleted device',app_version='',identity_public_key=NULL,identity_key_algorithm=NULL,identity_key_version=NULL,
		is_verified=false,revoked_at=COALESCE(revoked_at,$2) WHERE user_id=$1
	`, userID, now); err != nil {
		return fmt.Errorf("anonymize devices: %w", err)
	}
	anon := strings.ReplaceAll(userID.String(), "-", "")
	handle := "deleted_" + anon[:24]
	anonEmail := "deleted-" + userID.String() + "@invalid.dd"
	if _, err := tx.Exec(ctx, `
		UPDATE users SET email_normalized=$2,handle_normalized=$3,display_name='Deleted Account',bio='',updated_at=$4
		WHERE id=$1
	`, userID, anonEmail, handle, now); err != nil {
		return fmt.Errorf("anonymize user: %w", err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO data_rights_audit_events(user_id,request_id,request_type,event_type,detail,created_at) VALUES($1,$2,'ACCOUNT_DELETION','BUSINESS_DATA_ANONYMIZED',jsonb_build_object('retained','legal_audit_and_shared_conversation_records'),$3)`, userID, requestID, now); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit account data cleanup: %w", err)
	}
	return nil
}

func (service *Service) processObjectDeletions(ctx context.Context, requestID uuid.UUID) error {
	var pending int
	if err := service.pool.QueryRow(ctx, `SELECT count(*) FROM data_rights_object_deletions WHERE deletion_request_id=$1 AND status<>'COMPLETED'`, requestID).Scan(&pending); err != nil {
		return err
	}
	if pending == 0 {
		return nil
	}
	if service.store == nil {
		return errors.New("object storage unavailable for account deletion")
	}
	rows, err := service.pool.Query(ctx, `SELECT id,object_key,attempt_count FROM data_rights_object_deletions WHERE deletion_request_id=$1 AND status<>'COMPLETED' ORDER BY created_at,id`, requestID)
	if err != nil {
		return err
	}
	type item struct {
		id       uuid.UUID
		key      string
		attempts int
	}
	items := make([]item, 0, pending)
	for rows.Next() {
		var v item
		if err := rows.Scan(&v.id, &v.key, &v.attempts); err != nil {
			rows.Close()
			return err
		}
		items = append(items, v)
	}
	rows.Close()
	for _, v := range items {
		_, _ = service.pool.Exec(ctx, `UPDATE data_rights_object_deletions SET status='PROCESSING',attempt_count=attempt_count+1 WHERE id=$1`, v.id)
		if err := service.store.Delete(ctx, v.key); err != nil {
			_, _ = service.pool.Exec(ctx, `UPDATE data_rights_object_deletions SET status='FAILED',next_attempt_at=$2,last_error=$3 WHERE id=$1`, v.id, service.now().UTC().Add(retryBackoff(v.attempts+1)), truncateError(err))
			return fmt.Errorf("delete private object: %w", err)
		}
		_, err := service.pool.Exec(ctx, `UPDATE data_rights_object_deletions SET status='COMPLETED',completed_at=$2,last_error=NULL WHERE id=$1`, v.id, service.now().UTC())
		if err != nil {
			return err
		}
	}
	return nil
}

func (service *Service) completeDeletion(ctx context.Context, requestID, userID uuid.UUID) error {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var remaining int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM data_rights_object_deletions WHERE deletion_request_id=$1 AND status<>'COMPLETED'`, requestID).Scan(&remaining); err != nil {
		return err
	}
	if remaining != 0 {
		return errors.New("private object deletion is incomplete")
	}
	if _, err := tx.Exec(ctx, `UPDATE users SET status='DELETED',deleted_at=COALESCE(deleted_at,$2),updated_at=$2 WHERE id=$1 AND status='DELETING'`, userID, now); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE account_deletion_requests SET status='COMPLETED',completed_at=$2,lease_expires_at=NULL,last_error=NULL WHERE id=$1 AND status='EXECUTING'`, requestID, now); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO data_rights_audit_events(user_id,request_id,request_type,event_type,created_at) VALUES($1,$2,'ACCOUNT_DELETION','COMPLETED',$3)`, userID, requestID, now); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (service *Service) failDeletion(ctx context.Context, requestID uuid.UUID, cause error) {
	now := service.now().UTC()
	var attempts int
	_ = service.pool.QueryRow(ctx, `SELECT attempt_count FROM account_deletion_requests WHERE id=$1`, requestID).Scan(&attempts)
	_, _ = service.pool.Exec(ctx, `
		UPDATE account_deletion_requests SET status='FAILED',failed_at=$2,next_attempt_at=$3,lease_expires_at=NULL,last_error=$4 WHERE id=$1
	`, requestID, now, now.Add(retryBackoff(attempts)), truncateError(cause))
}

func (service *Service) getDeletionForUser(ctx context.Context, userID, requestID uuid.UUID) (DeletionRequest, error) {
	var result DeletionRequest
	var retryable bool
	err := service.pool.QueryRow(ctx, `
		SELECT id,status,requested_at,cooling_off_until,execution_started_at,completed_at,cancelled_at,failed_at,
		       status IN ('REQUESTED','COOLING_OFF','EXECUTING','FAILED')
		FROM account_deletion_requests WHERE id=$1 AND user_id=$2
	`, requestID, userID).Scan(&result.ID, &result.Status, &result.RequestedAt, &result.CoolingOffUntil, &result.ExecutionStarted, &result.CompletedAt, &result.CancelledAt, &result.FailedAt, &retryable)
	if errors.Is(err, pgx.ErrNoRows) {
		return DeletionRequest{}, ErrNotFound
	}
	if err != nil {
		return DeletionRequest{}, err
	}
	result.Retryable = retryable
	return result, nil
}

func loadExportByKey(ctx context.Context, tx pgx.Tx, userID uuid.UUID, key string) (ExportRequest, bool, error) {
	return scanExportRow(tx.QueryRow(ctx, `
		SELECT id,status,requested_at,started_at,completed_at,expires_at,artifact_size_bytes,COALESCE(artifact_sha256,''),status IN ('QUEUED','PROCESSING','FAILED')
		FROM data_export_requests WHERE user_id=$1 AND idempotency_key=$2
	`, userID, key))
}

func loadRecentExport(ctx context.Context, tx pgx.Tx, userID uuid.UUID, since, now time.Time) (ExportRequest, bool, error) {
	return scanExportRow(tx.QueryRow(ctx, `
		SELECT id,status,requested_at,started_at,completed_at,expires_at,artifact_size_bytes,COALESCE(artifact_sha256,''),status IN ('QUEUED','PROCESSING','FAILED')
		FROM data_export_requests WHERE user_id=$1 AND requested_at >= $2 AND status IN ('QUEUED','PROCESSING','COMPLETED','FAILED')
		  AND (expires_at IS NULL OR expires_at > $3)
		ORDER BY requested_at DESC,id DESC LIMIT 1
	`, userID, since, now))
}

func scanExportRow(row pgx.Row) (ExportRequest, bool, error) {
	var result ExportRequest
	err := row.Scan(&result.ID, &result.Status, &result.RequestedAt, &result.StartedAt, &result.CompletedAt, &result.ExpiresAt, &result.SizeBytes, &result.SHA256, &result.Retryable)
	if errors.Is(err, pgx.ErrNoRows) {
		return ExportRequest{}, false, nil
	}
	if err != nil {
		return ExportRequest{}, false, err
	}
	return result, true, nil
}

func loadDeletionByKey(ctx context.Context, tx pgx.Tx, userID uuid.UUID, key string) (DeletionRequest, bool, error) {
	return scanDeletionRow(tx.QueryRow(ctx, `
		SELECT id,status,requested_at,cooling_off_until,execution_started_at,completed_at,cancelled_at,failed_at,status IN ('REQUESTED','COOLING_OFF','EXECUTING','FAILED')
		FROM account_deletion_requests WHERE user_id=$1 AND idempotency_key=$2
	`, userID, key))
}

func loadActiveDeletion(ctx context.Context, tx pgx.Tx, userID uuid.UUID) (DeletionRequest, bool, error) {
	return scanDeletionRow(tx.QueryRow(ctx, `
		SELECT id,status,requested_at,cooling_off_until,execution_started_at,completed_at,cancelled_at,failed_at,true
		FROM account_deletion_requests WHERE user_id=$1 AND status IN ('REQUESTED','COOLING_OFF','EXECUTING','FAILED')
		ORDER BY requested_at DESC,id DESC LIMIT 1
	`, userID))
}

func scanDeletionRow(row pgx.Row) (DeletionRequest, bool, error) {
	var result DeletionRequest
	err := row.Scan(&result.ID, &result.Status, &result.RequestedAt, &result.CoolingOffUntil, &result.ExecutionStarted, &result.CompletedAt, &result.CancelledAt, &result.FailedAt, &result.Retryable)
	if errors.Is(err, pgx.ErrNoRows) {
		return DeletionRequest{}, false, nil
	}
	if err != nil {
		return DeletionRequest{}, false, err
	}
	return result, true, nil
}

func retryBackoff(attempt int) time.Duration {
	if attempt < 1 {
		attempt = 1
	}
	if attempt > 8 {
		attempt = 8
	}
	return time.Duration(1<<uint(attempt-1)) * 15 * time.Second
}

func truncateError(err error) string {
	if err == nil {
		return ""
	}
	value := err.Error()
	if len(value) > 1000 {
		value = value[:1000]
	}
	return value
}
