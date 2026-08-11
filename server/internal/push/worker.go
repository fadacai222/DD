package push

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type pushJob struct {
	ID              uuid.UUID
	RecipientUserID uuid.UUID
	EventType       string
	ResourceID      *uuid.UUID
	ConversationID  *uuid.UUID
	ActorUserID     *uuid.UUID
	Payload         []byte
	Attempts        int
}

type endpointDelivery struct {
	ID           uuid.UUID
	Provider     string
	Endpoint     string
	AppID        string
	Environment  string
	FailureCount int
}

func (service *Service) DispatchJobs(ctx context.Context, providers Providers, limit int) (int, error) {
	if limit == 0 {
		limit = 100
	}
	if limit < 1 || limit > 500 {
		return 0, ErrInvalidInput
	}
	processed := 0
	for processed < limit {
		didWork, err := service.dispatchOneJob(ctx, providers)
		if err != nil {
			return processed, err
		}
		if !didWork {
			break
		}
		processed++
	}
	return processed, nil
}

func (service *Service) dispatchOneJob(ctx context.Context, providers Providers) (bool, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return false, fmt.Errorf("begin push dispatch: %w", err)
	}
	defer tx.Rollback(ctx)

	var job pushJob
	err = tx.QueryRow(ctx, `
		SELECT id,recipient_user_id,event_type,resource_id,conversation_id,actor_user_id,payload_json,attempts
		FROM push_jobs
		WHERE status='PENDING' AND available_at<=$1
		ORDER BY available_at,created_at,id
		FOR UPDATE SKIP LOCKED
		LIMIT 1
	`, now).Scan(&job.ID, &job.RecipientUserID, &job.EventType, &job.ResourceID, &job.ConversationID, &job.ActorUserID, &job.Payload, &job.Attempts)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("claim push job: %w", err)
	}
	if service.observer != nil {
		service.observer.PushJobStarted()
		defer service.observer.PushJobFinished()
	}

	var pushEnabled bool
	var previewMode string
	if err := tx.QueryRow(ctx, `
		SELECT COALESCE(p.push_enabled,true),COALESCE(p.preview_mode,'SENDER_ONLY')
		FROM users u
		LEFT JOIN user_notification_preferences p ON p.user_id=u.id
		WHERE u.id=$1 AND u.status='ACTIVE'
	`, job.RecipientUserID).Scan(&pushEnabled, &previewMode); errors.Is(err, pgx.ErrNoRows) {
		return service.dropJob(ctx, tx, job.ID, "RECIPIENT_INACTIVE", now)
	} else if err != nil {
		return false, fmt.Errorf("load push recipient preferences: %w", err)
	}
	if !pushEnabled {
		return service.dropJob(ctx, tx, job.ID, "PUSH_DISABLED", now)
	}
	if job.ActorUserID != nil && *job.ActorUserID == job.RecipientUserID {
		return service.dropJob(ctx, tx, job.ID, "SELF_EVENT", now)
	}

	baseDelivery, suppressed, err := service.buildDelivery(ctx, tx, job, previewMode, now)
	if err != nil {
		return service.deferJob(ctx, tx, job, err, now)
	}
	if suppressed {
		return service.dropJob(ctx, tx, job.ID, "SUPPRESSED", now)
	}

	rows, err := tx.Query(ctx, `
		SELECT e.id,e.provider,e.endpoint,e.app_id,e.environment,e.failure_count
		FROM device_push_endpoints e
		JOIN devices d ON d.id=e.device_id
		WHERE d.user_id=$1 AND d.revoked_at IS NULL AND e.status='ACTIVE'
		ORDER BY e.id
	`, job.RecipientUserID)
	if err != nil {
		return false, fmt.Errorf("load push endpoints: %w", err)
	}
	endpoints := make([]endpointDelivery, 0, 4)
	for rows.Next() {
		var endpoint endpointDelivery
		if err := rows.Scan(&endpoint.ID, &endpoint.Provider, &endpoint.Endpoint, &endpoint.AppID, &endpoint.Environment, &endpoint.FailureCount); err != nil {
			rows.Close()
			return false, fmt.Errorf("scan push endpoint: %w", err)
		}
		endpoints = append(endpoints, endpoint)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return false, fmt.Errorf("iterate push endpoints: %w", err)
	}
	if len(endpoints) == 0 {
		return service.dropJob(ctx, tx, job.ID, "NO_ACTIVE_ENDPOINT", now)
	}

	providerMissing := false
	providerAuthFailure := false
	retryableFailure := false
	successes := 0
	for _, endpoint := range endpoints {
		provider := providers.For(endpoint.Provider)
		if provider == nil {
			providerMissing = true
			if service.observer != nil {
				service.observer.ObservePushProvider(endpoint.Provider, "unconfigured", 0)
			}
			continue
		}
		delivery := baseDelivery
		delivery.EndpointID = endpoint.ID.String()
		delivery.Provider = endpoint.Provider
		delivery.Endpoint = endpoint.Endpoint
		delivery.AppID = endpoint.AppID
		delivery.Environment = endpoint.Environment
		providerStarted := time.Now()
		result, sendErr := provider.Send(ctx, delivery)
		if service.observer != nil {
			service.observer.ObservePushProvider(endpoint.Provider, providerMetricResult(endpoint.Provider, result, sendErr), time.Since(providerStarted))
		}
		if sendErr == nil {
			successes++
			if _, err := tx.Exec(ctx, `
				UPDATE device_push_endpoints
				SET status='ACTIVE',failure_count=0,last_success_at=$2,last_failure_at=NULL,last_failure_code=NULL,updated_at=$2
				WHERE id=$1
			`, endpoint.ID, now); err != nil {
				return false, fmt.Errorf("record push endpoint success: %w", err)
			}
			_ = result
			continue
		}
		failureCode := classifyProviderFailure(sendErr)
		if result.InvalidToken {
			if _, err := tx.Exec(ctx, `
				UPDATE device_push_endpoints
				SET status='INVALID',failure_count=failure_count+1,last_failure_at=$2,last_failure_code=$3,updated_at=$2
				WHERE id=$1
			`, endpoint.ID, now, failureCode); err != nil {
				return false, fmt.Errorf("invalidate push endpoint: %w", err)
			}
			continue
		}
		if isProviderAuthFailure(endpoint.Provider, sendErr) {
			providerAuthFailure = true
			continue
		}
		if errors.Is(sendErr, ErrRetryable) {
			retryableFailure = true
			continue
		}
		// FCM/APNs adapters explicitly identify invalid device tokens. Other
		// permanent provider errors are payload/app/provider configuration faults,
		// so they must not poison otherwise valid device endpoints. UnifiedPush
		// uses a per-device capability URL, where repeated permanent 4xx failures
		// are endpoint-specific and may still disable that endpoint.
		if endpoint.Provider != ProviderUnifiedPush {
			continue
		}
		if _, err := tx.Exec(ctx, `
			UPDATE device_push_endpoints
			SET failure_count=failure_count+1,last_failure_at=$2,last_failure_code=$3,updated_at=$2,
			    status=CASE WHEN failure_count+1>=10 THEN 'DISABLED' ELSE status END
			WHERE id=$1
		`, endpoint.ID, now, failureCode); err != nil {
			return false, fmt.Errorf("record push endpoint failure: %w", err)
		}
	}

	if successes > 0 {
		if _, err := tx.Exec(ctx, `UPDATE push_jobs SET status='SENT',attempts=attempts+1,sent_at=$2,last_error=NULL WHERE id=$1`, job.ID, now); err != nil {
			return false, fmt.Errorf("mark push job sent: %w", err)
		}
		if err := tx.Commit(ctx); err != nil {
			return false, fmt.Errorf("commit push success: %w", err)
		}
		return true, nil
	}
	if providerMissing || providerAuthFailure || retryableFailure {
		return service.deferJob(ctx, tx, job, ErrProviderUnavailable, now)
	}
	return service.dropJob(ctx, tx, job.ID, "ALL_ENDPOINTS_FAILED", now)
}

