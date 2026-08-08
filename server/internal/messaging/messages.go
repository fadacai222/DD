package messaging

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func mediaPurposeForMessageType(messageType string) (string, bool) {
	switch messageType {
	case "IMAGE":
		return "CHAT_IMAGE", true
	case "GIF":
		return "GIF", true
	case "STICKER":
		return "STICKER", true
	case "FILE":
		return "CHAT_FILE", true
	case "VOICE":
		return "CHAT_VOICE", true
	default:
		return "", false
	}
}

func (service *Service) SendMessage(ctx context.Context, principal account.Principal, conversationID uuid.UUID, input SendMessageInput) (SendResult, error) {
	normalized, err := normalizeSendInput(input)
	if err != nil {
		return SendResult{}, err
	}
	for attempt := 0; attempt < 3; attempt++ {
		result, err := service.sendMessageOnce(ctx, principal, conversationID, normalized)
		if err == nil {
			return result, nil
		}
		if errors.Is(err, ErrConflict) {
			return SendResult{}, err
		}
		if !isSerializationFailure(err) && !isUniqueViolation(err) {
			return SendResult{}, err
		}
		if existing, loadErr := service.loadMessageByClientID(ctx, principal.DeviceID, normalized.ClientMessageID); loadErr == nil {
			if existing.ConversationID != conversationID.String() || existing.SenderUserID != principal.UserID.String() {
				return SendResult{}, ErrConflict
			}
			memberIDs, membersErr := service.activeMemberIDs(ctx, conversationID)
			if membersErr != nil {
				return SendResult{}, membersErr
			}
			return SendResult{Message: existing, NotifyUserIDs: memberIDs}, nil
		}
	}
	return SendResult{}, fmt.Errorf("send message retries exhausted")
}

func (service *Service) sendMessageOnce(ctx context.Context, principal account.Principal, conversationID uuid.UUID, input SendMessageInput) (SendResult, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return SendResult{}, fmt.Errorf("begin send message: %w", err)
	}
	defer tx.Rollback(ctx)
	idempotencyKey := principal.DeviceID.String() + ":" + input.ClientMessageID
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, idempotencyKey); err != nil {
		return SendResult{}, fmt.Errorf("lock message idempotency key: %w", err)
	}

	if existing, err := loadMessageByClientIDTx(ctx, tx, principal.DeviceID, input.ClientMessageID); err == nil {
		if existing.ConversationID != conversationID.String() || existing.SenderUserID != principal.UserID.String() {
			return SendResult{}, ErrConflict
		}
		memberIDs, err := activeMemberIDsTx(ctx, tx, conversationID)
		if err != nil {
			return SendResult{}, err
		}
		if err := tx.Commit(ctx); err != nil {
			return SendResult{}, fmt.Errorf("commit idempotent send: %w", err)
		}
		return SendResult{Message: existing, NotifyUserIDs: memberIDs}, nil
	} else if !errors.Is(err, ErrNotFound) {
		return SendResult{}, err
	}

	_, _, err = authorizeConversationTx(ctx, tx, principal, conversationID, true)
	if err != nil {
		return SendResult{}, err
	}

	var primaryMediaID *uuid.UUID
	if mediaPurpose, ok := mediaPurposeForMessageType(input.Type); ok {
		parsedMediaID := uuid.MustParse(input.Content.MediaID)
		var originalName string
		var mimeType string
		var sizeBytes int64
		err := tx.QueryRow(ctx, `
			SELECT original_name,mime_type,size_bytes
			FROM media_objects
			WHERE id=$1 AND owner_user_id=$2 AND status='READY' AND purpose=$3 AND deleted_at IS NULL
		`, parsedMediaID, principal.UserID, mediaPurpose).Scan(&originalName, &mimeType, &sizeBytes)
		if errors.Is(err, pgx.ErrNoRows) {
			return SendResult{}, ErrForbidden
		}
		if err != nil {
			return SendResult{}, fmt.Errorf("authorize %s media: %w", input.Type, err)
		}
		input.Content.FileName = originalName
		input.Content.MIMEType = mimeType
		input.Content.SizeBytes = sizeBytes
		primaryMediaID = &parsedMediaID
	}

	var replyID *uuid.UUID
	if input.ReplyToMessageID != nil {
		parsed := uuid.MustParse(*input.ReplyToMessageID)
		var replyConversationID uuid.UUID
		if err := tx.QueryRow(ctx, `SELECT conversation_id FROM messages WHERE id=$1 AND deleted_at IS NULL`, parsed).Scan(&replyConversationID); errors.Is(err, pgx.ErrNoRows) {
			return SendResult{}, ErrNotFound
		} else if err != nil {
			return SendResult{}, fmt.Errorf("load reply target: %w", err)
		}
		if replyConversationID != conversationID {
			return SendResult{}, ErrConflict
		}
		replyID = &parsed
	}

	var sequence int64
	if err := tx.QueryRow(ctx, `
		UPDATE conversations SET last_sequence=last_sequence+1,updated_at=$2
		WHERE id=$1 RETURNING last_sequence
	`, conversationID, now).Scan(&sequence); err != nil {
		return SendResult{}, fmt.Errorf("allocate message sequence: %w", err)
	}
	contentBytes, _ := json.Marshal(input.Content)
	var messageID uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO messages(conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,reply_to_message_id,created_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7::jsonb,$8,$9)
		RETURNING id
	`, conversationID, sequence, principal.UserID, principal.DeviceID, input.ClientMessageID, input.Type, string(contentBytes), replyID, now).Scan(&messageID); err != nil {
		return SendResult{}, fmt.Errorf("insert message: %w", err)
	}
	if primaryMediaID != nil {
		if _, err := tx.Exec(ctx, `
			INSERT INTO message_media(message_id,media_id,role,created_at)
			VALUES($1,$2,'PRIMARY',$3)
		`, messageID, *primaryMediaID, now); err != nil {
			return SendResult{}, fmt.Errorf("attach message media: %w", err)
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE conversations SET last_message_id=$2 WHERE id=$1`, conversationID, messageID); err != nil {
		return SendResult{}, fmt.Errorf("update conversation last message: %w", err)
	}
	payload, _ := json.Marshal(map[string]any{
		"messageId":      messageID.String(),
		"conversationId": conversationID.String(),
		"sequence":       sequence,
	})
	if err := insertOutbox(ctx, tx, "MESSAGE", messageID, "MESSAGE_CREATED", &conversationID, &sequence, nil, payload, now); err != nil {
		return SendResult{}, err
	}
	message, err := loadMessageByIDTx(ctx, tx, messageID)
	if err != nil {
		return SendResult{}, err
	}
	memberIDs, err := activeMemberIDsTx(ctx, tx, conversationID)
	if err != nil {
		return SendResult{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return SendResult{}, fmt.Errorf("commit send message: %w", err)
	}
	return SendResult{Message: message, NotifyUserIDs: memberIDs}, nil
}

