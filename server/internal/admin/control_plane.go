package admin

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
)

type DashboardSummary struct {
	TotalUsers                 int64 `json:"totalUsers"`
	TodayRegistrations         int64 `json:"todayRegistrations"`
	OnlineUsers                int64 `json:"onlineUsers"`
	ActiveDevices24h           int64 `json:"activeDevices24h"`
	TotalMessages              int64 `json:"totalMessages"`
	TodayMessages              int64 `json:"todayMessages"`
	TotalGroups                int64 `json:"totalGroups"`
	TotalMoments               int64 `json:"totalMoments"`
	TodayMoments               int64 `json:"todayMoments"`
	TotalCalls                 int64 `json:"totalCalls"`
	TodayCalls                 int64 `json:"todayCalls"`
	ActiveCalls                int64 `json:"activeCalls"`
	MediaObjects               int64 `json:"mediaObjects"`
	MediaBytes                 int64 `json:"mediaBytes"`
	PendingPushJobs            int64 `json:"pendingPushJobs"`
	PendingVoiceTranscriptions int64 `json:"pendingVoiceTranscriptions"`
	PendingOutboxEvents        int64 `json:"pendingOutboxEvents"`
}

type DashboardDay struct {
	Date          string `json:"date"`
	Registrations int64  `json:"registrations"`
	Messages      int64  `json:"messages"`
	Calls         int64  `json:"calls"`
	Moments       int64  `json:"moments"`
}

type DashboardSnapshot struct {
	GeneratedAt time.Time        `json:"generatedAt"`
	Presence    string           `json:"presenceDefinition"`
	Summary     DashboardSummary `json:"summary"`
	Trend       []DashboardDay   `json:"trend"`
}

type UserActivityCounts struct {
	Contacts       int64 `json:"contacts"`
	Groups         int64 `json:"groups"`
	Messages       int64 `json:"messages"`
	Moments        int64 `json:"moments"`
	ActiveSessions int64 `json:"activeSessions"`
}

type UserPushEndpoint struct {
	Provider        string     `json:"provider"`
	Environment     string     `json:"environment"`
	Status          string     `json:"status"`
	FailureCount    int        `json:"failureCount"`
	LastSuccessAt   *time.Time `json:"lastSuccessAt,omitempty"`
	LastFailureAt   *time.Time `json:"lastFailureAt,omitempty"`
	LastFailureCode string     `json:"lastFailureCode,omitempty"`
}

type UserDeviceDetail struct {
	ID         string             `json:"id"`
	Name       string             `json:"name"`
	Platform   string             `json:"platform"`
	AppVersion string             `json:"appVersion"`
	IsVerified bool               `json:"isVerified"`
	CreatedAt  time.Time          `json:"createdAt"`
	LastSeenAt time.Time          `json:"lastSeenAt"`
	RevokedAt  *time.Time         `json:"revokedAt,omitempty"`
	Push       []UserPushEndpoint `json:"push"`
}

type UserDetail struct {
	UserSummary
	Bio             string             `json:"bio"`
	AvatarMediaID   string             `json:"avatarMediaId,omitempty"`
	EmailVerifiedAt time.Time          `json:"emailVerifiedAt"`
	DeletedAt       *time.Time         `json:"deletedAt,omitempty"`
	Counts          UserActivityCounts `json:"counts"`
	Devices         []UserDeviceDetail `json:"devices"`
}

type GroupSummary struct {
	ConversationID  string     `json:"conversationId"`
	Name            string     `json:"name"`
	Announcement    string     `json:"announcement"`
	JoinMode        string     `json:"joinMode"`
	Status          string     `json:"status"`
	CreatedByUserID string     `json:"createdByUserId"`
	CreatedByHandle string     `json:"createdByHandle"`
	MemberCount     int64      `json:"memberCount"`
	CreatedAt       time.Time  `json:"createdAt"`
	UpdatedAt       time.Time  `json:"updatedAt"`
	DissolvedAt     *time.Time `json:"dissolvedAt,omitempty"`
}

type MomentSummary struct {
	ID                string     `json:"id"`
	AuthorUserID      string     `json:"authorUserId"`
	AuthorHandle      string     `json:"authorHandle"`
	AuthorDisplayName string     `json:"authorDisplayName"`
	Text              string     `json:"text"`
	Visibility        string     `json:"visibility"`
	Status            string     `json:"status"`
	MediaCount        int64      `json:"mediaCount"`
	LikeCount         int64      `json:"likeCount"`
	CommentCount      int64      `json:"commentCount"`
	CreatedAt         time.Time  `json:"createdAt"`
	DeletedAt         *time.Time `json:"deletedAt,omitempty"`
}