func (service *Service) buildDelivery(ctx context.Context, tx pgx.Tx, job pushJob, previewMode string, now time.Time) (Delivery, bool, error) {
	data := map[string]string{"eventType": job.EventType}
	if job.ResourceID != nil {
		data["resourceId"] = job.ResourceID.String()
	}
	if job.ConversationID != nil {
		data["conversationId"] = job.ConversationID.String()
	}
	delivery := Delivery{
		EventType:    job.EventType,
		Data:         data,
		CollapseKey:  "event:" + job.EventType,
		HighPriority: strings.Contains(job.EventType, "CALL"),
	}
	if job.ResourceID != nil {
		delivery.ResourceID = job.ResourceID.String()
	}
	if job.ConversationID != nil {
		delivery.ConversationID = job.ConversationID.String()
		delivery.CollapseKey = "conversation:" + job.ConversationID.String()
	}

	switch job.EventType {
	case "PUSH_TEST":
		var payload struct {
			Title string `json:"title"`
			Body  string `json:"body"`
		}
		if err := json.Unmarshal(job.Payload, &payload); err != nil {
			return Delivery{}, false, fmt.Errorf("decode push test payload: %w", err)
		}
		delivery.Title = payload.Title
		delivery.Body = payload.Body
		return delivery, false, nil
	case "MESSAGE_CREATED":
		if job.ResourceID == nil {
			return Delivery{}, false, errors.New("message push job missing resource id")
		}
		var senderID uuid.UUID
		var senderName, messageType string
		var content []byte
		var mutedUntil *time.Time
		if err := tx.QueryRow(ctx, `
			SELECT m.sender_user_id,u.display_name,m.type,m.content_json,cm.muted_until
			FROM messages m
			JOIN users u ON u.id=m.sender_user_id
			JOIN conversation_members cm ON cm.conversation_id=m.conversation_id AND cm.user_id=$2 AND cm.status='ACTIVE'
			WHERE m.id=$1 AND m.deleted_at IS NULL
		`, *job.ResourceID, job.RecipientUserID).Scan(&senderID, &senderName, &messageType, &content, &mutedUntil); errors.Is(err, pgx.ErrNoRows) {
			return delivery, true, nil
		} else if err != nil {
			return Delivery{}, false, fmt.Errorf("load message push preview: %w", err)
		}
		if senderID == job.RecipientUserID {
			return delivery, true, nil
		}
		if mutedUntil != nil && mutedUntil.After(now) {
			return delivery, true, nil
		}
		delivery.Data["senderUserId"] = senderID.String()
		delivery.Title, delivery.Body = renderPreview(previewMode, senderName, messageType, content)
		if normalizePreviewMode(previewMode) != PreviewHidden {
			if avatarURL := SignedAvatarURL(
				service.publicBaseURL,
				service.avatarTokenSecret,
				senderID,
				now.Add(24*time.Hour),
			); avatarURL != "" {
				delivery.Data["avatarUrl"] = avatarURL
			}
		}
		return delivery, false, nil
	case "GROUP_CALL_STARTED":
		if job.ResourceID == nil {
			return Delivery{}, false, errors.New("group call push missing group id")
		}
		var groupName string
		if err := tx.QueryRow(ctx, `SELECT name FROM groups WHERE id=$1 AND dissolved_at IS NULL`, *job.ResourceID).Scan(&groupName); errors.Is(err, pgx.ErrNoRows) {
			return delivery, true, nil
		} else if err != nil {
			return Delivery{}, false, fmt.Errorf("load group call push group: %w", err)
		}
		delivery.Title = groupName
		delivery.Body = "群通话正在呼叫"
		delivery.HighPriority = true
		return delivery, false, nil
	case "CALL_RINGING":
		var payload struct {
			CallerName string `json:"callerName"`
			Kind       string `json:"kind"`
		}
		_ = json.Unmarshal(job.Payload, &payload)
		if strings.EqualFold(payload.Kind, "video") {
			delivery.Body = "正在邀请你视频通话"
		} else {
			delivery.Body = "正在邀请你语音通话"
		}
		delivery.Title = strings.TrimSpace(payload.CallerName)
		if delivery.Title == "" {
			delivery.Title = "DD 来电"
		}
		delivery.HighPriority = true
		return delivery, false, nil
	case "CONTACT_REQUEST_CREATED":
		var payload struct {
			SenderName string `json:"senderName"`
		}
		_ = json.Unmarshal(job.Payload, &payload)
		delivery.Title = "新的朋友"
		if strings.TrimSpace(payload.SenderName) == "" {
			delivery.Body = "你收到了一条好友申请"
		} else {
			delivery.Body = payload.SenderName + " 请求添加你为好友"
		}
		return delivery, false, nil
	case "MOMENT_COMMENT_CREATED":
		delivery.Title = "朋友圈"
		delivery.Body = "你的朋友圈收到了一条新评论"
		return delivery, false, nil
	case "MOMENT_LIKE_CHANGED":
		delivery.Title = "朋友圈"
		delivery.Body = "有人赞了你的朋友圈"
		return delivery, false, nil
	default:
		delivery.Title = "DD"
		delivery.Body = "你有新的动态"
		return delivery, false, nil
	}
}