func (service *Service) ListMessages(ctx context.Context, principal account.Principal, conversationID uuid.UUID, beforeSequence int64, limit int) (MessagePage, error) {
	limit, err := normalizeHistoryLimit(limit)
	if err != nil {
		return MessagePage{}, err
	}
	if beforeSequence < 0 {
		return MessagePage{}, ErrInvalidInput
	}
	var exists bool
	if err := service.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM conversation_members WHERE conversation_id=$1 AND user_id=$2 AND status='ACTIVE')`, conversationID, principal.UserID).Scan(&exists); err != nil {
		return MessagePage{}, fmt.Errorf("authorize message history: %w", err)
	}
	if !exists {
		return MessagePage{}, ErrNotFound
	}
	if beforeSequence == 0 {
		if err := service.pool.QueryRow(ctx, `SELECT last_sequence+1 FROM conversations WHERE id=$1`, conversationID).Scan(&beforeSequence); errors.Is(err, pgx.ErrNoRows) {
			return MessagePage{}, ErrNotFound
		} else if err != nil {
			return MessagePage{}, fmt.Errorf("load history cursor: %w", err)
		}
	}
	rows, err := service.pool.Query(ctx, `
		SELECT m.id,m.conversation_id,m.sequence,m.sender_user_id,m.sender_device_id,m.client_message_id,m.type,m.content_json,m.reply_to_message_id,m.created_at,m.recalled_at
		FROM messages m
		LEFT JOIN message_local_deletions d ON d.message_id=m.id AND d.user_id=$2
		WHERE m.conversation_id=$1 AND m.sequence<$3 AND m.deleted_at IS NULL AND d.message_id IS NULL
		ORDER BY m.sequence DESC
		LIMIT $4
	`, conversationID, principal.UserID, beforeSequence, limit+1)
	if err != nil {
		return MessagePage{}, fmt.Errorf("list message history: %w", err)
	}
	defer rows.Close()

	items := make([]Message, 0, limit+1)
	for rows.Next() {
		message, err := scanMessage(rows)
		if err != nil {
			return MessagePage{}, err
		}
		items = append(items, message)
	}
	if err := rows.Err(); err != nil {
		return MessagePage{}, fmt.Errorf("iterate message history: %w", err)
	}
	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}
	var next *int64
	if len(items) > 0 && hasMore {
		value := items[len(items)-1].Sequence
		next = &value
	}
	return MessagePage{Items: items, NextBeforeSequence: next, HasMore: hasMore}, nil
}

func (service *Service) GetMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID) (Message, error) {
	message, err := service.loadMessageByID(ctx, messageID)
	if err != nil {
		return Message{}, err
	}
	conversationID := uuid.MustParse(message.ConversationID)
	var allowed bool
	if err := service.pool.QueryRow(ctx, `
		SELECT EXISTS(
			SELECT 1 FROM conversation_members m
			WHERE m.conversation_id=$1 AND m.user_id=$2 AND m.status='ACTIVE'
			AND NOT EXISTS(SELECT 1 FROM message_local_deletions d WHERE d.user_id=$2 AND d.message_id=$3)
		)
	`, conversationID, principal.UserID, messageID).Scan(&allowed); err != nil {
		return Message{}, fmt.Errorf("authorize message read: %w", err)
	}
	if !allowed {
		return Message{}, ErrNotFound
	}
	return message, nil
}

func (service *Service) RecallMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID) (SendResult, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return SendResult{}, fmt.Errorf("begin recall message: %w", err)
	}
	defer tx.Rollback(ctx)
	message, err := loadMessageByIDForUpdateTx(ctx, tx, messageID)
	if err != nil {
		return SendResult{}, err
	}
	if message.SenderUserID != principal.UserID.String() {
		return SendResult{}, ErrForbidden
	}
	conversationID := uuid.MustParse(message.ConversationID)
	if _, _, err := authorizeConversationTx(ctx, tx, principal, conversationID, false); err != nil {
		return SendResult{}, err
	}
	if message.RecalledAt != nil {
		memberIDs, err := activeMemberIDsTx(ctx, tx, conversationID)
		if err != nil {
			return SendResult{}, err
		}
		if err := tx.Commit(ctx); err != nil {
			return SendResult{}, fmt.Errorf("commit idempotent recall: %w", err)
		}
		return SendResult{Message: message, NotifyUserIDs: memberIDs}, nil
	}
	if _, err := tx.Exec(ctx, `UPDATE messages SET recalled_at=$2,content_json='{}'::jsonb WHERE id=$1`, messageID, now); err != nil {
		return SendResult{}, fmt.Errorf("recall message: %w", err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM message_media WHERE message_id=$1`, messageID); err != nil {
		return SendResult{}, fmt.Errorf("detach recalled message media: %w", err)
	}
	sequence := message.Sequence
	payload, _ := json.Marshal(map[string]any{"messageId": message.ID, "conversationId": message.ConversationID, "sequence": message.Sequence})
	if err := insertOutbox(ctx, tx, "MESSAGE", messageID, "MESSAGE_RECALLED", &conversationID, &sequence, nil, payload, now); err != nil {
		return SendResult{}, err
	}
	message.RecalledAt = &now
	message.Content = &TextContent{}
	memberIDs, err := activeMemberIDsTx(ctx, tx, conversationID)
	if err != nil {
		return SendResult{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return SendResult{}, fmt.Errorf("commit recall message: %w", err)
	}
	return SendResult{Message: message, NotifyUserIDs: memberIDs}, nil
}