type StorageBucket struct {
	Purpose     string `json:"purpose"`
	ObjectCount int64  `json:"objectCount"`
	Bytes       int64  `json:"bytes"`
}

type StorageSnapshot struct {
	GeneratedAt              time.Time       `json:"generatedAt"`
	ReadyObjects             int64           `json:"readyObjects"`
	ReadyBytes               int64           `json:"readyBytes"`
	UploadingObjects         int64           `json:"uploadingObjects"`
	FailedObjects            int64           `json:"failedObjects"`
	QuarantinedObjects       int64           `json:"quarantinedObjects"`
	DeletedObjects           int64           `json:"deletedObjects"`
	ExpiredIncompleteUploads int64           `json:"expiredIncompleteUploads"`
	ByPurpose                []StorageBucket `json:"byPurpose"`
}

type PushEndpointBucket struct {
	Provider string `json:"provider"`
	Status   string `json:"status"`
	Count    int64  `json:"count"`
}

type PushSnapshot struct {
	GeneratedAt         time.Time            `json:"generatedAt"`
	PendingJobs         int64                `json:"pendingJobs"`
	RetryingJobs        int64                `json:"retryingJobs"`
	SentJobs24h         int64                `json:"sentJobs24h"`
	DroppedJobs24h      int64                `json:"droppedJobs24h"`
	EndpointFailures24h int64                `json:"endpointFailures24h"`
	OldestPendingAt     *time.Time           `json:"oldestPendingAt,omitempty"`
	Endpoints           []PushEndpointBucket `json:"endpoints"`
}

type RTCSnapshot struct {
	GeneratedAt             time.Time `json:"generatedAt"`
	DirectCallsToday        int64     `json:"directCallsToday"`
	ActiveDirectCalls       int64     `json:"activeDirectCalls"`
	AcceptedDirectCalls24h  int64     `json:"acceptedDirectCalls24h"`
	AverageDirectSeconds24h float64   `json:"averageDirectSeconds24h"`
	GroupCallsToday         int64     `json:"groupCallsToday"`
	ActiveGroupCalls        int64     `json:"activeGroupCalls"`
	ActiveGroupParticipants int64     `json:"activeGroupParticipants"`
}

func (service *Service) Dashboard(ctx context.Context, _ Principal) (DashboardSnapshot, error) {
	now := service.now().UTC()
	var summary DashboardSummary
	err := service.pool.QueryRow(ctx, `
		SELECT
			(SELECT count(*) FROM users WHERE status <> 'DELETED'),
			(SELECT count(*) FROM users WHERE created_at >= date_trunc('day',$1::timestamptz)),
			(SELECT count(DISTINCT user_id) FROM devices WHERE revoked_at IS NULL AND last_seen_at >= $1::timestamptz - interval '5 minutes'),
			(SELECT count(*) FROM devices WHERE revoked_at IS NULL AND last_seen_at >= $1::timestamptz - interval '24 hours'),
			(SELECT count(*) FROM messages),
			(SELECT count(*) FROM messages WHERE created_at >= date_trunc('day',$1::timestamptz)),
			(SELECT count(*) FROM groups WHERE status='ACTIVE'),
			(SELECT count(*) FROM moments WHERE status='ACTIVE'),
			(SELECT count(*) FROM moments WHERE created_at >= date_trunc('day',$1::timestamptz)),
			(SELECT count(*) FROM calls),
			(SELECT count(*) FROM calls WHERE created_at >= date_trunc('day',$1::timestamptz)),
			(SELECT count(*) FROM calls WHERE status IN ('ringing','accepted')),
			(SELECT count(*) FROM media_objects WHERE status='READY'),
			(SELECT COALESCE(sum(size_bytes),0) FROM media_objects WHERE status='READY'),
			(SELECT count(*) FROM push_jobs WHERE status='PENDING'),
			(SELECT count(*) FROM voice_transcriptions WHERE status IN ('PENDING','RUNNING')),
			(SELECT count(*) FROM outbox_events WHERE published_at IS NULL)
	`, now).Scan(
		&summary.TotalUsers, &summary.TodayRegistrations, &summary.OnlineUsers, &summary.ActiveDevices24h,
		&summary.TotalMessages, &summary.TodayMessages, &summary.TotalGroups, &summary.TotalMoments, &summary.TodayMoments,
		&summary.TotalCalls, &summary.TodayCalls, &summary.ActiveCalls, &summary.MediaObjects, &summary.MediaBytes,
		&summary.PendingPushJobs, &summary.PendingVoiceTranscriptions, &summary.PendingOutboxEvents,
	)
	if err != nil {
		return DashboardSnapshot{}, fmt.Errorf("load admin dashboard summary: %w", err)
	}

	rows, err := service.pool.Query(ctx, `
		SELECT day::date,
			(SELECT count(*) FROM users WHERE created_at >= day AND created_at < day + interval '1 day'),
			(SELECT count(*) FROM messages WHERE created_at >= day AND created_at < day + interval '1 day'),
			(SELECT count(*) FROM calls WHERE created_at >= day AND created_at < day + interval '1 day'),
			(SELECT count(*) FROM moments WHERE created_at >= day AND created_at < day + interval '1 day')
		FROM generate_series(date_trunc('day',$1::timestamptz) - interval '13 days', date_trunc('day',$1::timestamptz), interval '1 day') AS day
		ORDER BY day
	`, now)
	if err != nil {
		return DashboardSnapshot{}, fmt.Errorf("load admin dashboard trend: %w", err)
	}
	defer rows.Close()
	trend := make([]DashboardDay, 0, 14)
	for rows.Next() {
		var day time.Time
		var item DashboardDay
		if err := rows.Scan(&day, &item.Registrations, &item.Messages, &item.Calls, &item.Moments); err != nil {
			return DashboardSnapshot{}, fmt.Errorf("scan admin dashboard trend: %w", err)
		}
		item.Date = day.UTC().Format("2006-01-02")
		trend = append(trend, item)
	}
	if err := rows.Err(); err != nil {
		return DashboardSnapshot{}, fmt.Errorf("iterate admin dashboard trend: %w", err)
	}
	return DashboardSnapshot{
		GeneratedAt: now,
		Presence:    "distinct users with a non-revoked device seen within the last 5 minutes",
		Summary:     summary,
		Trend:       trend,
	}, nil
}

