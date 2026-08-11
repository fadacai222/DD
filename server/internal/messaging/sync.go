package messaging

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func (service *Service) Sync(ctx context.Context, principal account.Principal, cursor int64, limit int) (SyncPage, error) {
	if cursor < 0 {
		return SyncPage{}, ErrInvalidInput
	}
	limit, err := normalizeSyncLimit(limit)
	if err != nil {
		return SyncPage{}, err
	}
	rows, err := service.pool.Query(ctx, `
		SELECT cursor,id,event_type,resource_id,conversation_id,sequence,payload_json,occurred_at
		FROM sync_events
		WHERE user_id=$1 AND cursor>$2
		ORDER BY cursor ASC
		LIMIT $3
	`, principal.UserID, cursor, limit+1)
	if err != nil {
		return SyncPage{}, fmt.Errorf("load sync events: %w", err)
	}
	defer rows.Close()

	items := make([]SyncEvent, 0, limit+1)
	for rows.Next() {
		var item SyncEvent
		var id uuid.UUID
		var resourceID, conversationID *uuid.UUID
		var payload []byte
		if err := rows.Scan(&item.Cursor, &id, &item.Type, &resourceID, &conversationID, &item.Sequence, &payload, &item.OccurredAt); err != nil {
			return SyncPage{}, fmt.Errorf("scan sync event: %w", err)
		}
		item.ID = id.String()
		if resourceID != nil {
			value := resourceID.String()
			item.ResourceID = &value
		}
		if conversationID != nil {
			value := conversationID.String()
			item.ConversationID = &value
		}
		item.Payload = append(json.RawMessage(nil), payload...)
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return SyncPage{}, fmt.Errorf("iterate sync events: %w", err)
	}
	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}
	next := cursor
	if len(items) > 0 {
		next = items[len(items)-1].Cursor
	}
	return SyncPage{Items: items, NextCursor: next, HasMore: hasMore}, nil
}

