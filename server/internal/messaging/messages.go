package messaging

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
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
	case "STICKER", "STICKER_PACK":
		return "STICKER", true
	case "FILE":
		return "CHAT_FILE", true
	case "VOICE":
		return "CHAT_VOICE", true
	case "VIDEO":
		return "CHAT_VIDEO", true
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

	conversationType, _, err := authorizeConversationTx(ctx, tx, principal, conversationID, true)
	if err != nil {
		return SendResult{}, err
	}

	if input.Type == "TEXT" {
		if len(input.trustedEntities) > 0 {
			input.Content.Entities = cloneMessageEntities(input.trustedEntities)
		} else {
			entities, err := resolveMentionEntitiesTx(
				ctx,
				tx,
				input.Content.Text,
				conversationType,
				conversationID,
				principal.UserID,
			)
			if err != nil {
				return SendResult{}, err
			}
			input.Content.Entities = entities
		}
	}

	var primaryMediaID *uuid.UUID
	var thumbnailMediaID *uuid.UUID
	if mediaPurpose, ok := mediaPurposeForMessageType(input.Type); ok {
		parsedMediaID := uuid.MustParse(input.Content.MediaID)
		var originalName string
		var mimeType string
		var sizeBytes int64
		var mediaErr error
		if input.forwardSourceID != nil {
			mediaErr = tx.QueryRow(ctx, `
				SELECT mo.original_name,mo.mime_type,mo.size_bytes
				FROM media_objects mo
				JOIN message_media mm ON mm.media_id=mo.id AND mm.role='PRIMARY'
				JOIN messages source ON source.id=mm.message_id
				JOIN conversation_members cm ON cm.conversation_id=source.conversation_id
				WHERE mo.id=$1 AND mo.status='READY' AND mo.purpose=$3 AND mo.deleted_at IS NULL
				  AND source.id=$4 AND source.recalled_at IS NULL AND source.deleted_at IS NULL
				  AND cm.user_id=$2 AND cm.status='ACTIVE'
				  AND NOT EXISTS(
					SELECT 1 FROM message_local_deletions d
					WHERE d.user_id=$2 AND d.message_id=source.id
				  )
			`, parsedMediaID, principal.UserID, mediaPurpose, *input.forwardSourceID).Scan(&originalName, &mimeType, &sizeBytes)
		} else {
			mediaErr = tx.QueryRow(ctx, `
				SELECT mo.original_name,mo.mime_type,mo.size_bytes
				FROM media_objects mo
				WHERE mo.id=$1 AND mo.status='READY' AND mo.purpose=$3 AND mo.deleted_at IS NULL
				  AND (
					mo.owner_user_id=$2
					OR ($3='STICKER' AND EXISTS(
						SELECT 1 FROM custom_stickers cs
						WHERE cs.owner_user_id=$2 AND cs.media_id=mo.id AND cs.deleted_at IS NULL
					))
					OR ($3='STICKER' AND EXISTS(
						SELECT 1
						FROM telegram_sticker_items tsi
						JOIN user_sticker_packs usp ON usp.pack_id=tsi.pack_id AND usp.user_id=$2
						WHERE tsi.media_id=mo.id
					))
				  )
			`, parsedMediaID, principal.UserID, mediaPurpose).Scan(&originalName, &mimeType, &sizeBytes)
		}
		if errors.Is(mediaErr, pgx.ErrNoRows) {
			return SendResult{}, ErrForbidden
		}
		if mediaErr != nil {
			return SendResult{}, fmt.Errorf("authorize %s media: %w", input.Type, mediaErr)
		}
		input.Content.FileName = originalName
		input.Content.MIMEType = mimeType
		input.Content.SizeBytes = sizeBytes
		primaryMediaID = &parsedMediaID

		if input.Type == "STICKER_PACK" {
			if input.forwardSourceID != nil {
				if input.trustedStickerPackShareURI == "" {
					return SendResult{}, ErrConflict
				}
				input.Content.Text = input.trustedStickerPackShareURI
			} else {
				var setName string
				var title string
				packErr := tx.QueryRow(ctx, `
					SELECT p.set_name,p.title
					FROM telegram_sticker_items item
					JOIN telegram_sticker_packs p ON p.id=item.pack_id
					WHERE item.media_id=$1
					  AND item.id=(
						SELECT first_item.id
						FROM telegram_sticker_items first_item
						WHERE first_item.pack_id=item.pack_id
						ORDER BY first_item.sort_order,first_item.id
						LIMIT 1
					  )
				`, parsedMediaID).Scan(&setName, &title)
				if errors.Is(packErr, pgx.ErrNoRows) {
					return SendResult{}, ErrForbidden
				}
				if packErr != nil {
					return SendResult{}, fmt.Errorf("load sticker pack share metadata: %w", packErr)
				}
				if title == "" {
					title = setName
				}
				shareURL := url.URL{Scheme: "dd", Host: "stickers", Path: "/telegram/" + setName}
				query := shareURL.Query()
				query.Set("title", title)
				shareURL.RawQuery = query.Encode()
				input.Content.Text = shareURL.String()
			}
		}

		if input.Type == "VIDEO" {
			parsedPosterID := uuid.MustParse(input.Content.PosterMediaID)
			var posterErr error
			if input.forwardSourceID != nil {
				posterErr = tx.QueryRow(ctx, `
					SELECT mo.id
					FROM media_objects mo
					JOIN message_media mm ON mm.media_id=mo.id AND mm.role='THUMBNAIL'
					JOIN messages source ON source.id=mm.message_id
					JOIN conversation_members cm ON cm.conversation_id=source.conversation_id
					WHERE mo.id=$1 AND mo.status='READY' AND mo.purpose='CHAT_IMAGE' AND mo.deleted_at IS NULL
					  AND source.id=$3 AND source.recalled_at IS NULL AND source.deleted_at IS NULL
					  AND cm.user_id=$2 AND cm.status='ACTIVE'
					  AND NOT EXISTS(
						SELECT 1 FROM message_local_deletions d
						WHERE d.user_id=$2 AND d.message_id=source.id
					  )
				`, parsedPosterID, principal.UserID, *input.forwardSourceID).Scan(&parsedPosterID)
			} else {
				posterErr = tx.QueryRow(ctx, `
					SELECT id FROM media_objects
					WHERE id=$1 AND owner_user_id=$2 AND status='READY'
					  AND purpose='CHAT_IMAGE' AND deleted_at IS NULL
				`, parsedPosterID, principal.UserID).Scan(&parsedPosterID)
			}
			if errors.Is(posterErr, pgx.ErrNoRows) {
				return SendResult{}, ErrForbidden
			}
			if posterErr != nil {
				return SendResult{}, fmt.Errorf("authorize VIDEO thumbnail: %w", posterErr)
			}
			thumbnailMediaID = &parsedPosterID
		}
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
		INSERT INTO messages(conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,reply_to_message_id,forwarded_from_message_id,created_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7::jsonb,$8,$9,$10)
		RETURNING id
	`, conversationID, sequence, principal.UserID, principal.DeviceID, input.ClientMessageID, input.Type, string(contentBytes), replyID, input.forwardSourceID, now).Scan(&messageID); err != nil {
		return SendResult{}, fmt.Errorf("insert message: %w", err)
	}
	if input.Type == "TEXT" {
		if err := syncMessageMentionIndexTx(ctx, tx, messageID, conversationID, sequence, principal.UserID, conversationType, input.Content.Entities); err != nil {
			return SendResult{}, err
		}
	}
	if primaryMediaID != nil {
		if _, err := tx.Exec(ctx, `
			INSERT INTO message_media(message_id,media_id,role,created_at)
			VALUES($1,$2,'PRIMARY',$3)
		`, messageID, *primaryMediaID, now); err != nil {
			return SendResult{}, fmt.Errorf("attach message media: %w", err)
		}
	}
	if thumbnailMediaID != nil {
		if _, err := tx.Exec(ctx, `
			INSERT INTO message_media(message_id,media_id,role,created_at)
			VALUES($1,$2,'THUMBNAIL',$3)
		`, messageID, *thumbnailMediaID, now); err != nil {
			return SendResult{}, fmt.Errorf("attach message thumbnail: %w", err)
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE conversations SET last_message_id=$2 WHERE id=$1`, conversationID, messageID); err != nil {
		return SendResult{}, fmt.Errorf("update conversation last message: %w", err)
	}
	if conversationType == "SELF" {
		if _, err := tx.Exec(ctx, `
			UPDATE conversation_members
			SET last_read_sequence=$3,hidden_through_sequence=NULL,is_pinned=true,archived_at=NULL
			WHERE conversation_id=$1 AND user_id=$2 AND status='ACTIVE'
		`, conversationID, principal.UserID, sequence); err != nil {
			return SendResult{}, fmt.Errorf("mark self message read: %w", err)
		}
	}
	// Telegram-like archive rule: an incoming message wakes an archived chat
	// only when that recipient has not muted the conversation. The sender's
	// archive choice is left untouched.
	if _, err := tx.Exec(ctx, `
		UPDATE conversation_members
		SET archived_at=NULL
		WHERE conversation_id=$1 AND user_id<>$2 AND archived_at IS NOT NULL
		  AND (muted_until IS NULL OR muted_until<=$3)
	`, conversationID, principal.UserID, now); err != nil {
		return SendResult{}, fmt.Errorf("wake archived conversation: %w", err)
	}
	payload, _ := json.Marshal(map[string]any{
		"messageId":      messageID.String(),
		"conversationId": conversationID.String(),
		"sequence":       sequence,
		"forwardedFromMessageId": func() any {
			if input.forwardSourceID == nil {
				return nil
			}
			return input.forwardSourceID.String()
		}(),
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
		SELECT m.id,m.conversation_id,m.sequence,m.sender_user_id,m.sender_device_id,m.client_message_id,m.type,m.content_json,m.reply_to_message_id,m.forwarded_from_message_id,m.created_at,m.edited_at,m.edit_version,m.recalled_at
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

func (service *Service) EditMessage(ctx context.Context, principal account.Principal, messageID uuid.UUID, input EditMessageInput) (SendResult, error) {
	input, err := normalizeEditMessageInput(input)
	if err != nil {
		return SendResult{}, err
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return SendResult{}, fmt.Errorf("begin edit message: %w", err)
	}
	defer tx.Rollback(ctx)

	message, err := loadMessageByIDForUpdateTx(ctx, tx, messageID)
	if err != nil {
		return SendResult{}, err
	}
	if message.SenderUserID != principal.UserID.String() || message.RecalledAt != nil {
		return SendResult{}, ErrEditForbidden
	}
	if message.Type != "TEXT" {
		return SendResult{}, ErrEditUnsupported
	}
	conversationID := uuid.MustParse(message.ConversationID)
	conversationType, _, err := authorizeConversationTx(ctx, tx, principal, conversationID, false)
	if err != nil {
		return SendResult{}, err
	}
	if message.Content != nil && message.Content.Text == input.Text {
		memberIDs, err := activeMemberIDsTx(ctx, tx, conversationID)
		if err != nil {
			return SendResult{}, err
		}
		if err := tx.Commit(ctx); err != nil {
			return SendResult{}, fmt.Errorf("commit idempotent edit: %w", err)
		}
		return SendResult{Message: message, NotifyUserIDs: memberIDs}, nil
	}
	if message.EditVersion != input.ExpectedEditVersion {
		return SendResult{}, ErrEditConflict
	}
	entities, err := resolveMentionEntitiesTx(
		ctx,
		tx,
		input.Text,
		conversationType,
		conversationID,
		principal.UserID,
	)
	if err != nil {
		return SendResult{}, err
	}
	contentValue := TextContent{Text: input.Text, Entities: entities}
	content, err := json.Marshal(contentValue)
	if err != nil {
		return SendResult{}, fmt.Errorf("marshal edited message: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE messages
		SET content_json=$2::jsonb, edited_at=$3, edit_version=edit_version+1
		WHERE id=$1
	`, messageID, content, now); err != nil {
		return SendResult{}, fmt.Errorf("edit message: %w", err)
	}
	if err := syncMessageMentionIndexTx(ctx, tx, messageID, conversationID, message.Sequence, principal.UserID, conversationType, entities); err != nil {
		return SendResult{}, err
	}
	message.Content = &contentValue
	message.EditedAt = &now
	message.EditVersion++
	sequence := message.Sequence
	payload, _ := json.Marshal(map[string]any{
		"messageId":      message.ID,
		"conversationId": message.ConversationID,
		"sequence":       message.Sequence,
		"editVersion":    message.EditVersion,
	})
	if err := insertOutbox(ctx, tx, "MESSAGE", messageID, "MESSAGE_EDITED", &conversationID, &sequence, nil, payload, now); err != nil {
		return SendResult{}, err
	}
	memberIDs, err := activeMemberIDsTx(ctx, tx, conversationID)
	if err != nil {
		return SendResult{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return SendResult{}, fmt.Errorf("commit edit message: %w", err)
	}
	return SendResult{Message: message, NotifyUserIDs: memberIDs}, nil
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
	if _, err := tx.Exec(ctx, `DELETE FROM message_mentions WHERE message_id=$1`, messageID); err != nil {
		return SendResult{}, fmt.Errorf("delete recalled message mentions: %w", err)
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
	if _, err := tx.Exec(ctx, `
		DELETE FROM saved_messages WHERE user_id=$1 AND migrated_message_id=$2
	`, principal.UserID, messageID); err != nil {
		return fmt.Errorf("delete migrated saved bookmark: %w", err)
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
		SELECT id,conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,reply_to_message_id,forwarded_from_message_id,created_at,edited_at,edit_version,recalled_at
		FROM messages WHERE sender_device_id=$1 AND client_message_id=$2 AND deleted_at IS NULL
	`, deviceID, clientMessageID)
	return scanMessageRow(row)
}

func loadMessageByClientIDTx(ctx context.Context, tx pgx.Tx, deviceID uuid.UUID, clientMessageID string) (Message, error) {
	row := tx.QueryRow(ctx, `
		SELECT id,conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,reply_to_message_id,forwarded_from_message_id,created_at,edited_at,edit_version,recalled_at
		FROM messages WHERE sender_device_id=$1 AND client_message_id=$2 AND deleted_at IS NULL
	`, deviceID, clientMessageID)
	return scanMessageRow(row)
}

func (service *Service) loadMessageByID(ctx context.Context, messageID uuid.UUID) (Message, error) {
	row := service.pool.QueryRow(ctx, `
		SELECT id,conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,reply_to_message_id,forwarded_from_message_id,created_at,edited_at,edit_version,recalled_at
		FROM messages WHERE id=$1 AND deleted_at IS NULL
	`, messageID)
	return scanMessageRow(row)
}

func loadMessageByIDTx(ctx context.Context, tx pgx.Tx, messageID uuid.UUID) (Message, error) {
	row := tx.QueryRow(ctx, `
		SELECT id,conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,reply_to_message_id,forwarded_from_message_id,created_at,edited_at,edit_version,recalled_at
		FROM messages WHERE id=$1 AND deleted_at IS NULL
	`, messageID)
	return scanMessageRow(row)
}

func loadMessageByIDForUpdateTx(ctx context.Context, tx pgx.Tx, messageID uuid.UUID) (Message, error) {
	row := tx.QueryRow(ctx, `
		SELECT id,conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,reply_to_message_id,forwarded_from_message_id,created_at,edited_at,edit_version,recalled_at
		FROM messages WHERE id=$1 AND deleted_at IS NULL FOR UPDATE
	`, messageID)
	return scanMessageRow(row)
}

func (service *Service) loadLastVisibleMessage(ctx context.Context, userID, conversationID uuid.UUID) (Message, error) {
	row := service.pool.QueryRow(ctx, `
		SELECT m.id,m.conversation_id,m.sequence,m.sender_user_id,m.sender_device_id,m.client_message_id,m.type,m.content_json,m.reply_to_message_id,m.forwarded_from_message_id,m.created_at,m.edited_at,m.edit_version,m.recalled_at
		FROM messages m
		LEFT JOIN message_local_deletions d ON d.message_id=m.id AND d.user_id=$1
		WHERE m.conversation_id=$2 AND m.deleted_at IS NULL AND m.recalled_at IS NULL AND d.message_id IS NULL
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
	var forwardID *uuid.UUID
	var rawContent []byte
	if err := row.Scan(&id, &conversationID, &result.Sequence, &senderUserID, &senderDeviceID, &result.ClientMessageID, &result.Type, &rawContent, &replyID, &forwardID, &result.CreatedAt, &result.EditedAt, &result.EditVersion, &result.RecalledAt); errors.Is(err, pgx.ErrNoRows) {
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
	if forwardID != nil {
		value := forwardID.String()
		result.ForwardedFromMessageID = &value
	}
	if result.Type != "ENCRYPTED" {
		var content TextContent
		if len(rawContent) > 0 {
			if err := json.Unmarshal(rawContent, &content); err != nil {
				return Message{}, fmt.Errorf("decode message content: %w", err)
			}
		}
		if result.RecalledAt != nil {
			content = TextContent{}
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