func (service *Service) DeleteMessageLocally(ctx context.Context, principal account.Principal, messageID uuid.UUID) error {
	message, err := service.GetMessage(ctx, principal, messageID)
	if err != nil {
		return err
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("begin local delete: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		INSERT INTO message_local_deletions(user_id,message_id,deleted_at)
		VALUES ($1,$2,$3) ON CONFLICT (user_id,message_id) DO NOTHING
	`, principal.UserID, messageID, now); err != nil {
		return fmt.Errorf("delete message locally: %w", err)
	}
	conversationID := uuid.MustParse(message.ConversationID)
	payload, _ := json.Marshal(map[string]any{"messageId": message.ID, "conversationId": message.ConversationID})
	if err := insertOutbox(ctx, tx, "MESSAGE", messageID, "MESSAGE_LOCAL_DELETED", &conversationID, nil, &principal.UserID, payload, now); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (service *Service) loadMessageByClientID(ctx context.Context, deviceID uuid.UUID, clientMessageID string) (Message, error) {
	row := service.pool.QueryRow(ctx, `
		SELECT id,conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,reply_to_message_id,created_at,recalled_at
		FROM messages WHERE sender_device_id=$1 AND client_message_id=$2 AND deleted_at IS NULL
	`, deviceID, clientMessageID)
	return scanMessageRow(row)
}

func loadMessageByClientIDTx(ctx context.Context, tx pgx.Tx, deviceID uuid.UUID, clientMessageID string) (Message, error) {
	row := tx.QueryRow(ctx, `
		SELECT id,conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,reply_to_message_id,created_at,recalled_at
		FROM messages WHERE sender_device_id=$1 AND client_message_id=$2 AND deleted_at IS NULL
	`, deviceID, clientMessageID)
	return scanMessageRow(row)
}

func (service *Service) loadMessageByID(ctx context.Context, messageID uuid.UUID) (Message, error) {
	row := service.pool.QueryRow(ctx, `
		SELECT id,conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,reply_to_message_id,created_at,recalled_at
		FROM messages WHERE id=$1 AND deleted_at IS NULL
	`, messageID)
	return scanMessageRow(row)
}

func loadMessageByIDTx(ctx context.Context, tx pgx.Tx, messageID uuid.UUID) (Message, error) {
	row := tx.QueryRow(ctx, `
		SELECT id,conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,reply_to_message_id,created_at,recalled_at
		FROM messages WHERE id=$1 AND deleted_at IS NULL
	`, messageID)
	return scanMessageRow(row)
}

func loadMessageByIDForUpdateTx(ctx context.Context, tx pgx.Tx, messageID uuid.UUID) (Message, error) {
	row := tx.QueryRow(ctx, `
		SELECT id,conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,reply_to_message_id,created_at,recalled_at
		FROM messages WHERE id=$1 AND deleted_at IS NULL FOR UPDATE
	`, messageID)
	return scanMessageRow(row)
}

func (service *Service) loadLastVisibleMessage(ctx context.Context, userID, conversationID uuid.UUID) (Message, error) {
	row := service.pool.QueryRow(ctx, `
		SELECT m.id,m.conversation_id,m.sequence,m.sender_user_id,m.sender_device_id,m.client_message_id,m.type,m.content_json,m.reply_to_message_id,m.created_at,m.recalled_at
		FROM messages m
		LEFT JOIN message_local_deletions d ON d.message_id=m.id AND d.user_id=$1
		WHERE m.conversation_id=$2 AND m.deleted_at IS NULL AND d.message_id IS NULL
		ORDER BY m.sequence DESC LIMIT 1
	`, userID, conversationID)
	return scanMessageRow(row)
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanMessage(rows pgx.Rows) (Message, error) {
	return scanMessageRow(rows)
}

func scanMessageRow(row rowScanner) (Message, error) {
	var result Message
	var id, conversationID, senderUserID, senderDeviceID uuid.UUID
	var replyID *uuid.UUID
	var rawContent []byte
	if err := row.Scan(&id, &conversationID, &result.Sequence, &senderUserID, &senderDeviceID, &result.ClientMessageID, &result.Type, &rawContent, &replyID, &result.CreatedAt, &result.RecalledAt); errors.Is(err, pgx.ErrNoRows) {
		return Message{}, ErrNotFound
	} else if err != nil {
		return Message{}, fmt.Errorf("scan message: %w", err)
	}
	result.ID = id.String()
	result.ConversationID = conversationID.String()
	result.SenderUserID = senderUserID.String()
	result.SenderDeviceID = senderDeviceID.String()
	if replyID != nil {
		value := replyID.String()
		result.ReplyToMessageID = &value
	}
	if result.Type == "TEXT" {
		var content TextContent
		if len(rawContent) > 0 {
			if err := json.Unmarshal(rawContent, &content); err != nil {
				return Message{}, fmt.Errorf("decode message content: %w", err)
			}
		}
		if result.RecalledAt != nil {
			content.Text = ""
		}
		result.Content = &content
	}
	return result, nil
}

func (service *Service) activeMemberIDs(ctx context.Context, conversationID uuid.UUID) ([]uuid.UUID, error) {
	rows, err := service.pool.Query(ctx, `SELECT user_id FROM conversation_members WHERE conversation_id=$1 AND status='ACTIVE' ORDER BY user_id`, conversationID)
	if err != nil {
		return nil, fmt.Errorf("load active members: %w", err)
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

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

var _ = time.Second