func (service *Service) GetUserDetail(ctx context.Context, principal Principal, userID uuid.UUID) (UserDetail, error) {
	base, err := service.GetUser(ctx, principal, userID)
	if err != nil {
		return UserDetail{}, err
	}
	detail := UserDetail{UserSummary: base, Devices: make([]UserDeviceDetail, 0)}
	if err := service.pool.QueryRow(ctx, `
		SELECT bio,COALESCE(avatar_media_id::text,''),email_verified_at,deleted_at,
			(SELECT count(*) FROM contacts WHERE owner_user_id=$1),
			(SELECT count(*) FROM conversation_members cm JOIN groups g ON g.conversation_id=cm.conversation_id WHERE cm.user_id=$1 AND cm.status='ACTIVE' AND g.status='ACTIVE'),
			(SELECT count(*) FROM messages WHERE sender_user_id=$1),
			(SELECT count(*) FROM moments WHERE author_user_id=$1 AND status='ACTIVE'),
			(SELECT count(*) FROM refresh_tokens WHERE user_id=$1 AND revoked_at IS NULL AND expires_at > $2)
		FROM users WHERE id=$1
	`, userID, service.now().UTC()).Scan(
		&detail.Bio, &detail.AvatarMediaID, &detail.EmailVerifiedAt, &detail.DeletedAt,
		&detail.Counts.Contacts, &detail.Counts.Groups, &detail.Counts.Messages, &detail.Counts.Moments, &detail.Counts.ActiveSessions,
	); err != nil {
		return UserDetail{}, fmt.Errorf("load governed user detail: %w", err)
	}

	rows, err := service.pool.Query(ctx, `
		SELECT id::text,name,platform,app_version,is_verified,created_at,last_seen_at,revoked_at
		FROM devices WHERE user_id=$1 ORDER BY last_seen_at DESC,id
	`, userID)
	if err != nil {
		return UserDetail{}, fmt.Errorf("list governed user devices: %w", err)
	}
	for rows.Next() {
		var item UserDeviceDetail
		item.Push = make([]UserPushEndpoint, 0)
		if err := rows.Scan(&item.ID, &item.Name, &item.Platform, &item.AppVersion, &item.IsVerified, &item.CreatedAt, &item.LastSeenAt, &item.RevokedAt); err != nil {
			rows.Close()
			return UserDetail{}, fmt.Errorf("scan governed user device: %w", err)
		}
		detail.Devices = append(detail.Devices, item)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return UserDetail{}, fmt.Errorf("iterate governed user devices: %w", err)
	}
	rows.Close()

	deviceIndex := make(map[string]int, len(detail.Devices))
	for index := range detail.Devices {
		deviceIndex[detail.Devices[index].ID] = index
	}
	pushRows, err := service.pool.Query(ctx, `
		SELECT e.device_id::text,e.provider,e.environment,e.status,e.failure_count,e.last_success_at,e.last_failure_at,COALESCE(e.last_failure_code,'')
		FROM device_push_endpoints e JOIN devices d ON d.id=e.device_id
		WHERE d.user_id=$1 ORDER BY e.updated_at DESC,e.id
	`, userID)
	if err != nil {
		return UserDetail{}, fmt.Errorf("list governed user push endpoints: %w", err)
	}
	defer pushRows.Close()
	for pushRows.Next() {
		var deviceID string
		var item UserPushEndpoint
		if err := pushRows.Scan(&deviceID, &item.Provider, &item.Environment, &item.Status, &item.FailureCount, &item.LastSuccessAt, &item.LastFailureAt, &item.LastFailureCode); err != nil {
			return UserDetail{}, fmt.Errorf("scan governed user push endpoint: %w", err)
		}
		if index, ok := deviceIndex[deviceID]; ok {
			detail.Devices[index].Push = append(detail.Devices[index].Push, item)
		}
	}
	if err := pushRows.Err(); err != nil {
		return UserDetail{}, fmt.Errorf("iterate governed user push endpoints: %w", err)
	}
	return detail, nil
}

