package contacts

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/identity"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/text/unicode/norm"
)

var (
	ErrUnavailable         = errors.New("contacts service unavailable")
	ErrNotFound            = errors.New("relationship resource not found")
	ErrForbidden           = errors.New("relationship operation forbidden")
	ErrBlocked             = errors.New("relationship is blocked")
	ErrAlreadyContact      = errors.New("users are already contacts")
	ErrRequestConflict     = errors.New("contact request conflicts with current state")
	ErrRateLimited         = errors.New("relationship rate limited")
	ErrInvalidState        = errors.New("relationship state is invalid")
	ErrInvalidMentionQuery = errors.New("invalid mention suggestion query")
)

const (
	requestTTL                = 30 * 24 * time.Hour
	handleSearchWindow        = 10 * time.Minute
	handleSearchLimit         = 60
	contactRequestWindow      = 24 * time.Hour
	contactRequestLimit       = 30
	defaultPageSize           = 50
	maximumPageSize           = 100
	maximumRequestMessage     = 200
	maximumRemarkLength       = 80
	maximumTagLength          = 40
	maximumTagsPerContact     = 20
	mentionSuggestionWindow   = time.Minute
	mentionSuggestionLimit    = 60
	maximumMentionSuggestions = 8
)

type Service struct {
	pool *pgxpool.Pool
	now  func() time.Time
}

type Config struct {
	Pool *pgxpool.Pool
	Now  func() time.Time
}

type PublicUser struct {
	ID          string `json:"id"`
	Handle      string `json:"handle"`
	DisplayName string `json:"displayName"`
	Bio         string `json:"bio"`
}

type SearchResult struct {
	User                 PublicUser `json:"user"`
	Relationship         string     `json:"relationship"`
	EffectiveDisplayName string     `json:"effectiveDisplayName"`
}

type MentionSuggestion struct {
	User                 PublicUser `json:"user"`
	Relationship         string     `json:"relationship"`
	EffectiveDisplayName string     `json:"effectiveDisplayName"`
}

type ContactRequest struct {
	ID             string     `json:"id"`
	Sender         PublicUser `json:"sender"`
	Receiver       PublicUser `json:"receiver"`
	Message        string     `json:"message"`
	Status         string     `json:"status"`
	CreatedAt      time.Time  `json:"createdAt"`
	ExpiresAt      time.Time  `json:"expiresAt"`
	ResolvedAt     *time.Time `json:"resolvedAt,omitempty"`
	ConversationID *string    `json:"conversationId,omitempty"`
}

type Contact struct {
	User      PublicUser `json:"user"`
	Remark    string     `json:"remark"`
	IsStarred bool       `json:"isStarred"`
	Tags      []string   `json:"tags"`
	CreatedAt time.Time  `json:"createdAt"`
	UpdatedAt time.Time  `json:"updatedAt"`
}

type BlockedUser struct {
	User      PublicUser `json:"user"`
	CreatedAt time.Time  `json:"createdAt"`
}

type Page[T any] struct {
	Items      []T `json:"items"`
	Page       int `json:"page"`
	PageSize   int `json:"pageSize"`
	TotalItems int `json:"totalItems"`
	TotalPages int `json:"totalPages"`
}

type SendRequestInput struct {
	TargetHandle string `json:"targetHandle"`
	Message      string `json:"message"`
}

type UpdateContactInput struct {
	Remark    *string   `json:"remark"`
	IsStarred *bool     `json:"isStarred"`
	Tags      *[]string `json:"tags"`
}

