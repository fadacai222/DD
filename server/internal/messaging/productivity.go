package messaging

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const (
	DefaultProductivityLimit = 50
	MaximumProductivityLimit = 100
	MaximumSearchQueryRunes  = 160
)

func normalizeProductivityLimit(limit int) (int, error) {
	if limit == 0 {
		return DefaultProductivityLimit, nil
	}
	if limit < 1 || limit > MaximumProductivityLimit {
		return 0, ErrInvalidInput
	}
	return limit, nil
}

func (service *Service) SaveMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID) (SavedMessage, error) {
	message, err := service.GetMessage(ctx, principal, messageID)
	if err != nil {
		return SavedMessage{}, err
	}
	if message.RecalledAt != nil {
		return SavedMessage{}, ErrConflict
	}
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return SavedMessage{}, fmt.Errorf("begin save message: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		INSERT INTO saved_messages(user_id,message_id,saved_at)
		VALUES($1,$2,$3)
		ON CONFLICT(user_id,message_id) DO UPDATE SET saved_at=saved_messages.saved_at
	`, principal.UserID, messageID, now); err != nil {
		return SavedMessage{}, fmt.Errorf("save message: %w", err)
	}
	conversationID := uuid.MustParse(message.ConversationID)
	payload, _ := json.Marshal(map[string]any{"messageId": message.ID, "conversationId": message.ConversationID})
	if err := insertOutbox(ctx, tx, "MESSAGE", messageID, "MESSAGE_SAVED", &conversationID, nil, &principal.UserID, payload, now); err != nil {
		return SavedMessage{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return SavedMessage{}, fmt.Errorf("commit save message: %w", err)
	}
	return SavedMessage{Message: message, SavedAt: now}, nil
}

func (service *Service) UnsaveMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID) error {
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin unsave message: %w", err)
	}
	defer tx.Rollback(ctx)
	var migratedMessageID *uuid.UUID
	if err := tx.QueryRow(ctx, `
		SELECT migrated_message_id FROM saved_messages WHERE user_id=$1 AND message_id=$2 FOR UPDATE
	`, principal.UserID, messageID).Scan(&migratedMessageID); errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	} else if err != nil {
		return fmt.Errorf("load saved message for removal: %w", err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM saved_messages WHERE user_id=$1 AND message_id=$2`, principal.UserID, messageID); err != nil {
		return fmt.Errorf("unsave message: %w", err)
	}
	if migratedMessageID != nil {
		if _, err := tx.Exec(ctx, `
			INSERT INTO message_local_deletions(user_id,message_id,deleted_at)
			VALUES($1,$2,$3) ON CONFLICT(user_id,message_id) DO NOTHING
		`, principal.UserID, *migratedMessageID, now); err != nil {
			return fmt.Errorf("hide migrated saved message: %w", err)
		}
	}
	payload, _ := json.Marshal(map[string]any{"messageId": messageID.String()})
	if err := insertOutbox(ctx, tx, "MESSAGE", messageID, "MESSAGE_UNSAVED", nil, nil, &principal.UserID, payload, now); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit unsave message: %w", err)
	}
	return nil
}