func renderPreview(mode, senderName, messageType string, content []byte) (string, string) {
	if normalizePreviewMode(mode) == PreviewHidden {
		return "DD", "你收到了一条新消息"
	}
	title := strings.TrimSpace(senderName)
	if title == "" {
		title = "DD"
	}
	if normalizePreviewMode(mode) != PreviewFull {
		return title, "你收到了一条新消息"
	}
	body := messageTypeLabel(messageType)
	if strings.EqualFold(messageType, "TEXT") || strings.EqualFold(messageType, "SYSTEM") {
		var payload struct {
			Text string `json:"text"`
		}
		if json.Unmarshal(content, &payload) == nil && strings.TrimSpace(payload.Text) != "" {
			body = strings.TrimSpace(payload.Text)
		}
	}
	return title, truncateRunes(body, 160)
}

func messageTypeLabel(messageType string) string {
	switch strings.ToUpper(strings.TrimSpace(messageType)) {
	case "IMAGE":
		return "图片"
	case "GIF":
		return "GIF"
	case "VIDEO":
		return "视频"
	case "VOICE":
		return "语音消息"
	case "FILE":
		return "文件"
	case "STICKER":
		return "贴纸"
	case "STICKER_PACK":
		return "表情包"
	case "SYSTEM":
		return "系统消息"
	default:
		return "你收到了一条新消息"
	}
}