func (service *Service) ListGroups(ctx context.Context, _ Principal, status, query string, limit int) ([]GroupSummary, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	status = strings.ToUpper(strings.TrimSpace(status))
	if status != "" && status != "ACTIVE" && status != "DISSOLVED" {
		return nil, fmt.Errorf("%w: invalid group status", ErrInvalidInput)
	}
	query = strings.TrimSpace(query)
	if len(query) > 100 {
		query = query[:100]
	}
	rows, err := service.pool.Query(ctx, `
		SELECT g.conversation_id::text,g.name,g.announcement,g.join_mode,g.status,g.created_by_user_id::text,
		       COALESCE(u.handle_normalized,''),
		       (SELECT count(*) FROM conversation_members cm WHERE cm.conversation_id=g.conversation_id AND cm.status='ACTIVE'),
		       g.created_at,g.updated_at,g.dissolved_at
		FROM groups g LEFT JOIN users u ON u.id=g.created_by_user_id
		WHERE ($1='' OR g.status=$1) AND ($2='' OR g.name ILIKE '%' || $2 || '%' OR COALESCE(u.handle_normalized,'') ILIKE '%' || $2 || '%')
		ORDER BY g.updated_at DESC,g.conversation_id LIMIT $3
	`, status, query, limit)
	if err != nil {
		return nil, fmt.Errorf("list governed groups: %w", err)
	}
	defer rows.Close()
	items := make([]GroupSummary, 0)
	for rows.Next() {
		var item GroupSummary
		if err := rows.Scan(&item.ConversationID, &item.Name, &item.Announcement, &item.JoinMode, &item.Status,
			&item.CreatedByUserID, &item.CreatedByHandle, &item.MemberCount, &item.CreatedAt, &item.UpdatedAt, &item.DissolvedAt); err != nil {
			return nil, fmt.Errorf("scan governed group: %w", err)
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (service *Service) ListMoments(ctx context.Context, _ Principal, status, query string, limit int) ([]MomentSummary, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	status = strings.ToUpper(strings.TrimSpace(status))
	if status != "" && status != "ACTIVE" && status != "DELETED" {
		return nil, fmt.Errorf("%w: invalid moment status", ErrInvalidInput)
	}
	query = strings.TrimSpace(query)
	if len(query) > 100 {
		query = query[:100]
	}
	rows, err := service.pool.Query(ctx, `
		SELECT m.id::text,m.author_user_id::text,u.handle_normalized,u.display_name,m.text,m.visibility,m.status,
		       (SELECT count(*) FROM moment_media mm WHERE mm.moment_id=m.id),
		       (SELECT count(*) FROM moment_likes ml WHERE ml.moment_id=m.id),
		       (SELECT count(*) FROM moment_comments mc WHERE mc.moment_id=m.id AND mc.deleted_at IS NULL),
		       m.created_at,m.deleted_at
		FROM moments m JOIN users u ON u.id=m.author_user_id
		WHERE ($1='' OR m.status=$1)
		  AND ($2='' OR m.text ILIKE '%' || $2 || '%' OR u.handle_normalized ILIKE '%' || $2 || '%' OR u.display_name ILIKE '%' || $2 || '%')
		ORDER BY m.created_at DESC,m.id LIMIT $3
	`, status, query, limit)
	if err != nil {
		return nil, fmt.Errorf("list governed moments: %w", err)
	}
	defer rows.Close()
	items := make([]MomentSummary, 0)
	for rows.Next() {
		var item MomentSummary
		if err := rows.Scan(&item.ID, &item.AuthorUserID, &item.AuthorHandle, &item.AuthorDisplayName, &item.Text,
			&item.Visibility, &item.Status, &item.MediaCount, &item.LikeCount, &item.CommentCount, &item.CreatedAt, &item.DeletedAt); err != nil {
			return nil, fmt.Errorf("scan governed moment: %w", err)
		}
		items = append(items, item)
	}
	return items, rows.Err()
}
