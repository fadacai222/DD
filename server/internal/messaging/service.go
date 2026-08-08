package messaging

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Service struct {
	pool *pgxpool.Pool
	now  func() time.Time
}

type Config struct {
	Pool *pgxpool.Pool
	Now  func() time.Time
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

func (service *Service) EnsureDirectConversation(ctx context.Context, principal account.Principal, targetUserID uuid.UUID) (Conversation, error) {
	if targetUserID == uuid.Nil || targetUserID == principal.UserID {
		return Conversation{}, ErrInvalidInput
	}
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		result, err := service.ensureDirectConversationOnce(ctx, principal, targetUserID)
		if err == nil {
			return result, nil
		}
		lastErr = err
		if !isSerializationFailure(err) {
			return Conversation{}, err
		}
	}
	return Conversation{}, lastErr
}

func (service *Service) ensureDirectConversationOnce(ctx context.Context, principal account.Principal, targetUserID uuid.UUID) (Conversation, error) {
	now := service.now().UTC()
	pairKey := directPairKey(principal.UserID, targetUserID)
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return Conversation{}, fmt.Errorf("begin direct conversation: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, pairKey); err != nil {
		return Conversation{}, fmt.Errorf("lock direct conversation pair: %w", err)
	}

	var active bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE id=$1 AND status='ACTIVE')`, targetUserID).Scan(&active); err != nil {
		return Conversation{}, fmt.Errorf("load direct target: %w", err)
	}
	if !active {
		return Conversation{}, ErrNotFound
	}
	if blocked, err := isBlockedBetweenTx(ctx, tx, principal.UserID, targetUserID); err != nil {
		return Conversation{}, err
	} else if blocked {
		return Conversation{}, ErrBlocked
	}
	if allowed, err := canStartOrWriteDirectTx(ctx, tx, principal.UserID, targetUserID); err != nil {
		return Conversation{}, err
	} else if !allowed {
		return Conversation{}, ErrForbidden
	}

	var conversationID uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO conversations(type,direct_pair_key,created_at,updated_at)
		VALUES ('DIRECT',$1,$2,$2)
		ON CONFLICT (direct_pair_key) DO UPDATE SET updated_at=conversations.updated_at
		RETURNING id
	`, pairKey, now).Scan(&conversationID); err != nil {
		return Conversation{}, fmt.Errorf("ensure direct conversation: %w", err)
	}
	for _, userID := range []uuid.UUID{principal.UserID, targetUserID} {
		if _, err := tx.Exec(ctx, `
			INSERT INTO conversation_members(conversation_id,user_id,role,status,joined_at,left_at,last_read_sequence)
			VALUES ($1,$2,'MEMBER','ACTIVE',$3,NULL,0)
			ON CONFLICT (conversation_id,user_id) DO UPDATE
			SET status='ACTIVE', left_at=NULL
		`, conversationID, userID, now); err != nil {
			return Conversation{}, fmt.Errorf("ensure direct member: %w", err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Conversation{}, fmt.Errorf("commit direct conversation: %w", err)
	}
	return service.GetConversation(ctx, principal, conversationID)
}

func (service *Service) ListConversations(ctx context.Context, principal account.Principal, limit int) ([]Conversation, error) {
	if limit == 0 {
		limit = 100
	}
	if limit < 1 || limit > 100 {
		return nil, ErrInvalidInput
	}
	rows, err := service.pool.Query(ctx, `
		SELECT c.id,c.type,c.last_sequence,m.last_read_sequence,m.muted_until,m.is_pinned,c.created_at,c.updated_at
		FROM conversation_members m
		JOIN conversations c ON c.id=m.conversation_id
		WHERE m.user_id=$1 AND m.status='ACTIVE'
		ORDER BY m.is_pinned DESC,c.updated_at DESC,c.id DESC
		LIMIT $2
	`, principal.UserID, limit)
	if err != nil {
		return nil, fmt.Errorf("list conversations: %w", err)
	}
	defer rows.Close()

	result := make([]Conversation, 0, limit)
	for rows.Next() {
		var item Conversation
		if err := rows.Scan(&item.ID, &item.Type, &item.LastSequence, &item.LastReadSequence, &item.Preferences.MutedUntil, &item.Preferences.IsPinned, &item.CreatedAt, &item.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scan conversation: %w", err)
		}
		item.UnreadCount = item.LastSequence - item.LastReadSequence
		if item.UnreadCount < 0 {
			item.UnreadCount = 0
		}
		conversationID := uuid.MustParse(item.ID)
		if item.Type == "DIRECT" {
			peer, peerLastReadSequence, err := service.loadDirectPeerState(ctx, conversationID, principal.UserID)
			if err != nil {
				return nil, err
			}
			item.Peer = &peer
			item.PeerLastReadSequence = peerLastReadSequence
		}
		last, err := service.loadLastVisibleMessage(ctx, principal.UserID, conversationID)
		if err != nil && !errors.Is(err, ErrNotFound) {
			return nil, err
		}
		if err == nil {
			item.LastMessage = &last
		}
		result = append(result, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate conversations: %w", err)
	}
	return result, nil
}

func (service *Service) GetConversation(ctx context.Context, principal account.Principal, conversationID uuid.UUID) (Conversation, error) {
	var item Conversation
	err := service.pool.QueryRow(ctx, `
		SELECT c.id,c.type,c.last_sequence,m.last_read_sequence,m.muted_until,m.is_pinned,c.created_at,c.updated_at
		FROM conversation_members m
		JOIN conversations c ON c.id=m.conversation_id
		WHERE c.id=$1 AND m.user_id=$2 AND m.status='ACTIVE'
	`, conversationID, principal.UserID).Scan(&item.ID, &item.Type, &item.LastSequence, &item.LastReadSequence, &item.Preferences.MutedUntil, &item.Preferences.IsPinned, &item.CreatedAt, &item.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Conversation{}, ErrNotFound
	}
	if err != nil {
		return Conversation{}, fmt.Errorf("load conversation: %w", err)
	}
	item.UnreadCount = item.LastSequence - item.LastReadSequence
	if item.UnreadCount < 0 {
		item.UnreadCount = 0
	}
	if item.Type == "DIRECT" {
		peer, peerLastReadSequence, err := service.loadDirectPeerState(ctx, conversationID, principal.UserID)
		if err != nil {
			return Conversation{}, err
		}
		item.Peer = &peer
		item.PeerLastReadSequence = peerLastReadSequence
	}
	last, err := service.loadLastVisibleMessage(ctx, principal.UserID, conversationID)
	if err != nil && !errors.Is(err, ErrNotFound) {
		return Conversation{}, err
	}
	if err == nil {
		item.LastMessage = &last
	}
	return item, nil
}

func (service *Service) UpdatePreferences(ctx context.Context, principal account.Principal, conversationID uuid.UUID, input UpdatePreferencesInput) (Conversation, error) {
	if input.IsPinned == nil && input.MutedUntil == nil && !input.ClearMute {
		return Conversation{}, ErrInvalidInput
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return Conversation{}, fmt.Errorf("begin conversation preferences: %w", err)
	}
	defer tx.Rollback(ctx)

	var currentPinned bool
	var currentMute *time.Time
	if err := tx.QueryRow(ctx, `
		SELECT is_pinned,muted_until FROM conversation_members
		WHERE conversation_id=$1 AND user_id=$2 AND status='ACTIVE'
		FOR UPDATE
	`, conversationID, principal.UserID).Scan(&currentPinned, &currentMute); errors.Is(err, pgx.ErrNoRows) {
		return Conversation{}, ErrNotFound
	} else if err != nil {
		return Conversation{}, fmt.Errorf("load conversation preferences: %w", err)
	}
	if input.IsPinned != nil {
		currentPinned = *input.IsPinned
	}
	if input.ClearMute {
		currentMute = nil
	} else if input.MutedUntil != nil {
		value := input.MutedUntil.UTC()
		currentMute = &value
	}
	if _, err := tx.Exec(ctx, `
		UPDATE conversation_members SET is_pinned=$3,muted_until=$4
		WHERE conversation_id=$1 AND user_id=$2 AND status='ACTIVE'
	`, conversationID, principal.UserID, currentPinned, currentMute); err != nil {
		return Conversation{}, fmt.Errorf("update conversation preferences: %w", err)
	}
	payload, _ := json.Marshal(map[string]any{"isPinned": currentPinned, "mutedUntil": currentMute})
	if err := insertOutbox(ctx, tx, "CONVERSATION", conversationID, "CONVERSATION_PREFERENCES_UPDATED", &conversationID, nil, &principal.UserID, payload, now); err != nil {
		return Conversation{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Conversation{}, fmt.Errorf("commit conversation preferences: %w", err)
	}
	return service.GetConversation(ctx, principal, conversationID)
}

func (service *Service) MarkRead(ctx context.Context, principal account.Principal, conversationID uuid.UUID, sequence int64) (MarkReadResult, []uuid.UUID, error) {
	if sequence < 0 {
		return MarkReadResult{}, nil, ErrInvalidInput
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return MarkReadResult{}, nil, fmt.Errorf("begin mark read: %w", err)
	}
	defer tx.Rollback(ctx)
	var lastSequence int64
	if err := tx.QueryRow(ctx, `
		SELECT c.last_sequence FROM conversations c
		JOIN conversation_members m ON m.conversation_id=c.id
		WHERE c.id=$1 AND m.user_id=$2 AND m.status='ACTIVE'
		FOR UPDATE OF m
	`, conversationID, principal.UserID).Scan(&lastSequence); errors.Is(err, pgx.ErrNoRows) {
		return MarkReadResult{}, nil, ErrNotFound
	} else if err != nil {
		return MarkReadResult{}, nil, fmt.Errorf("authorize mark read: %w", err)
	}
	if sequence > lastSequence {
		return MarkReadResult{}, nil, ErrConflict
	}
	var actual int64
	if err := tx.QueryRow(ctx, `
		UPDATE conversation_members
		SET last_read_sequence=GREATEST(last_read_sequence,$3)
		WHERE conversation_id=$1 AND user_id=$2
		RETURNING last_read_sequence
	`, conversationID, principal.UserID, sequence).Scan(&actual); err != nil {
		return MarkReadResult{}, nil, fmt.Errorf("update read sequence: %w", err)
	}
	payload, _ := json.Marshal(map[string]any{"userId": principal.UserID.String(), "lastReadSequence": actual})
	if err := insertOutbox(ctx, tx, "CONVERSATION", conversationID, "CONVERSATION_READ_UPDATED", &conversationID, nil, nil, payload, now); err != nil {
		return MarkReadResult{}, nil, err
	}
	userIDs, err := activeMemberIDsTx(ctx, tx, conversationID)
	if err != nil {
		return MarkReadResult{}, nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return MarkReadResult{}, nil, fmt.Errorf("commit mark read: %w", err)
	}
	return MarkReadResult{ConversationID: conversationID.String(), LastReadSequence: actual}, userIDs, nil
}

func (service *Service) loadDirectPeerState(ctx context.Context, conversationID, currentUserID uuid.UUID) (UserPreview, *int64, error) {
	var peer UserPreview
	var peerLastReadSequence *int64
	err := service.pool.QueryRow(ctx, `
		SELECT
			u.id,
			u.handle_normalized,
			u.display_name,
			CASE
				WHEN COALESCE(p.read_receipts_enabled, true) THEN m.last_read_sequence
				ELSE NULL
			END
		FROM conversation_members m
		JOIN users u ON u.id=m.user_id
		LEFT JOIN user_privacy_settings p ON p.user_id=m.user_id
		WHERE m.conversation_id=$1 AND m.user_id<>$2 AND m.status='ACTIVE'
		ORDER BY m.joined_at ASC LIMIT 1
	`, conversationID, currentUserID).Scan(&peer.ID, &peer.Handle, &peer.DisplayName, &peerLastReadSequence)
	if errors.Is(err, pgx.ErrNoRows) {
		return UserPreview{}, nil, ErrNotFound
	}
	if err != nil {
		return UserPreview{}, nil, fmt.Errorf("load direct peer state: %w", err)
	}
	return peer, peerLastReadSequence, nil
}

func authorizeConversationTx(ctx context.Context, tx pgx.Tx, principal account.Principal, conversationID uuid.UUID, write bool) (string, int64, error) {
	var conversationType, status string
	var lastSequence int64
	err := tx.QueryRow(ctx, `
		SELECT c.type,c.last_sequence,m.status
		FROM conversations c JOIN conversation_members m ON m.conversation_id=c.id
		WHERE c.id=$1 AND m.user_id=$2
		FOR UPDATE OF c
	`, conversationID, principal.UserID).Scan(&conversationType, &lastSequence, &status)
	if errors.Is(err, pgx.ErrNoRows) || status != "ACTIVE" {
		return "", 0, ErrNotFound
	}
	if err != nil {
		return "", 0, fmt.Errorf("authorize conversation: %w", err)
	}
	if !write || conversationType != "DIRECT" {
		return conversationType, lastSequence, nil
	}
	var peerID uuid.UUID
	if err := tx.QueryRow(ctx, `SELECT user_id FROM conversation_members WHERE conversation_id=$1 AND user_id<>$2 ORDER BY joined_at LIMIT 1`, conversationID, principal.UserID).Scan(&peerID); errors.Is(err, pgx.ErrNoRows) {
		return "", 0, ErrNotFound
	} else if err != nil {
		return "", 0, fmt.Errorf("load direct peer for authorization: %w", err)
	}
	if blocked, err := isBlockedBetweenTx(ctx, tx, principal.UserID, peerID); err != nil {
		return "", 0, err
	} else if blocked {
		return "", 0, ErrBlocked
	}
	if allowed, err := canStartOrWriteDirectTx(ctx, tx, principal.UserID, peerID); err != nil {
		return "", 0, err
	} else if !allowed {
		return "", 0, ErrForbidden
	}
	return conversationType, lastSequence, nil
}

func canStartOrWriteDirectTx(ctx context.Context, tx pgx.Tx, senderID, receiverID uuid.UUID) (bool, error) {
	var isContact, allowStranger bool
	err := tx.QueryRow(ctx, `
		SELECT
			EXISTS(SELECT 1 FROM contacts WHERE owner_user_id=$1 AND contact_user_id=$2),
			COALESCE((SELECT allow_stranger_messages FROM user_privacy_settings WHERE user_id=$2),false)
	`, senderID, receiverID).Scan(&isContact, &allowStranger)
	if err != nil {
		return false, fmt.Errorf("check direct write policy: %w", err)
	}
	return isContact || allowStranger, nil
}

func isBlockedBetweenTx(ctx context.Context, tx pgx.Tx, a, b uuid.UUID) (bool, error) {
	var blocked bool
	if err := tx.QueryRow(ctx, `
		SELECT EXISTS(
			SELECT 1 FROM blocks
			WHERE (owner_user_id=$1 AND blocked_user_id=$2)
			   OR (owner_user_id=$2 AND blocked_user_id=$1)
		)
	`, a, b).Scan(&blocked); err != nil {
		return false, fmt.Errorf("check block state: %w", err)
	}
	return blocked, nil
}

func activeMemberIDsTx(ctx context.Context, tx pgx.Tx, conversationID uuid.UUID) ([]uuid.UUID, error) {
	rows, err := tx.Query(ctx, `SELECT user_id FROM conversation_members WHERE conversation_id=$1 AND status='ACTIVE' ORDER BY user_id`, conversationID)
	if err != nil {
		return nil, fmt.Errorf("load active conversation members: %w", err)
	}
	defer rows.Close()
	var result []uuid.UUID
	for rows.Next() {
		var id uuid.UUID
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scan active member: %w", err)
		}
		result = append(result, id)
	}
	return result, rows.Err()
}

func insertOutbox(ctx context.Context, tx pgx.Tx, aggregateType string, aggregateID uuid.UUID, eventType string, conversationID *uuid.UUID, sequence *int64, targetUserID *uuid.UUID, payload []byte, now time.Time) error {
	if len(payload) == 0 {
		payload = []byte(`{}`)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO outbox_events(aggregate_type,aggregate_id,event_type,conversation_id,sequence,target_user_id,payload_json,created_at,available_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7::jsonb,$8,$8)
	`, aggregateType, aggregateID, eventType, conversationID, sequence, targetUserID, string(payload), now); err != nil {
		return fmt.Errorf("write outbox event: %w", err)
	}
	return nil
}

func directPairKey(a, b uuid.UUID) string {
	values := []string{a.String(), b.String()}
	sort.Strings(values)
	return strings.Join(values, ":")
}

func isSerializationFailure(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "40001"
}