func (service *Service) DispatchOutbox(ctx context.Context, limit int) (int, error) {
	if limit == 0 {
		limit = 100
	}
	if limit < 1 || limit > 500 {
		return 0, ErrInvalidInput
	}
	processed := 0
	for processed < limit {
		didWork, err := service.dispatchOne(ctx)
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

func (service *Service) dispatchOne(ctx context.Context) (bool, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return false, fmt.Errorf("begin outbox dispatch: %w", err)
	}
	defer tx.Rollback(ctx)

	var event outboxEvent
	err = tx.QueryRow(ctx, `
		SELECT id,aggregate_type,aggregate_id,event_type,conversation_id,sequence,target_user_id,payload_json,created_at,attempts
		FROM outbox_events
		WHERE published_at IS NULL AND available_at<=$1
		ORDER BY available_at,created_at,id
		FOR UPDATE SKIP LOCKED
		LIMIT 1
	`, now).Scan(&event.ID, &event.AggregateType, &event.AggregateID, &event.EventType, &event.ConversationID, &event.Sequence, &event.TargetUserID, &event.Payload, &event.CreatedAt, &event.Attempts)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("claim outbox event: %w", err)
	}

	recipients, err := service.resolveOutboxRecipients(ctx, tx, event)
	if err != nil {
		_ = service.deferOutbox(ctx, tx, event, err, now)
		if commitErr := tx.Commit(ctx); commitErr != nil {
			return false, fmt.Errorf("commit deferred outbox: %w", commitErr)
		}
		return true, nil
	}
	if _, err := tx.Exec(ctx, `SAVEPOINT outbox_delivery`); err != nil {
		return false, fmt.Errorf("create outbox delivery savepoint: %w", err)
	}
	for _, userID := range recipients {
		if _, err := tx.Exec(ctx, `
			INSERT INTO sync_events(user_id,source_outbox_id,event_type,resource_id,conversation_id,sequence,payload_json,occurred_at,created_at)
			VALUES ($1,$2,$3,$4,$5,$6,$7::jsonb,$8,$9)
			ON CONFLICT (source_outbox_id,user_id) DO NOTHING
		`, userID, event.ID, event.EventType, nullableResourceID(event), event.ConversationID, event.Sequence, string(event.Payload), event.CreatedAt, now); err != nil {
			if _, rollbackErr := tx.Exec(ctx, `ROLLBACK TO SAVEPOINT outbox_delivery`); rollbackErr != nil {
				return false, fmt.Errorf("rollback failed outbox delivery: %w", rollbackErr)
			}
			if deferErr := service.deferOutbox(ctx, tx, event, err, now); deferErr != nil {
				return false, fmt.Errorf("defer failed outbox delivery: %w", deferErr)
			}
			if commitErr := tx.Commit(ctx); commitErr != nil {
				return false, fmt.Errorf("commit failed outbox attempt: %w", commitErr)
			}
			return true, nil
		}
		if err := enqueuePushJobForOutboxRecipient(ctx, tx, event, userID, now); err != nil {
			if _, rollbackErr := tx.Exec(ctx, `ROLLBACK TO SAVEPOINT outbox_delivery`); rollbackErr != nil {
				return false, fmt.Errorf("rollback failed push enqueue: %w", rollbackErr)
			}
			if deferErr := service.deferOutbox(ctx, tx, event, err, now); deferErr != nil {
				return false, fmt.Errorf("defer failed push enqueue: %w", deferErr)
			}
			if commitErr := tx.Commit(ctx); commitErr != nil {
				return false, fmt.Errorf("commit failed push enqueue attempt: %w", commitErr)
			}
			return true, nil
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE outbox_events SET published_at=$2,attempts=attempts+1,last_error=NULL WHERE id=$1`, event.ID, now); err != nil {
		return false, fmt.Errorf("mark outbox published: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("commit outbox dispatch: %w", err)
	}
	return true, nil
}

type outboxEvent struct {
	ID             uuid.UUID
	AggregateType  string
	AggregateID    uuid.UUID
	EventType      string
	ConversationID *uuid.UUID
	Sequence       *int64
	TargetUserID   *uuid.UUID
	Payload        []byte
	CreatedAt      time.Time
	Attempts       int
}

func (service *Service) resolveOutboxRecipients(ctx context.Context, tx pgx.Tx, event outboxEvent) ([]uuid.UUID, error) {
	if event.TargetUserID != nil {
		return []uuid.UUID{*event.TargetUserID}, nil
	}
	if event.ConversationID == nil {
		return nil, ErrOutboxUnavailable
	}
	return activeMemberIDsTx(ctx, tx, *event.ConversationID)
}

func (service *Service) deferOutbox(ctx context.Context, tx pgx.Tx, event outboxEvent, dispatchErr error, now time.Time) error {
	attempt := event.Attempts + 1
	backoff := time.Second * time.Duration(1<<min(attempt-1, 6))
	if backoff > time.Minute {
		backoff = time.Minute
	}
	message := dispatchErr.Error()
	if len(message) > 1000 {
		message = message[:1000]
	}
	_, err := tx.Exec(ctx, `
		UPDATE outbox_events
		SET attempts=$2,last_error=$3,available_at=$4
		WHERE id=$1
	`, event.ID, attempt, message, now.Add(backoff))
	return err
}

func nullableResourceID(event outboxEvent) *uuid.UUID {
	switch event.AggregateType {
	case "MESSAGE", "RELATIONSHIP", "GROUP", "MOMENT", "CALL":
		value := event.AggregateID
		return &value
	default:
		return nil
	}
}

func enqueuePushJobForOutboxRecipient(ctx context.Context, tx pgx.Tx, event outboxEvent, recipientUserID uuid.UUID, now time.Time) error {
	if recipientUserID == uuid.Nil {
		return nil
	}
	if event.EventType != "MESSAGE_CREATED" && event.EventType != "GROUP_CALL_STARTED" && event.EventType != "CALL_RINGING" {
		return nil
	}
	var actorUserID *uuid.UUID
	if event.EventType == "MESSAGE_CREATED" {
		var sender uuid.UUID
		if err := tx.QueryRow(ctx, `SELECT sender_user_id FROM messages WHERE id=$1`, event.AggregateID).Scan(&sender); errors.Is(err, pgx.ErrNoRows) {
			return nil
		} else if err != nil {
			return fmt.Errorf("load push message sender: %w", err)
		}
		if sender == recipientUserID {
			return nil
		}
		actorUserID = &sender
	} else {
		var payload struct {
			StartedByUserID string `json:"startedByUserId"`
			CallerUserID    string `json:"callerUserId"`
		}
		if json.Unmarshal(event.Payload, &payload) == nil {
			actorRaw := strings.TrimSpace(payload.StartedByUserID)
			if actorRaw == "" {
				actorRaw = strings.TrimSpace(payload.CallerUserID)
			}
			if parsed, err := uuid.Parse(actorRaw); err == nil && parsed != uuid.Nil {
				if parsed == recipientUserID {
					return nil
				}
				actorUserID = &parsed
			}
		}
	}
	resourceID := nullableResourceID(event)
	dedupe := "outbox:" + event.ID.String() + ":user:" + recipientUserID.String()
	_, err := tx.Exec(ctx, `
		INSERT INTO push_jobs(
		  recipient_user_id,event_type,resource_id,conversation_id,actor_user_id,
		  dedupe_key,payload_json,status,available_at,created_at
		) VALUES($1,$2,$3,$4,$5,$6,$7::jsonb,'PENDING',$8,$8)
		ON CONFLICT(dedupe_key) DO NOTHING
	`, recipientUserID, event.EventType, resourceID, event.ConversationID, actorUserID, dedupe, string(event.Payload), now)
	if err != nil {
		return fmt.Errorf("enqueue push job: %w", err)
	}
	return nil
}