func (service *Service) ListSavedMessages(ctx context.Context, principal account.Principal, limit int) ([]SavedMessage, error) {
	limit, err := normalizeProductivityLimit(limit)
	if err != nil {
		return nil, err
	}
	rows, err := service.pool.Query(ctx, `
		SELECT s.message_id,s.saved_at
		FROM saved_messages s
		JOIN messages m ON m.id=s.message_id AND m.deleted_at IS NULL
		JOIN conversation_members cm ON cm.conversation_id=m.conversation_id
		LEFT JOIN message_local_deletions d ON d.message_id=m.id AND d.user_id=$1
		WHERE s.user_id=$1 AND cm.user_id=$1 AND cm.status='ACTIVE' AND d.message_id IS NULL
		ORDER BY s.saved_at DESC,s.message_id DESC
		LIMIT $2
	`, principal.UserID, limit)
	if err != nil {
		return nil, fmt.Errorf("list saved messages: %w", err)
	}
	defer rows.Close()
	result := make([]SavedMessage, 0, limit)
	for rows.Next() {
		var messageID uuid.UUID
		var item SavedMessage
		if err := rows.Scan(&messageID, &item.SavedAt); err != nil {
			return nil, fmt.Errorf("scan saved message: %w", err)
		}
		message, err := service.loadMessageByID(ctx, messageID)
		if errors.Is(err, ErrNotFound) {
			continue
		}
		if err != nil {
			return nil, err
		}
		item.Message = message
		result = append(result, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate saved messages: %w", err)
	}
	return result, nil
}

func (service *Service) PinMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID) (PinnedMessage, []uuid.UUID, error) {
	message, err := service.GetMessage(ctx, principal, messageID)
	if err != nil {
		return PinnedMessage{}, nil, err
	}
	if message.RecalledAt != nil {
		return PinnedMessage{}, nil, ErrConflict
	}
	conversationID := uuid.MustParse(message.ConversationID)
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return PinnedMessage{}, nil, fmt.Errorf("begin pin message: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		INSERT INTO conversation_pinned_messages(conversation_id,message_id,pinned_by_user_id,pinned_at)
		VALUES($1,$2,$3,$4)
		ON CONFLICT(conversation_id,message_id) DO UPDATE SET pinned_at=conversation_pinned_messages.pinned_at
	`, conversationID, messageID, principal.UserID, now); err != nil {
		return PinnedMessage{}, nil, fmt.Errorf("pin message: %w", err)
	}
	payload, _ := json.Marshal(map[string]any{"messageId": message.ID, "conversationId": message.ConversationID})
	if err := insertOutbox(ctx, tx, "MESSAGE", messageID, "MESSAGE_PINNED", &conversationID, nil, nil, payload, now); err != nil {
		return PinnedMessage{}, nil, err
	}
	memberIDs, err := activeMemberIDsTx(ctx, tx, conversationID)
	if err != nil {
		return PinnedMessage{}, nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return PinnedMessage{}, nil, fmt.Errorf("commit pin message: %w", err)
	}
	return PinnedMessage{Message: message, PinnedByUserID: principal.UserID.String(), PinnedAt: now}, memberIDs, nil
}

func (service *Service) UnpinMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID) ([]uuid.UUID, error) {
	message, err := service.GetMessage(ctx, principal, messageID)
	if err != nil {
		return nil, err
	}
	conversationID := uuid.MustParse(message.ConversationID)
	now := service.now().UTC()
	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("begin unpin message: %w", err)
	}
	defer tx.Rollback(ctx)
	command, err := tx.Exec(ctx, `
		DELETE FROM conversation_pinned_messages
		WHERE conversation_id=$1 AND message_id=$2
	`, conversationID, messageID)
	if err != nil {
		return nil, fmt.Errorf("unpin message: %w", err)
	}
	if command.RowsAffected() == 0 {
		return nil, ErrNotFound
	}
	payload, _ := json.Marshal(map[string]any{"messageId": message.ID, "conversationId": message.ConversationID})
	if err := insertOutbox(ctx, tx, "MESSAGE", messageID, "MESSAGE_UNPINNED", &conversationID, nil, nil, payload, now); err != nil {
		return nil, err
	}
	memberIDs, err := activeMemberIDsTx(ctx, tx, conversationID)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit unpin message: %w", err)
	}
	return memberIDs, nil
}

func (service *Service) ListPinnedMessages(ctx context.Context, principal account.Principal, conversationID uuid.UUID, limit int) ([]PinnedMessage, error) {
	limit, err := normalizeProductivityLimit(limit)
	if err != nil {
		return nil, err
	}
	var allowed bool
	if err := service.pool.QueryRow(ctx, `
		SELECT EXISTS(
			SELECT 1 FROM conversation_members
			WHERE conversation_id=$1 AND user_id=$2 AND status='ACTIVE'
		)
	`, conversationID, principal.UserID).Scan(&allowed); err != nil {
		return nil, fmt.Errorf("authorize pinned messages: %w", err)
	}
	if !allowed {
		return nil, ErrNotFound
	}
	rows, err := service.pool.Query(ctx, `
		SELECT p.message_id,p.pinned_by_user_id,p.pinned_at
		FROM conversation_pinned_messages p
		JOIN messages m ON m.id=p.message_id AND m.deleted_at IS NULL AND m.recalled_at IS NULL
		LEFT JOIN message_local_deletions d ON d.message_id=m.id AND d.user_id=$2
		WHERE p.conversation_id=$1 AND d.message_id IS NULL
		ORDER BY p.pinned_at DESC,p.message_id DESC
		LIMIT $3
	`, conversationID, principal.UserID, limit)
	if err != nil {
		return nil, fmt.Errorf("list pinned messages: %w", err)
	}
	defer rows.Close()
	result := make([]PinnedMessage, 0, limit)
	for rows.Next() {
		var messageID, pinnedBy uuid.UUID
		var item PinnedMessage
		if err := rows.Scan(&messageID, &pinnedBy, &item.PinnedAt); err != nil {
			return nil, fmt.Errorf("scan pinned message: %w", err)
		}
		message, err := service.loadMessageByID(ctx, messageID)
		if errors.Is(err, ErrNotFound) {
			continue
		}
		if err != nil {
			return nil, err
		}
		item.Message = message
		item.PinnedByUserID = pinnedBy.String()
		result = append(result, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate pinned messages: %w", err)
	}
	return result, nil
}

func (service *Service) SearchMessages(ctx context.Context, principal account.Principal, query string, conversationID *uuid.UUID, limit int) ([]MessageSearchHit, error) {
	query = strings.TrimSpace(query)
	if utf8.RuneCountInString(query) < 1 || utf8.RuneCountInString(query) > MaximumSearchQueryRunes || strings.ContainsRune(query, '\x00') {
		return nil, ErrInvalidInput
	}
	limit, err := normalizeProductivityLimit(limit)
	if err != nil {
		return nil, err
	}
	rows, err := service.pool.Query(ctx, `
		SELECT m.id
		FROM messages m
		JOIN conversation_members cm ON cm.conversation_id=m.conversation_id
		LEFT JOIN message_local_deletions d ON d.message_id=m.id AND d.user_id=$1
		WHERE cm.user_id=$1 AND cm.status='ACTIVE'
		  AND m.deleted_at IS NULL AND m.recalled_at IS NULL AND d.message_id IS NULL
		  AND m.type='TEXT' AND COALESCE(m.content_json->>'text','') ILIKE ('%' || $2 || '%')
		  AND ($3::uuid IS NULL OR m.conversation_id=$3)
		ORDER BY m.created_at DESC,m.id DESC
		LIMIT $4
	`, principal.UserID, query, conversationID, limit)
	if err != nil {
		return nil, fmt.Errorf("search messages: %w", err)
	}
	defer rows.Close()
	result := make([]MessageSearchHit, 0, limit)
	for rows.Next() {
		var messageID uuid.UUID
		if err := rows.Scan(&messageID); err != nil {
			return nil, fmt.Errorf("scan search result: %w", err)
		}
		message, err := service.loadMessageByID(ctx, messageID)
		if errors.Is(err, ErrNotFound) {
			continue
		}
		if err != nil {
			return nil, err
		}
		result = append(result, MessageSearchHit{Message: message})
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate search results: %w", err)
	}
	return result, nil
}

func (service *Service) ForwardMessage(ctx context.Context, principal account.Principal, sourceMessageID uuid.UUID, input ForwardMessageInput) (SendResult, error) {
	targetConversationID, err := uuid.Parse(strings.TrimSpace(input.TargetConversationID))
	if err != nil {
		return SendResult{}, ErrInvalidInput
	}
	source, err := service.GetMessage(ctx, principal, sourceMessageID)
	if err != nil {
		return SendResult{}, err
	}
	if source.RecalledAt != nil || source.Content == nil {
		return SendResult{}, ErrConflict
	}
	content, err := forwardableContent(source)
	if err != nil {
		return SendResult{}, err
	}
	inputMessage := SendMessageInput{
		ClientMessageID: input.ClientMessageID,
		Type:            source.Type,
		Content:         content,
		forwardSourceID: &sourceMessageID,
	}
	if source.Type == "TEXT" && source.Content != nil {
		inputMessage.trustedEntities = cloneMessageEntities(source.Content.Entities)
	}
	if source.Type == "STICKER_PACK" && source.Content != nil {
		inputMessage.trustedStickerPackShareURI = source.Content.Text
	}
	return service.SendMessage(ctx, principal, targetConversationID, inputMessage)
}

func forwardableContent(source Message) (*TextContent, error) {
	if source.Content == nil {
		return nil, ErrConflict
	}
	content := source.Content
	switch source.Type {
	case "TEXT":
		return &TextContent{
			Text:     content.Text,
			Entities: cloneMessageEntities(content.Entities),
		}, nil
	case "IMAGE", "GIF", "STICKER", "STICKER_PACK":
		if content.MediaID == "" || content.Width <= 0 || content.Height <= 0 {
			return nil, ErrConflict
		}
		return &TextContent{MediaID: content.MediaID, Width: content.Width, Height: content.Height}, nil
	case "FILE":
		if content.MediaID == "" {
			return nil, ErrConflict
		}
		return &TextContent{MediaID: content.MediaID}, nil
	case "VOICE":
		if content.MediaID == "" || content.DurationMS <= 0 {
			return nil, ErrConflict
		}
		return &TextContent{MediaID: content.MediaID, DurationMS: content.DurationMS}, nil
	case "VIDEO":
		if content.MediaID == "" || content.PosterMediaID == "" ||
			content.Width <= 0 || content.Height <= 0 || content.DurationMS <= 0 {
			return nil, ErrConflict
		}
		return &TextContent{
			MediaID:       content.MediaID,
			PosterMediaID: content.PosterMediaID,
			Width:         content.Width,
			Height:        content.Height,
			DurationMS:    content.DurationMS,
		}, nil
	default:
		return nil, ErrUnsupportedType
	}
}