func NewService(config Config) (*Service, error) {
	if config.Pool == nil {
		return nil, ErrUnavailable
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	return &Service{pool: config.Pool, now: now}, nil
}

func (service *Service) SearchByHandle(ctx context.Context, principal account.Principal, rawHandle string) (SearchResult, error) {
	handle, err := identity.NormalizeHandle(rawHandle)
	if err != nil {
		return SearchResult{}, err
	}
	if err := service.consumeRateLimit(ctx, principal.UserID, "HANDLE_SEARCH", handleSearchWindow, handleSearchLimit); err != nil {
		return SearchResult{}, err
	}

	var user PublicUser
	var effectiveDisplayName string
	err = service.pool.QueryRow(ctx, `
		SELECT u.id,u.handle_normalized,u.display_name,u.bio,
		       COALESCE(NULLIF(viewer_contact.remark,''),u.display_name)
		FROM users u
		LEFT JOIN contacts viewer_contact ON viewer_contact.owner_user_id=$1 AND viewer_contact.contact_user_id=u.id
		WHERE u.handle_normalized=$2 AND u.status='ACTIVE'
	`, principal.UserID, handle).Scan(&user.ID, &user.Handle, &user.DisplayName, &user.Bio, &effectiveDisplayName)
	if errors.Is(err, pgx.ErrNoRows) {
		return SearchResult{}, ErrNotFound
	}
	if err != nil {
		return SearchResult{}, fmt.Errorf("search handle: %w", err)
	}

	targetID, err := uuid.Parse(user.ID)
	if err != nil {
		return SearchResult{}, fmt.Errorf("parse searched user id: %w", err)
	}
	return service.relationshipForUser(ctx, principal, user, targetID, effectiveDisplayName)
}

func (service *Service) GetUserByID(ctx context.Context, principal account.Principal, userID uuid.UUID) (SearchResult, error) {
	if userID == uuid.Nil {
		return SearchResult{}, ErrNotFound
	}
	var user PublicUser
	var effectiveDisplayName string
	err := service.pool.QueryRow(ctx, `
		SELECT u.id,u.handle_normalized,u.display_name,u.bio,
		       COALESCE(NULLIF(viewer_contact.remark,''),u.display_name)
		FROM users u
		LEFT JOIN contacts viewer_contact ON viewer_contact.owner_user_id=$1 AND viewer_contact.contact_user_id=u.id
		WHERE u.id=$2 AND u.status='ACTIVE'
	`, principal.UserID, userID).Scan(&user.ID, &user.Handle, &user.DisplayName, &user.Bio, &effectiveDisplayName)
	if errors.Is(err, pgx.ErrNoRows) {
		return SearchResult{}, ErrNotFound
	}
	if err != nil {
		return SearchResult{}, fmt.Errorf("load public user profile: %w", err)
	}
	return service.relationshipForUser(ctx, principal, user, userID, effectiveDisplayName)
}

func (service *Service) SuggestMentions(ctx context.Context, principal account.Principal, rawQuery string, conversationID *uuid.UUID, limit int) ([]MentionSuggestion, error) {
	query, err := normalizeMentionSuggestionQuery(rawQuery)
	if err != nil {
		return nil, err
	}
	if limit <= 0 {
		limit = maximumMentionSuggestions
	}
	if limit > maximumMentionSuggestions {
		return nil, ErrInvalidMentionQuery
	}
	if err := service.consumeRateLimit(ctx, principal.UserID, "MENTION_SUGGESTION", mentionSuggestionWindow, mentionSuggestionLimit); err != nil {
		return nil, err
	}

	var conversation any
	if conversationID != nil && *conversationID != uuid.Nil {
		conversation = *conversationID
	}
	rows, err := service.pool.Query(ctx, `
		WITH current_peer AS (
			SELECT peer.user_id
			FROM conversations c
			JOIN conversation_members self
			  ON self.conversation_id=c.id
			 AND self.user_id=$1
			 AND self.status='ACTIVE'
			JOIN conversation_members peer
			  ON peer.conversation_id=c.id
			 AND peer.user_id<>$1
			 AND peer.status='ACTIVE'
			WHERE c.id=$3::uuid AND c.type='DIRECT'
			LIMIT 1
		), current_group_members AS (
			SELECT member.user_id
			FROM conversations c
			JOIN conversation_members self
			  ON self.conversation_id=c.id
			 AND self.user_id=$1
			 AND self.status='ACTIVE'
			JOIN conversation_members member
			  ON member.conversation_id=c.id
			 AND member.user_id<>$1
			 AND member.status='ACTIVE'
			WHERE c.id=$3::uuid AND c.type='GROUP'
		)
		SELECT u.id::text,u.handle_normalized,u.display_name,u.bio,
		       COALESCE(NULLIF(gmp.nickname,''),NULLIF(contact.remark,''),u.display_name),
		       CASE
		         WHEN cgm.user_id IS NOT NULL THEN 'GROUP_MEMBER'
		         WHEN cp.user_id IS NOT NULL THEN 'CONVERSATION_PEER'
		         WHEN contact.contact_user_id IS NOT NULL THEN 'CONTACT'
		         ELSE 'NONE'
		       END AS relationship
		FROM users u
		LEFT JOIN current_peer cp ON cp.user_id=u.id
		LEFT JOIN current_group_members cgm ON cgm.user_id=u.id
		LEFT JOIN contacts contact
		  ON contact.owner_user_id=$1 AND contact.contact_user_id=u.id
		LEFT JOIN group_member_profiles gmp
		  ON gmp.conversation_id=$3::uuid AND gmp.user_id=u.id
		WHERE u.status='ACTIVE'
		  AND u.id<>$1
		  AND (
		    u.handle_normalized LIKE $2 || '%'
		    OR lower(u.display_name) LIKE '%' || lower($2) || '%'
		    OR lower(COALESCE(contact.remark,'')) LIKE '%' || lower($2) || '%'
		    OR lower(COALESCE(gmp.nickname,'')) LIKE '%' || lower($2) || '%'
		  )
		  AND NOT EXISTS (
		    SELECT 1 FROM blocks b
		    WHERE (b.owner_user_id=$1 AND b.blocked_user_id=u.id)
		       OR (b.owner_user_id=u.id AND b.blocked_user_id=$1)
		  )
		ORDER BY
		  (cgm.user_id IS NOT NULL) DESC,
		  (cp.user_id IS NOT NULL) DESC,
		  (contact.contact_user_id IS NOT NULL) DESC,
		  (u.handle_normalized LIKE $2 || '%') DESC,
		  u.handle_normalized ASC
		LIMIT $4
	`, principal.UserID, query, conversation, limit)
	if err != nil {
		return nil, fmt.Errorf("list mention suggestions: %w", err)
	}
	defer rows.Close()

	items := make([]MentionSuggestion, 0, limit)
	for rows.Next() {
		var item MentionSuggestion
		if err := rows.Scan(
			&item.User.ID,
			&item.User.Handle,
			&item.User.DisplayName,
			&item.User.Bio,
			&item.EffectiveDisplayName,
			&item.Relationship,
		); err != nil {
			return nil, fmt.Errorf("scan mention suggestion: %w", err)
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate mention suggestions: %w", err)
	}
	return items, nil
}

func normalizeMentionSuggestionQuery(raw string) (string, error) {
	query := strings.ToLower(strings.TrimSpace(raw))
	if len(query) < 2 || len(query) > 32 {
		return "", ErrInvalidMentionQuery
	}
	for index := 0; index < len(query); index++ {
		value := query[index]
		if index == 0 {
			if value < 'a' || value > 'z' {
				return "", ErrInvalidMentionQuery
			}
			continue
		}
		if !((value >= 'a' && value <= 'z') || (value >= '0' && value <= '9') || value == '_') {
			return "", ErrInvalidMentionQuery
		}
	}
	return query, nil
}

func (service *Service) relationshipForUser(ctx context.Context, principal account.Principal, user PublicUser, targetID uuid.UUID, effectiveDisplayName string) (SearchResult, error) {
	if targetID == principal.UserID {
		return SearchResult{User: user, Relationship: "SELF", EffectiveDisplayName: effectiveDisplayName}, nil
	}

	if blocked, err := service.IsBlockedBetween(ctx, principal.UserID, targetID); err != nil {
		return SearchResult{}, err
	} else if blocked {
		// Stable-id lookup follows the same privacy boundary as exact-handle
		// search: a blocked account is indistinguishable from an unavailable
		// account, so mention/profile lookup cannot be used to probe blocks.
		return SearchResult{}, ErrNotFound
	}

	now := service.now().UTC()
	if _, err := service.pool.Exec(ctx, `
		UPDATE contact_requests
		SET status='EXPIRED',resolved_at=$3
		WHERE status='PENDING' AND expires_at<=$3
		  AND ((sender_user_id=$1 AND receiver_user_id=$2) OR (sender_user_id=$2 AND receiver_user_id=$1))
	`, principal.UserID, targetID, now); err != nil {
		return SearchResult{}, fmt.Errorf("expire stale contact request: %w", err)
	}

	var isContact, outgoingPending, incomingPending bool
	if err := service.pool.QueryRow(ctx, `
		SELECT
			EXISTS(SELECT 1 FROM contacts WHERE owner_user_id=$1 AND contact_user_id=$2),
			EXISTS(SELECT 1 FROM contact_requests WHERE sender_user_id=$1 AND receiver_user_id=$2 AND status='PENDING'),
			EXISTS(SELECT 1 FROM contact_requests WHERE sender_user_id=$2 AND receiver_user_id=$1 AND status='PENDING')
	`, principal.UserID, targetID).Scan(&isContact, &outgoingPending, &incomingPending); err != nil {
		return SearchResult{}, fmt.Errorf("load relationship state: %w", err)
	}

	relationship := "NONE"
	switch {
	case isContact:
		relationship = "CONTACT"
	case outgoingPending:
		relationship = "PENDING_OUTGOING"
	case incomingPending:
		relationship = "PENDING_INCOMING"
	}
	return SearchResult{User: user, Relationship: relationship, EffectiveDisplayName: effectiveDisplayName}, nil
}

func (service *Service) SendRequest(ctx context.Context, principal account.Principal, raw SendRequestInput) (ContactRequest, error) {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		result, err := service.sendRequestOnce(ctx, principal, raw)
		if err == nil {
			return result, nil
		}
		lastErr = err
		if !isSerializationFailure(err) {
			return ContactRequest{}, err
		}
	}
	return ContactRequest{}, lastErr
}

func (service *Service) sendRequestOnce(ctx context.Context, principal account.Principal, raw SendRequestInput) (ContactRequest, error) {
	handle, err := identity.NormalizeHandle(raw.TargetHandle)
	if err != nil {
		return ContactRequest{}, err
	}
	message, err := normalizeBoundedText(raw.Message, maximumRequestMessage, true, "contact request message")
	if err != nil {
		return ContactRequest{}, err
	}
	now := service.now().UTC()

	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return ContactRequest{}, fmt.Errorf("begin contact request: %w", err)
	}
	defer tx.Rollback(ctx)

	var targetID uuid.UUID
	if err := tx.QueryRow(ctx, `SELECT id FROM users WHERE handle_normalized = $1 AND status = 'ACTIVE'`, handle).Scan(&targetID); errors.Is(err, pgx.ErrNoRows) {
		return ContactRequest{}, ErrNotFound
	} else if err != nil {
		return ContactRequest{}, fmt.Errorf("resolve contact target: %w", err)
	}
	if targetID == principal.UserID {
		return ContactRequest{}, ErrInvalidState
	}
	if err := lockPair(ctx, tx, principal.UserID, targetID); err != nil {
		return ContactRequest{}, err
	}
	if err := expirePairRequests(ctx, tx, principal.UserID, targetID, now); err != nil {
		return ContactRequest{}, err
	}
	if blocked, err := isBlockedBetweenTx(ctx, tx, principal.UserID, targetID); err != nil {
		return ContactRequest{}, err
	} else if blocked {
		return ContactRequest{}, ErrBlocked
	}
	var contactExists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM contacts WHERE owner_user_id = $1 AND contact_user_id = $2)`, principal.UserID, targetID).Scan(&contactExists); err != nil {
		return ContactRequest{}, fmt.Errorf("check existing contact: %w", err)
	}
	if contactExists {
		return ContactRequest{}, ErrAlreadyContact
	}

	existing, found, err := loadPendingPairRequest(ctx, tx, principal.UserID, targetID)
	if err != nil {
		return ContactRequest{}, err
	}
	if found {
		if existing.Sender.ID == principal.UserID.String() {
			if err := tx.Commit(ctx); err != nil {
				return ContactRequest{}, fmt.Errorf("commit idempotent contact request: %w", err)
			}
			return existing, nil
		}
		accepted, err := acceptLoadedRequest(ctx, tx, existing, principal.UserID, principal.DeviceID, now)
		if err != nil {
			return ContactRequest{}, err
		}
		if err := tx.Commit(ctx); err != nil {
			return ContactRequest{}, fmt.Errorf("commit mutual contact request: %w", err)
		}
		return accepted, nil
	}

	if err := consumeRateLimitTx(ctx, tx, principal.UserID, "CONTACT_REQUEST", now, contactRequestWindow, contactRequestLimit); err != nil {
		return ContactRequest{}, err
	}

	var requestID uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO contact_requests (sender_user_id, receiver_user_id, message, status, created_at, expires_at)
		VALUES ($1, $2, $3, 'PENDING', $4, $5)
		RETURNING id
	`, principal.UserID, targetID, message, now, now.Add(requestTTL)).Scan(&requestID); err != nil {
		return ContactRequest{}, fmt.Errorf("create contact request: %w", err)
	}
	result, err := loadRequestByID(ctx, tx, requestID)
	if err != nil {
		return ContactRequest{}, err
	}
	pushPayload, err := json.Marshal(map[string]any{
		"requestId":    requestID.String(),
		"senderUserId": principal.UserID.String(),
		"senderName":   result.Sender.DisplayName,
	})
	if err != nil {
		return ContactRequest{}, fmt.Errorf("marshal contact request push: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO push_jobs(recipient_user_id,event_type,resource_id,actor_user_id,dedupe_key,payload_json,status,available_at,created_at)
		VALUES($1,'CONTACT_REQUEST_CREATED',$2,$3,$4,$5::jsonb,'PENDING',$6,$6)
		ON CONFLICT(dedupe_key) DO NOTHING
	`, targetID, requestID, principal.UserID, "contact-request:"+requestID.String()+":user:"+targetID.String(), string(pushPayload), now); err != nil {
		return ContactRequest{}, fmt.Errorf("enqueue contact request push: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return ContactRequest{}, fmt.Errorf("commit contact request: %w", err)
	}
	return result, nil
}

func (service *Service) AcceptRequest(ctx context.Context, principal account.Principal, requestID uuid.UUID) (ContactRequest, error) {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		result, err := service.acceptRequestOnce(ctx, principal, requestID)
		if err == nil {
			return result, nil
		}
		lastErr = err
		if !isSerializationFailure(err) {
			return ContactRequest{}, err
		}
	}
	return ContactRequest{}, lastErr
}

func (service *Service) acceptRequestOnce(ctx context.Context, principal account.Principal, requestID uuid.UUID) (ContactRequest, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return ContactRequest{}, fmt.Errorf("begin accept contact request: %w", err)
	}
	defer tx.Rollback(ctx)

	request, err := loadRequestByIDForUpdate(ctx, tx, requestID)
	if err != nil {
		return ContactRequest{}, err
	}
	if request.Receiver.ID != principal.UserID.String() {
		return ContactRequest{}, ErrForbidden
	}
	if request.Status == "ACCEPTED" {
		conversationID, err := ensureDirectConversationForRequest(ctx, tx, request, now)
		if err != nil {
			return ContactRequest{}, err
		}
		request.ConversationID = &conversationID
		if err := tx.Commit(ctx); err != nil {
			return ContactRequest{}, fmt.Errorf("commit idempotent accept: %w", err)
		}
		return request, nil
	}
	if request.Status != "PENDING" {
		return ContactRequest{}, ErrInvalidState
	}
	if !request.ExpiresAt.After(now) {
		if _, err := tx.Exec(ctx, `UPDATE contact_requests SET status='EXPIRED', resolved_at=$2 WHERE id=$1 AND status='PENDING'`, requestID, now); err != nil {
			return ContactRequest{}, fmt.Errorf("expire contact request: %w", err)
		}
		if err := tx.Commit(ctx); err != nil {
			return ContactRequest{}, fmt.Errorf("commit expired contact request: %w", err)
		}
		return ContactRequest{}, ErrInvalidState
	}
	if err := lockPair(ctx, tx, mustUUID(request.Sender.ID), mustUUID(request.Receiver.ID)); err != nil {
		return ContactRequest{}, err
	}
	accepted, err := acceptLoadedRequest(ctx, tx, request, principal.UserID, principal.DeviceID, now)
	if err != nil {
		return ContactRequest{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return ContactRequest{}, fmt.Errorf("commit accepted contact request: %w", err)
	}
	return accepted, nil
}

func (service *Service) RejectRequest(ctx context.Context, principal account.Principal, requestID uuid.UUID) (ContactRequest, error) {
	return service.resolveRequest(ctx, principal, requestID, "REJECTED", true)
}

func (service *Service) CancelRequest(ctx context.Context, principal account.Principal, requestID uuid.UUID) (ContactRequest, error) {
	return service.resolveRequest(ctx, principal, requestID, "CANCELLED", false)
}

func (service *Service) resolveRequest(ctx context.Context, principal account.Principal, requestID uuid.UUID, nextStatus string, receiverAction bool) (ContactRequest, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return ContactRequest{}, fmt.Errorf("begin resolve contact request: %w", err)
	}
	defer tx.Rollback(ctx)

	request, err := loadRequestByIDForUpdate(ctx, tx, requestID)
	if err != nil {
		return ContactRequest{}, err
	}
	expectedActor := request.Sender.ID
	if receiverAction {
		expectedActor = request.Receiver.ID
	}
	if expectedActor != principal.UserID.String() {
		return ContactRequest{}, ErrForbidden
	}
	if request.Status == nextStatus {
		if err := tx.Commit(ctx); err != nil {
			return ContactRequest{}, fmt.Errorf("commit idempotent request resolution: %w", err)
		}
		return request, nil
	}
	if request.Status != "PENDING" {
		return ContactRequest{}, ErrInvalidState
	}
	if !request.ExpiresAt.After(now) {
		nextStatus = "EXPIRED"
	}
	if _, err := tx.Exec(ctx, `UPDATE contact_requests SET status=$2, resolved_at=$3 WHERE id=$1`, requestID, nextStatus, now); err != nil {
		return ContactRequest{}, fmt.Errorf("resolve contact request: %w", err)
	}
	request.Status = nextStatus
	request.ResolvedAt = &now
	if err := tx.Commit(ctx); err != nil {
		return ContactRequest{}, fmt.Errorf("commit contact request resolution: %w", err)
	}
	if nextStatus == "EXPIRED" {
		return ContactRequest{}, ErrInvalidState
	}
	return request, nil
}

func (service *Service) ListRequests(ctx context.Context, principal account.Principal, direction string, page, pageSize int) (Page[ContactRequest], error) {
	direction = strings.ToLower(strings.TrimSpace(direction))
	if direction != "incoming" && direction != "outgoing" {
		return Page[ContactRequest]{}, errors.New("direction must be incoming or outgoing")
	}
	page, pageSize = normalizePage(page, pageSize)
	now := service.now().UTC()
	if _, err := service.pool.Exec(ctx, `
		UPDATE contact_requests SET status='EXPIRED', resolved_at=$2
		WHERE status='PENDING' AND expires_at <= $2 AND (sender_user_id=$1 OR receiver_user_id=$1)
	`, principal.UserID, now); err != nil {
		return Page[ContactRequest]{}, fmt.Errorf("expire contact requests: %w", err)
	}

	column := "receiver_user_id"
	if direction == "outgoing" {
		column = "sender_user_id"
	}
	var total int
	if err := service.pool.QueryRow(ctx, `SELECT count(*) FROM contact_requests WHERE `+column+` = $1`, principal.UserID).Scan(&total); err != nil {
		return Page[ContactRequest]{}, fmt.Errorf("count contact requests: %w", err)
	}
	rows, err := service.pool.Query(ctx, `
		SELECT r.id,
		       su.id, su.handle_normalized, su.display_name, su.bio,
		       ru.id, ru.handle_normalized, ru.display_name, ru.bio,
		       r.message, r.status, r.created_at, r.expires_at, r.resolved_at
		FROM contact_requests r
		JOIN users su ON su.id = r.sender_user_id
		JOIN users ru ON ru.id = r.receiver_user_id
		WHERE r.`+column+` = $1
		ORDER BY r.created_at DESC, r.id DESC
		LIMIT $2 OFFSET $3
	`, principal.UserID, pageSize, (page-1)*pageSize)
	if err != nil {
		return Page[ContactRequest]{}, fmt.Errorf("list contact requests: %w", err)
	}
	defer rows.Close()
	items := make([]ContactRequest, 0, pageSize)
	for rows.Next() {
		var item ContactRequest
		if err := scanRequest(rows, &item); err != nil {
			return Page[ContactRequest]{}, fmt.Errorf("scan contact request: %w", err)
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return Page[ContactRequest]{}, fmt.Errorf("iterate contact requests: %w", err)
	}
	return makePage(items, page, pageSize, total), nil
}

func (service *Service) ListContacts(ctx context.Context, principal account.Principal, page, pageSize int) (Page[Contact], error) {
	page, pageSize = normalizePage(page, pageSize)
	var total int
	if err := service.pool.QueryRow(ctx, `SELECT count(*) FROM contacts WHERE owner_user_id=$1`, principal.UserID).Scan(&total); err != nil {
		return Page[Contact]{}, fmt.Errorf("count contacts: %w", err)
	}
	rows, err := service.pool.Query(ctx, `
		SELECT u.id, u.handle_normalized, u.display_name, u.bio,
		       c.remark, c.is_starred,
		       COALESCE(array_agg(t.tag_name ORDER BY t.tag_name) FILTER (WHERE t.tag_name IS NOT NULL), ARRAY[]::varchar[]),
		       c.created_at, c.updated_at
		FROM contacts c
		JOIN users u ON u.id = c.contact_user_id AND u.status = 'ACTIVE'
		LEFT JOIN contact_tags t ON t.owner_user_id = c.owner_user_id AND t.contact_user_id = c.contact_user_id
		WHERE c.owner_user_id = $1
		GROUP BY u.id, u.handle_normalized, u.display_name, u.bio, c.contact_user_id, c.remark, c.is_starred, c.created_at, c.updated_at
		ORDER BY c.is_starred DESC, COALESCE(NULLIF(c.remark,''), u.display_name), c.created_at DESC, c.contact_user_id
		LIMIT $2 OFFSET $3
	`, principal.UserID, pageSize, (page-1)*pageSize)
	if err != nil {
		return Page[Contact]{}, fmt.Errorf("list contacts: %w", err)
	}
	defer rows.Close()
	items := make([]Contact, 0, pageSize)
	for rows.Next() {
		var item Contact
		if err := rows.Scan(&item.User.ID, &item.User.Handle, &item.User.DisplayName, &item.User.Bio, &item.Remark, &item.IsStarred, &item.Tags, &item.CreatedAt, &item.UpdatedAt); err != nil {
			return Page[Contact]{}, fmt.Errorf("scan contact: %w", err)
		}
		if item.Tags == nil {
			item.Tags = []string{}
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return Page[Contact]{}, fmt.Errorf("iterate contacts: %w", err)
	}
	return makePage(items, page, pageSize, total), nil
}

func (service *Service) AddContact(ctx context.Context, principal account.Principal, contactUserID uuid.UUID) (Contact, error) {
	if contactUserID == uuid.Nil || contactUserID == principal.UserID {
		return Contact{}, ErrInvalidState
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return Contact{}, fmt.Errorf("begin add contact: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := lockPair(ctx, tx, principal.UserID, contactUserID); err != nil {
		return Contact{}, err
	}
	var active bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE id=$1 AND status='ACTIVE')`, contactUserID).Scan(&active); err != nil {
		return Contact{}, fmt.Errorf("load contact target: %w", err)
	}
	if !active {
		return Contact{}, ErrNotFound
	}
	if blocked, err := isBlockedBetweenTx(ctx, tx, principal.UserID, contactUserID); err != nil {
		return Contact{}, err
	} else if blocked {
		return Contact{}, ErrBlocked
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO contacts(owner_user_id,contact_user_id,remark,is_starred,created_at,updated_at)
		VALUES ($1,$2,'',false,$3,$3)
		ON CONFLICT (owner_user_id,contact_user_id) DO NOTHING
	`, principal.UserID, contactUserID, now); err != nil {
		return Contact{}, fmt.Errorf("add contact: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Contact{}, fmt.Errorf("commit add contact: %w", err)
	}
	return service.getContact(ctx, principal.UserID, contactUserID)
}

func (service *Service) UpdateContact(ctx context.Context, principal account.Principal, contactUserID uuid.UUID, raw UpdateContactInput) (Contact, error) {
	if contactUserID == principal.UserID {
		return Contact{}, ErrInvalidState
	}
	remark := raw.Remark
	if remark != nil {
		normalized, err := normalizeBoundedText(*remark, maximumRemarkLength, true, "contact remark")
		if err != nil {
			return Contact{}, err
		}
		remark = &normalized
	}
	var normalizedTags []tagValue
	if raw.Tags != nil {
		var err error
		normalizedTags, err = normalizeTags(*raw.Tags)
		if err != nil {
			return Contact{}, err
		}
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return Contact{}, fmt.Errorf("begin update contact: %w", err)
	}
	defer tx.Rollback(ctx)

	var exists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM contacts WHERE owner_user_id=$1 AND contact_user_id=$2)`, principal.UserID, contactUserID).Scan(&exists); err != nil {
		return Contact{}, fmt.Errorf("check contact ownership: %w", err)
	}
	if !exists {
		return Contact{}, ErrNotFound
	}
	if remark != nil {
		if _, err := tx.Exec(ctx, `UPDATE contacts SET remark=$3, updated_at=$4 WHERE owner_user_id=$1 AND contact_user_id=$2`, principal.UserID, contactUserID, *remark, now); err != nil {
			return Contact{}, fmt.Errorf("update contact remark: %w", err)
		}
	}
	if raw.IsStarred != nil {
		if _, err := tx.Exec(ctx, `UPDATE contacts SET is_starred=$3, updated_at=$4 WHERE owner_user_id=$1 AND contact_user_id=$2`, principal.UserID, contactUserID, *raw.IsStarred, now); err != nil {
			return Contact{}, fmt.Errorf("update contact starred: %w", err)
		}
	}
	if raw.Tags != nil {
		if _, err := tx.Exec(ctx, `DELETE FROM contact_tags WHERE owner_user_id=$1 AND contact_user_id=$2`, principal.UserID, contactUserID); err != nil {
			return Contact{}, fmt.Errorf("replace contact tags: %w", err)
		}
		for _, tag := range normalizedTags {
			if _, err := tx.Exec(ctx, `INSERT INTO contact_tags (owner_user_id, contact_user_id, tag_normalized, tag_name, created_at) VALUES ($1,$2,$3,$4,$5)`, principal.UserID, contactUserID, tag.Normalized, tag.Name, now); err != nil {
				return Contact{}, fmt.Errorf("insert contact tag: %w", err)
			}
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Contact{}, fmt.Errorf("commit update contact: %w", err)
	}
	return service.getContact(ctx, principal.UserID, contactUserID)
}

func (service *Service) DeleteContact(ctx context.Context, principal account.Principal, contactUserID uuid.UUID) error {
	if contactUserID == principal.UserID {
		return ErrInvalidState
	}
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return fmt.Errorf("begin delete contact: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := lockPair(ctx, tx, principal.UserID, contactUserID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		DELETE FROM contacts
		WHERE (owner_user_id=$1 AND contact_user_id=$2) OR (owner_user_id=$2 AND contact_user_id=$1)
	`, principal.UserID, contactUserID); err != nil {
		return fmt.Errorf("delete contact pair: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit delete contact: %w", err)
	}
	return nil
}

func (service *Service) BlockUser(ctx context.Context, principal account.Principal, blockedUserID uuid.UUID) (BlockedUser, error) {
	if blockedUserID == principal.UserID {
		return BlockedUser{}, ErrInvalidState
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return BlockedUser{}, fmt.Errorf("begin block user: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := lockPair(ctx, tx, principal.UserID, blockedUserID); err != nil {
		return BlockedUser{}, err
	}
	var target PublicUser
	if err := tx.QueryRow(ctx, `SELECT id,handle_normalized,display_name,bio FROM users WHERE id=$1 AND status='ACTIVE'`, blockedUserID).Scan(&target.ID, &target.Handle, &target.DisplayName, &target.Bio); errors.Is(err, pgx.ErrNoRows) {
		return BlockedUser{}, ErrNotFound
	} else if err != nil {
		return BlockedUser{}, fmt.Errorf("load block target: %w", err)
	}
	blockResult, err := tx.Exec(ctx, `INSERT INTO blocks (owner_user_id,blocked_user_id,created_at) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, principal.UserID, blockedUserID, now)
	if err != nil {
		return BlockedUser{}, fmt.Errorf("create block: %w", err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM contacts WHERE (owner_user_id=$1 AND contact_user_id=$2) OR (owner_user_id=$2 AND contact_user_id=$1)`, principal.UserID, blockedUserID); err != nil {
		return BlockedUser{}, fmt.Errorf("remove contacts while blocking: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE contact_requests SET status='CANCELLED', resolved_at=$3
		WHERE status='PENDING' AND ((sender_user_id=$1 AND receiver_user_id=$2) OR (sender_user_id=$2 AND receiver_user_id=$1))
	`, principal.UserID, blockedUserID, now); err != nil {
		return BlockedUser{}, fmt.Errorf("cancel contact requests while blocking: %w", err)
	}
	if blockResult.RowsAffected() > 0 {
		payload, _ := json.Marshal(map[string]any{
			"blockedByUserId": principal.UserID.String(),
		})
		if _, err := tx.Exec(ctx, `
			INSERT INTO outbox_events(
				aggregate_type,aggregate_id,event_type,target_user_id,
				payload_json,created_at,available_at
			)
			VALUES('RELATIONSHIP',$1,'RELATIONSHIP_BLOCKED_BY_PEER',$2,$3::jsonb,$4,$4)
		`, principal.UserID, blockedUserID, string(payload), now); err != nil {
			return BlockedUser{}, fmt.Errorf("insert block relationship outbox: %w", err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return BlockedUser{}, fmt.Errorf("commit block user: %w", err)
	}
	return BlockedUser{User: target, CreatedAt: now}, nil
}

func (service *Service) UnblockUser(ctx context.Context, principal account.Principal, blockedUserID uuid.UUID) error {
	result, err := service.pool.Exec(ctx, `DELETE FROM blocks WHERE owner_user_id=$1 AND blocked_user_id=$2`, principal.UserID, blockedUserID)
	if err != nil {
		return fmt.Errorf("delete block: %w", err)
	}
	if result.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (service *Service) ListBlocks(ctx context.Context, principal account.Principal, page, pageSize int) (Page[BlockedUser], error) {
	page, pageSize = normalizePage(page, pageSize)
	var total int
	if err := service.pool.QueryRow(ctx, `SELECT count(*) FROM blocks WHERE owner_user_id=$1`, principal.UserID).Scan(&total); err != nil {
		return Page[BlockedUser]{}, fmt.Errorf("count blocks: %w", err)
	}
	rows, err := service.pool.Query(ctx, `
		SELECT u.id,u.handle_normalized,u.display_name,u.bio,b.created_at
		FROM blocks b JOIN users u ON u.id=b.blocked_user_id
		WHERE b.owner_user_id=$1
		ORDER BY b.created_at DESC,b.blocked_user_id
		LIMIT $2 OFFSET $3
	`, principal.UserID, pageSize, (page-1)*pageSize)
	if err != nil {
		return Page[BlockedUser]{}, fmt.Errorf("list blocks: %w", err)
	}
	defer rows.Close()
	items := make([]BlockedUser, 0, pageSize)
	for rows.Next() {
		var item BlockedUser
		if err := rows.Scan(&item.User.ID, &item.User.Handle, &item.User.DisplayName, &item.User.Bio, &item.CreatedAt); err != nil {
			return Page[BlockedUser]{}, fmt.Errorf("scan block: %w", err)
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return Page[BlockedUser]{}, fmt.Errorf("iterate blocks: %w", err)
	}
	return makePage(items, page, pageSize, total), nil
}

func (service *Service) IsBlockedBetween(ctx context.Context, a, b uuid.UUID) (bool, error) {
	var blocked bool
	if err := service.pool.QueryRow(ctx, `
		SELECT EXISTS(
			SELECT 1 FROM blocks
			WHERE (owner_user_id=$1 AND blocked_user_id=$2) OR (owner_user_id=$2 AND blocked_user_id=$1)
		)
	`, a, b).Scan(&blocked); err != nil {
		return false, fmt.Errorf("check block relationship: %w", err)
	}
	return blocked, nil
}

func (service *Service) getContact(ctx context.Context, ownerID, contactID uuid.UUID) (Contact, error) {
	var item Contact
	err := service.pool.QueryRow(ctx, `
		SELECT u.id,u.handle_normalized,u.display_name,u.bio,c.remark,c.is_starred,
		       COALESCE(array_agg(t.tag_name ORDER BY t.tag_name) FILTER (WHERE t.tag_name IS NOT NULL), ARRAY[]::varchar[]),
		       c.created_at,c.updated_at
		FROM contacts c
		JOIN users u ON u.id=c.contact_user_id
		LEFT JOIN contact_tags t ON t.owner_user_id=c.owner_user_id AND t.contact_user_id=c.contact_user_id
		WHERE c.owner_user_id=$1 AND c.contact_user_id=$2
		GROUP BY u.id,u.handle_normalized,u.display_name,u.bio,c.remark,c.is_starred,c.created_at,c.updated_at
	`, ownerID, contactID).Scan(&item.User.ID, &item.User.Handle, &item.User.DisplayName, &item.User.Bio, &item.Remark, &item.IsStarred, &item.Tags, &item.CreatedAt, &item.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Contact{}, ErrNotFound
	}
	if err != nil {
		return Contact{}, fmt.Errorf("load contact: %w", err)
	}
	if item.Tags == nil {
		item.Tags = []string{}
	}
	return item, nil
}

func (service *Service) consumeRateLimit(ctx context.Context, userID uuid.UUID, scope string, window time.Duration, limit int) error {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("begin relationship rate limit: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := consumeRateLimitTx(ctx, tx, userID, scope, now, window, limit); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit relationship rate limit: %w", err)
	}
	return nil
}

func consumeRateLimitTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, scope string, now time.Time, window time.Duration, limit int) error {
	lockKey := userID.String() + ":" + scope
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, lockKey); err != nil {
		return fmt.Errorf("lock relationship rate limit: %w", err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM relationship_rate_events WHERE user_id=$1 AND scope=$2 AND created_at < $3`, userID, scope, now.Add(-2*window)); err != nil {
		return fmt.Errorf("prune relationship rate events: %w", err)
	}
	var count int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM relationship_rate_events WHERE user_id=$1 AND scope=$2 AND created_at >= $3`, userID, scope, now.Add(-window)).Scan(&count); err != nil {
		return fmt.Errorf("count relationship rate events: %w", err)
	}
	if count >= limit {
		return ErrRateLimited
	}
	if _, err := tx.Exec(ctx, `INSERT INTO relationship_rate_events (user_id,scope,created_at) VALUES ($1,$2,$3)`, userID, scope, now); err != nil {
		return fmt.Errorf("record relationship rate event: %w", err)
	}
	return nil
}

func acceptLoadedRequest(ctx context.Context, tx pgx.Tx, request ContactRequest, actorID, actorDeviceID uuid.UUID, now time.Time) (ContactRequest, error) {
	if request.Status != "PENDING" {
		return ContactRequest{}, ErrInvalidState
	}
	if request.Receiver.ID != actorID.String() {
		return ContactRequest{}, ErrForbidden
	}
	senderID := mustUUID(request.Sender.ID)
	receiverID := mustUUID(request.Receiver.ID)
	if blocked, err := isBlockedBetweenTx(ctx, tx, senderID, receiverID); err != nil {
		return ContactRequest{}, err
	} else if blocked {
		return ContactRequest{}, ErrBlocked
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO contacts (owner_user_id,contact_user_id,created_at,updated_at)
		VALUES ($1,$2,$3,$3),($2,$1,$3,$3)
		ON CONFLICT (owner_user_id,contact_user_id) DO NOTHING
	`, senderID, receiverID, now); err != nil {
		return ContactRequest{}, fmt.Errorf("create bidirectional contacts: %w", err)
	}
	conversationID, err := ensureDirectConversation(ctx, tx, senderID, receiverID, now)
	if err != nil {
		return ContactRequest{}, err
	}
	requestID := mustUUID(request.ID)
	if _, err := tx.Exec(ctx, `UPDATE contact_requests SET status='ACCEPTED',resolved_at=$2 WHERE id=$1 AND status='PENDING'`, requestID, now); err != nil {
		return ContactRequest{}, fmt.Errorf("accept contact request: %w", err)
	}
	request.Status = "ACCEPTED"
	request.ResolvedAt = &now
	request.ConversationID = &conversationID
	if err := insertFriendAcceptedSystemMessage(ctx, tx, mustUUID(conversationID), actorID, actorDeviceID, requestID, now); err != nil {
		return ContactRequest{}, err
	}
	return request, nil
}

func insertFriendAcceptedSystemMessage(ctx context.Context, tx pgx.Tx, conversationID, actorID, actorDeviceID, requestID uuid.UUID, now time.Time) error {
	var sequence int64
	if err := tx.QueryRow(ctx, `
		UPDATE conversations SET last_sequence=last_sequence+1,updated_at=$2
		WHERE id=$1 RETURNING last_sequence
	`, conversationID, now).Scan(&sequence); err != nil {
		return fmt.Errorf("allocate friend accepted message sequence: %w", err)
	}
	content, _ := json.Marshal(map[string]any{"text": "我刚刚同意了你的好友请求"})
	var messageID uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO messages(conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,created_at)
		VALUES($1,$2,$3,$4,$5,'SYSTEM',$6::jsonb,$7)
		RETURNING id
	`, conversationID, sequence, actorID, actorDeviceID, "friend-accept-"+requestID.String(), string(content), now).Scan(&messageID); err != nil {
		return fmt.Errorf("insert friend accepted system message: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE conversations SET last_message_id=$2 WHERE id=$1`, conversationID, messageID); err != nil {
		return fmt.Errorf("update friend accepted conversation last message: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE conversation_members
		SET archived_at=NULL
		WHERE conversation_id=$1 AND user_id<>$2 AND archived_at IS NOT NULL
		  AND (muted_until IS NULL OR muted_until<=$3)
	`, conversationID, actorID, now); err != nil {
		return fmt.Errorf("wake friend accepted conversation: %w", err)
	}
	payload, _ := json.Marshal(map[string]any{
		"messageId":      messageID.String(),
		"conversationId": conversationID.String(),
		"sequence":       sequence,
	})
	if _, err := tx.Exec(ctx, `
		INSERT INTO outbox_events(aggregate_type,aggregate_id,event_type,conversation_id,sequence,payload_json,created_at,available_at)
		VALUES('MESSAGE',$1,'MESSAGE_CREATED',$2,$3,$4::jsonb,$5,$5)
	`, messageID, conversationID, sequence, string(payload), now); err != nil {
		return fmt.Errorf("insert friend accepted outbox: %w", err)
	}
	return nil
}

func ensureDirectConversationForRequest(ctx context.Context, tx pgx.Tx, request ContactRequest, now time.Time) (string, error) {
	return ensureDirectConversation(ctx, tx, mustUUID(request.Sender.ID), mustUUID(request.Receiver.ID), now)
}

func ensureDirectConversation(ctx context.Context, tx pgx.Tx, a, b uuid.UUID, now time.Time) (string, error) {
	pairKey := directPairKey(a, b)
	var conversationID uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO conversations (type,direct_pair_key,created_at,updated_at)
		VALUES ('DIRECT',$1,$2,$2)
		ON CONFLICT (direct_pair_key) DO UPDATE SET direct_pair_key=EXCLUDED.direct_pair_key
		RETURNING id
	`, pairKey, now).Scan(&conversationID); err != nil {
		return "", fmt.Errorf("ensure direct conversation: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO conversation_members (conversation_id,user_id,role,status,joined_at,left_at,last_read_sequence)
		VALUES ($1,$2,'MEMBER','ACTIVE',$4,NULL,0),($1,$3,'MEMBER','ACTIVE',$4,NULL,0)
		ON CONFLICT (conversation_id,user_id) DO UPDATE SET status='ACTIVE',left_at=NULL
	`, conversationID, a, b, now); err != nil {
		return "", fmt.Errorf("ensure direct conversation members: %w", err)
	}
	return conversationID.String(), nil
}

func loadPendingPairRequest(ctx context.Context, tx pgx.Tx, a, b uuid.UUID) (ContactRequest, bool, error) {
	row := tx.QueryRow(ctx, `
		SELECT r.id,
		       su.id, su.handle_normalized, su.display_name, su.bio,
		       ru.id, ru.handle_normalized, ru.display_name, ru.bio,
		       r.message, r.status, r.created_at, r.expires_at, r.resolved_at
		FROM contact_requests r
		JOIN users su ON su.id=r.sender_user_id
		JOIN users ru ON ru.id=r.receiver_user_id
		WHERE r.status='PENDING' AND ((r.sender_user_id=$1 AND r.receiver_user_id=$2) OR (r.sender_user_id=$2 AND r.receiver_user_id=$1))
		LIMIT 1
	`, a, b)
	var request ContactRequest
	if err := scanRequest(row, &request); errors.Is(err, pgx.ErrNoRows) {
		return ContactRequest{}, false, nil
	} else if err != nil {
		return ContactRequest{}, false, fmt.Errorf("load pending contact request: %w", err)
	}
	return request, true, nil
}

func loadRequestByID(ctx context.Context, tx pgx.Tx, requestID uuid.UUID) (ContactRequest, error) {
	row := tx.QueryRow(ctx, `
		SELECT r.id,
		       su.id, su.handle_normalized, su.display_name, su.bio,
		       ru.id, ru.handle_normalized, ru.display_name, ru.bio,
		       r.message, r.status, r.created_at, r.expires_at, r.resolved_at
		FROM contact_requests r
		JOIN users su ON su.id=r.sender_user_id
		JOIN users ru ON ru.id=r.receiver_user_id
		WHERE r.id=$1
	`, requestID)
	var request ContactRequest
	if err := scanRequest(row, &request); errors.Is(err, pgx.ErrNoRows) {
		return ContactRequest{}, ErrNotFound
	} else if err != nil {
		return ContactRequest{}, fmt.Errorf("load contact request: %w", err)
	}
	return request, nil
}

func loadRequestByIDForUpdate(ctx context.Context, tx pgx.Tx, requestID uuid.UUID) (ContactRequest, error) {
	row := tx.QueryRow(ctx, `
		SELECT r.id,
		       su.id, su.handle_normalized, su.display_name, su.bio,
		       ru.id, ru.handle_normalized, ru.display_name, ru.bio,
		       r.message, r.status, r.created_at, r.expires_at, r.resolved_at
		FROM contact_requests r
		JOIN users su ON su.id=r.sender_user_id
		JOIN users ru ON ru.id=r.receiver_user_id
		WHERE r.id=$1
		FOR UPDATE OF r
	`, requestID)
	var request ContactRequest
	if err := scanRequest(row, &request); errors.Is(err, pgx.ErrNoRows) {
		return ContactRequest{}, ErrNotFound
	} else if err != nil {
		return ContactRequest{}, fmt.Errorf("lock contact request: %w", err)
	}
	return request, nil
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanRequest(row rowScanner, item *ContactRequest) error {
	return row.Scan(
		&item.ID,
		&item.Sender.ID, &item.Sender.Handle, &item.Sender.DisplayName, &item.Sender.Bio,
		&item.Receiver.ID, &item.Receiver.Handle, &item.Receiver.DisplayName, &item.Receiver.Bio,
		&item.Message, &item.Status, &item.CreatedAt, &item.ExpiresAt, &item.ResolvedAt,
	)
}

func expirePairRequests(ctx context.Context, tx pgx.Tx, a, b uuid.UUID, now time.Time) error {
	if _, err := tx.Exec(ctx, `
		UPDATE contact_requests SET status='EXPIRED',resolved_at=$3
		WHERE status='PENDING' AND expires_at <= $3
		  AND ((sender_user_id=$1 AND receiver_user_id=$2) OR (sender_user_id=$2 AND receiver_user_id=$1))
	`, a, b, now); err != nil {
		return fmt.Errorf("expire pair contact requests: %w", err)
	}
	return nil
}

func isBlockedBetweenTx(ctx context.Context, tx pgx.Tx, a, b uuid.UUID) (bool, error) {
	var blocked bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM blocks WHERE (owner_user_id=$1 AND blocked_user_id=$2) OR (owner_user_id=$2 AND blocked_user_id=$1))`, a, b).Scan(&blocked); err != nil {
		return false, fmt.Errorf("check pair block: %w", err)
	}
	return blocked, nil
}

func lockPair(ctx context.Context, tx pgx.Tx, a, b uuid.UUID) error {
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, directPairKey(a, b)); err != nil {
		return fmt.Errorf("lock relationship pair: %w", err)
	}
	return nil
}

func directPairKey(a, b uuid.UUID) string {
	left, right := a.String(), b.String()
	if right < left {
		left, right = right, left
	}
	return left + ":" + right
}

func mustUUID(value string) uuid.UUID {
	parsed, err := uuid.Parse(value)
	if err != nil {
		panic("database returned invalid uuid: " + value)
	}
	return parsed
}

func normalizeBoundedText(raw string, maxRunes int, allowEmpty bool, field string) (string, error) {
	value := strings.TrimSpace(norm.NFKC.String(raw))
	if value == "" && !allowEmpty {
		return "", fmt.Errorf("%s is required", field)
	}
	if utf8.RuneCountInString(value) > maxRunes {
		return "", fmt.Errorf("%s exceeds %d characters", field, maxRunes)
	}
	return value, nil
}

type tagValue struct {
	Name       string
	Normalized string
}

func normalizeTags(raw []string) ([]tagValue, error) {
	if len(raw) > maximumTagsPerContact {
		return nil, fmt.Errorf("contact tags exceed %d items", maximumTagsPerContact)
	}
	result := make([]tagValue, 0, len(raw))
	seen := make(map[string]struct{}, len(raw))
	for _, value := range raw {
		name, err := normalizeBoundedText(value, maximumTagLength, false, "contact tag")
		if err != nil {
			return nil, err
		}
		normalized := strings.ToLower(norm.NFKC.String(name))
		if _, exists := seen[normalized]; exists {
			continue
		}
		seen[normalized] = struct{}{}
		result = append(result, tagValue{Name: name, Normalized: normalized})
	}
	return result, nil
}

func normalizePage(page, pageSize int) (int, int) {
	if page < 1 {
		page = 1
	}
	if pageSize < 1 {
		pageSize = defaultPageSize
	}
	if pageSize > maximumPageSize {
		pageSize = maximumPageSize
	}
	return page, pageSize
}

func isSerializationFailure(err error) bool {
	var postgresError *pgconn.PgError
	return errors.As(err, &postgresError) && postgresError.Code == "40001"
}

func makePage[T any](items []T, page, pageSize, total int) Page[T] {
	totalPages := 0
	if total > 0 {
		totalPages = (total + pageSize - 1) / pageSize
	}
	return Page[T]{Items: items, Page: page, PageSize: pageSize, TotalItems: total, TotalPages: totalPages}
}