func truncateRunes(value string, max int) string {
	runes := []rune(value)
	if len(runes) <= max {
		return value
	}
	return string(runes[:max]) + "…"
}

func (service *Service) deferJob(ctx context.Context, tx pgx.Tx, job pushJob, dispatchErr error, now time.Time) (bool, error) {
	attempt := job.Attempts + 1
	if attempt >= 8 {
		message := truncateRunes(dispatchErr.Error(), 900)
		if _, err := tx.Exec(ctx, `UPDATE push_jobs SET status='DROPPED',attempts=$2,last_error=$3 WHERE id=$1`, job.ID, attempt, message); err != nil {
			return false, fmt.Errorf("drop exhausted push job: %w", err)
		}
		if err := tx.Commit(ctx); err != nil {
			return false, fmt.Errorf("commit exhausted push job: %w", err)
		}
		if service.observer != nil {
			service.observer.PushFailed()
		}
		return true, nil
	}
	backoff := time.Second * time.Duration(1<<min(attempt-1, 8))
	if backoff > 5*time.Minute {
		backoff = 5 * time.Minute
	}
	message := truncateRunes(dispatchErr.Error(), 900)
	if _, err := tx.Exec(ctx, `
		UPDATE push_jobs SET attempts=$2,last_error=$3,available_at=$4 WHERE id=$1
	`, job.ID, attempt, message, now.Add(backoff)); err != nil {
		return false, fmt.Errorf("defer push job: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("commit deferred push job: %w", err)
	}
	if service.observer != nil {
		service.observer.PushRetry()
	}
	return true, nil
}

func (service *Service) dropJob(ctx context.Context, tx pgx.Tx, jobID uuid.UUID, reason string, now time.Time) (bool, error) {
	if _, err := tx.Exec(ctx, `UPDATE push_jobs SET status='DROPPED',last_error=$2 WHERE id=$1`, jobID, reason); err != nil {
		return false, fmt.Errorf("drop push job: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("commit dropped push job: %w", err)
	}
	if reason == "ALL_ENDPOINTS_FAILED" && service.observer != nil {
		service.observer.PushFailed()
	}
	return true, nil
}

func classifyProviderFailure(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, ErrRetryable) {
		return "RETRYABLE"
	}
	if errors.Is(err, ErrProviderUnavailable) {
		return "PROVIDER_UNAVAILABLE"
	}
	text := strings.ToUpper(err.Error())
	for _, code := range []string{"UNREGISTERED", "BADDEVICETOKEN", "INVALID_ARGUMENT", "UNAUTHORIZED", "FORBIDDEN"} {
		if strings.Contains(text, code) {
			return code
		}
	}
	return "PROVIDER_ERROR"
}
