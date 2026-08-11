package calls

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
	"github.com/jackc/pgx/v5/pgxpool"
)

type Service struct {
	pool        *pgxpool.Pool
	now         func() time.Time
	ringTimeout time.Duration
}

type Config struct {
	Pool        *pgxpool.Pool
	Now         func() time.Time
	RingTimeout time.Duration
}

func NewService(config Config) (*Service, error) {
	if config.Pool == nil {
		return nil, ErrUnavailable
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	ringTimeout := config.RingTimeout
	if ringTimeout <= 0 {
		ringTimeout = 30 * time.Second
	}
	return &Service{pool: config.Pool, now: now, ringTimeout: ringTimeout}, nil
}

func (service *Service) Create(ctx context.Context, principal account.Principal, raw CreateInput) (Call, error) {
	calleeID, err := uuid.Parse(strings.TrimSpace(raw.CalleeUserID))
	if err != nil || calleeID == uuid.Nil || calleeID == principal.UserID {
		return Call{}, ErrInvalidInput
	}
	kind := strings.ToLower(strings.TrimSpace(raw.Kind))
	if kind != KindAudio && kind != KindVideo {
		return Call{}, ErrInvalidInput
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return Call{}, fmt.Errorf("begin create call: %w", err)
	}
	defer tx.Rollback(ctx)

	if err := lockCallParticipants(ctx, tx, principal.UserID, calleeID); err != nil {
		return Call{}, err
	}
	if _, err := expireOverdueForUsersTx(ctx, tx, []uuid.UUID{principal.UserID, calleeID}, now); err != nil {
		return Call{}, err
	}
	var callerName, calleeName string
	if err := tx.QueryRow(ctx, `
		SELECT caller.display_name,callee.display_name
		FROM users caller, users callee
		WHERE caller.id=$1 AND caller.status='ACTIVE' AND callee.id=$2 AND callee.status='ACTIVE'
	`, principal.UserID, calleeID).Scan(&callerName, &calleeName); errors.Is(err, pgx.ErrNoRows) {
		return Call{}, ErrNotFound
	} else if err != nil {
		return Call{}, fmt.Errorf("load call participants: %w", err)
	}
	var isContact, blocked bool
	if err := tx.QueryRow(ctx, `
		SELECT
		  EXISTS(SELECT 1 FROM contacts WHERE owner_user_id=$1 AND contact_user_id=$2),
		  EXISTS(SELECT 1 FROM blocks WHERE (owner_user_id=$1 AND blocked_user_id=$2) OR (owner_user_id=$2 AND blocked_user_id=$1))
	`, principal.UserID, calleeID).Scan(&isContact, &blocked); err != nil {
		return Call{}, fmt.Errorf("authorize call relationship: %w", err)
	}
	if blocked {
		return Call{}, ErrBlocked
	}
	if !isContact {
		return Call{}, ErrForbidden
	}
	var conversationID uuid.UUID
	if err := tx.QueryRow(ctx, `
		SELECT c.id
		FROM conversations c
		JOIN conversation_members caller
		  ON caller.conversation_id=c.id AND caller.user_id=$1 AND caller.status='ACTIVE'
		JOIN conversation_members callee
		  ON callee.conversation_id=c.id AND callee.user_id=$2 AND callee.status='ACTIVE'
		WHERE c.type='DIRECT'
		ORDER BY c.created_at
		LIMIT 1
	`, principal.UserID, calleeID).Scan(&conversationID); errors.Is(err, pgx.ErrNoRows) {
		return Call{}, ErrConflict
	} else if err != nil {
		return Call{}, fmt.Errorf("load call conversation: %w", err)
	}
	var active bool
	if err := tx.QueryRow(ctx, `
		SELECT EXISTS(
		  SELECT 1 FROM calls
		  WHERE status IN ('ringing','accepted')
		    AND (caller_user_id=ANY($1::uuid[]) OR callee_user_id=ANY($1::uuid[]))
		)
	`, []uuid.UUID{principal.UserID, calleeID}).Scan(&active); err != nil {
		return Call{}, fmt.Errorf("check active call conflict: %w", err)
	}
	if active {
		return Call{}, ErrBusy
	}
	callID := uuid.New()
	roomName := "dd-call-" + strings.ReplaceAll(callID.String(), "-", "")
	ringExpiresAt := now.Add(service.ringTimeout)
	if _, err := tx.Exec(ctx, `
		INSERT INTO calls(
		  id,caller_user_id,callee_user_id,caller_device_id,conversation_id,room_name,kind,status,
		  created_at,ring_expires_at,version
		) VALUES($1,$2,$3,$4,$5,$6,$7,'ringing',$8,$9,0)
	`, callID, principal.UserID, calleeID, principal.DeviceID, conversationID, roomName, kind, now, ringExpiresAt); err != nil {
		return Call{}, fmt.Errorf("insert call: %w", err)
	}
	callPayload, err := json.Marshal(map[string]any{
		"callId":         callID.String(),
		"conversationId": conversationID.String(),
		"callerUserId":   principal.UserID.String(),
		"callerName":     callerName,
		"kind":           kind,
	})
	if err != nil {
		return Call{}, fmt.Errorf("marshal call ringing outbox: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO outbox_events(
		  aggregate_type,aggregate_id,event_type,conversation_id,target_user_id,payload_json,created_at,available_at
		) VALUES('CALL',$1,'CALL_RINGING',$2,$3,$4::jsonb,$5,$5)
	`, callID, conversationID, calleeID, string(callPayload), now); err != nil {
		return Call{}, fmt.Errorf("insert call ringing outbox: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Call{}, fmt.Errorf("commit create call: %w", err)
	}
	return Call{
		ID:                callID.String(),
		RoomName:          roomName,
		CallerIdentity:    principal.UserID.String(),
		CallerName:        callerName,
		CalleeIdentity:    calleeID.String(),
		CalleeName:        calleeName,
		Kind:              kind,
		Status:            StatusRinging,
		CreatedAt:         now,
		RingTimeoutSecond: int(service.ringTimeout.Seconds()),
	}, nil
}

func (service *Service) GetActive(ctx context.Context, principal account.Principal) (*Call, error) {
	now := service.now().UTC()
	if _, err := service.ExpireOverdueForUser(ctx, principal.UserID); err != nil {
		return nil, err
	}
	row := service.pool.QueryRow(ctx, `
		SELECT c.id::text,c.room_name,c.caller_user_id::text,caller.display_name,
		       c.callee_user_id::text,callee.display_name,c.kind,c.status,c.created_at,
		       c.accepted_at,c.ended_at,COALESCE(c.end_reason,''),c.ring_expires_at
		FROM calls c
		JOIN users caller ON caller.id=c.caller_user_id
		JOIN users callee ON callee.id=c.callee_user_id
		WHERE (
		  c.status='ringing' AND (
		    (c.caller_user_id=$1 AND c.caller_device_id=$2)
		    OR c.callee_user_id=$1
		  )
		) OR (
		  c.status='accepted' AND (
		    (c.caller_user_id=$1 AND c.caller_device_id=$2)
		    OR (c.callee_user_id=$1 AND c.answered_device_id=$2)
		  )
		)
		ORDER BY c.created_at DESC
		LIMIT 1
	`, principal.UserID, principal.DeviceID)
	call, err := service.scanCall(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("load active call: %w", err)
	}
	if call.Status == StatusRinging && call.CreatedAt.Add(time.Duration(call.RingTimeoutSecond)*time.Second).Before(now) {
		return nil, nil
	}
	return &call, nil
}

func (service *Service) ApplyAction(ctx context.Context, principal account.Principal, callID uuid.UUID, raw ActionInput) (Call, error) {
	if callID == uuid.Nil {
		return Call{}, ErrNotFound
	}
	action := strings.ToLower(strings.TrimSpace(raw.Action))
	if action != "accept" && action != "reject" && action != "hangup" {
		return Call{}, ErrInvalidInput
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return Call{}, fmt.Errorf("begin call action: %w", err)
	}
	defer tx.Rollback(ctx)

	state, err := loadCallStateForUpdate(ctx, tx, callID)
	if err != nil {
		return Call{}, err
	}
	if principal.UserID != state.callerUserID && principal.UserID != state.calleeUserID {
		return Call{}, ErrForbidden
	}
	if state.status == StatusRinging && !state.ringExpiresAt.After(now) {
		if err := endRingingCallTx(ctx, tx, callID, now, "timeout"); err != nil {
			return Call{}, err
		}
		return Call{}, ErrConflict
	}

	switch action {
	case "accept":
		if state.status != StatusRinging || principal.UserID != state.calleeUserID {
			return Call{}, ErrConflict
		}
		if _, err := tx.Exec(ctx, `
			UPDATE calls SET status='accepted',accepted_at=$2,answered_device_id=$3,version=version+1
			WHERE id=$1
		`, callID, now, principal.DeviceID); err != nil {
			return Call{}, fmt.Errorf("accept call: %w", err)
		}
	case "reject":
		if state.status != StatusRinging || principal.UserID != state.calleeUserID {
			return Call{}, ErrConflict
		}
		if _, err := tx.Exec(ctx, `
			UPDATE calls SET status='rejected',ended_at=$2,end_reason='rejected',version=version+1
			WHERE id=$1
		`, callID, now); err != nil {
			return Call{}, fmt.Errorf("reject call: %w", err)
		}
	case "hangup":
		switch state.status {
		case StatusRinging:
			if principal.UserID != state.callerUserID || principal.DeviceID != state.callerDeviceID {
				return Call{}, ErrForbidden
			}
			if err := endRingingCallTx(ctx, tx, callID, now, "cancelled"); err != nil {
				return Call{}, err
			}
		case StatusAccepted:
			if !state.deviceCanControl(principal) {
				return Call{}, ErrForbidden
			}
			if _, err := tx.Exec(ctx, `
				UPDATE calls SET status='ended',ended_at=$2,end_reason='hung_up',version=version+1
				WHERE id=$1
			`, callID, now); err != nil {
				return Call{}, fmt.Errorf("hang up call: %w", err)
			}
		default:
			return Call{}, ErrConflict
		}
	}
	call, err := service.scanCall(tx.QueryRow(ctx, callSelectByIDSQL, callID))
	if err != nil {
		return Call{}, fmt.Errorf("load call after action: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Call{}, fmt.Errorf("commit call action: %w", err)
	}
	return call, nil
}

func (service *Service) AuthorizeToken(ctx context.Context, principal account.Principal, callID uuid.UUID) (TokenAuthorization, error) {
	if callID == uuid.Nil {
		return TokenAuthorization{}, ErrNotFound
	}
	state, err := loadCallState(ctx, service.pool, callID)
	if err != nil {
		return TokenAuthorization{}, err
	}
	if state.status != StatusAccepted || !state.deviceCanControl(principal) {
		if principal.UserID != state.callerUserID && principal.UserID != state.calleeUserID {
			return TokenAuthorization{}, ErrForbidden
		}
		return TokenAuthorization{}, ErrConflict
	}
	call, err := service.scanCall(service.pool.QueryRow(ctx, callSelectByIDSQL, callID))
	if err != nil {
		return TokenAuthorization{}, fmt.Errorf("load call token context: %w", err)
	}
	participantName := call.CallerName
	if principal.UserID == state.calleeUserID {
		participantName = call.CalleeName
	}
	return TokenAuthorization{
		Call:            call,
		RoomName:        call.RoomName,
		ParticipantID:   principal.UserID.String(),
		ParticipantName: participantName,
	}, nil
}

func (service *Service) Timeout(ctx context.Context, callID uuid.UUID) (Call, bool, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return Call{}, false, fmt.Errorf("begin call timeout: %w", err)
	}
	defer tx.Rollback(ctx)
	state, err := loadCallStateForUpdate(ctx, tx, callID)
	if errors.Is(err, ErrNotFound) {
		return Call{}, false, nil
	}
	if err != nil {
		return Call{}, false, err
	}
	if state.status != StatusRinging || state.ringExpiresAt.After(now) {
		return Call{}, false, nil
	}
	if err := endRingingCallTx(ctx, tx, callID, now, "timeout"); err != nil {
		return Call{}, false, err
	}
	if err := writeCallSystemMessageTx(ctx, tx, callID, state, "timeout", now); err != nil {
		return Call{}, false, err
	}
	call, err := service.scanCall(tx.QueryRow(ctx, callSelectByIDSQL, callID))
	if err != nil {
		return Call{}, false, fmt.Errorf("load timed out call: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Call{}, false, fmt.Errorf("commit call timeout: %w", err)
	}
	return call, true, nil
}

func (service *Service) ExpireOverdueForUser(ctx context.Context, userID uuid.UUID) ([]uuid.UUID, error) {
	if userID == uuid.Nil {
		return nil, nil
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, fmt.Errorf("begin expire overdue calls: %w", err)
	}
	defer tx.Rollback(ctx)
	participants, err := expireOverdueForUsersTx(ctx, tx, []uuid.UUID{userID}, now)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit expire overdue calls: %w", err)
	}
	return participants, nil
}

func (service *Service) scanCall(row pgx.Row) (Call, error) {
	var call Call
	var ringExpiresAt time.Time
	if err := row.Scan(
		&call.ID,
		&call.RoomName,
		&call.CallerIdentity,
		&call.CallerName,
		&call.CalleeIdentity,
		&call.CalleeName,
		&call.Kind,
		&call.Status,
		&call.CreatedAt,
		&call.AcceptedAt,
		&call.EndedAt,
		&call.EndReason,
		&ringExpiresAt,
	); err != nil {
		return Call{}, err
	}
	call.CreatedAt = call.CreatedAt.UTC()
	if call.AcceptedAt != nil {
		value := call.AcceptedAt.UTC()
		call.AcceptedAt = &value
	}
	if call.EndedAt != nil {
		value := call.EndedAt.UTC()
		call.EndedAt = &value
	}
	seconds := int(ringExpiresAt.Sub(call.CreatedAt).Round(time.Second) / time.Second)
	if seconds < 1 {
		seconds = int(service.ringTimeout.Seconds())
	}
	call.RingTimeoutSecond = seconds
	return call, nil
}

const callSelectByIDSQL = `
	SELECT c.id::text,c.room_name,c.caller_user_id::text,caller.display_name,
	       c.callee_user_id::text,callee.display_name,c.kind,c.status,c.created_at,
	       c.accepted_at,c.ended_at,COALESCE(c.end_reason,''),c.ring_expires_at
	FROM calls c
	JOIN users caller ON caller.id=c.caller_user_id
	JOIN users callee ON callee.id=c.callee_user_id
	WHERE c.id=$1
`

type callState struct {
	callerUserID     uuid.UUID
	calleeUserID     uuid.UUID
	callerDeviceID   uuid.UUID
	answeredDeviceID *uuid.UUID
	conversationID   uuid.UUID
	kind             string
	status           string
	acceptedAt       *time.Time
	ringExpiresAt    time.Time
}

func (state callState) deviceCanControl(principal account.Principal) bool {
	if principal.UserID == state.callerUserID {
		return principal.DeviceID == state.callerDeviceID
	}
	if principal.UserID == state.calleeUserID && state.answeredDeviceID != nil {
		return principal.DeviceID == *state.answeredDeviceID
	}
	return false
}

func loadCallState(ctx context.Context, queryer interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}, callID uuid.UUID) (callState, error) {
	var state callState
	if err := queryer.QueryRow(ctx, `
		SELECT caller_user_id,callee_user_id,caller_device_id,answered_device_id,conversation_id,kind,status,accepted_at,ring_expires_at
		FROM calls WHERE id=$1
	`, callID).Scan(
		&state.callerUserID,
		&state.calleeUserID,
		&state.callerDeviceID,
		&state.answeredDeviceID,
		&state.conversationID,
		&state.kind,
		&state.status,
		&state.acceptedAt,
		&state.ringExpiresAt,
	); errors.Is(err, pgx.ErrNoRows) {
		return callState{}, ErrNotFound
	} else if err != nil {
		return callState{}, fmt.Errorf("load call state: %w", err)
	}
	return state, nil
}

func loadCallStateForUpdate(ctx context.Context, tx pgx.Tx, callID uuid.UUID) (callState, error) {
	var state callState
	if err := tx.QueryRow(ctx, `
		SELECT caller_user_id,callee_user_id,caller_device_id,answered_device_id,conversation_id,kind,status,accepted_at,ring_expires_at
		FROM calls WHERE id=$1 FOR UPDATE
	`, callID).Scan(
		&state.callerUserID,
		&state.calleeUserID,
		&state.callerDeviceID,
		&state.answeredDeviceID,
		&state.conversationID,
		&state.kind,
		&state.status,
		&state.acceptedAt,
		&state.ringExpiresAt,
	); errors.Is(err, pgx.ErrNoRows) {
		return callState{}, ErrNotFound
	} else if err != nil {
		return callState{}, fmt.Errorf("lock call state: %w", err)
	}
	return state, nil
}

func endRingingCallTx(ctx context.Context, tx pgx.Tx, callID uuid.UUID, now time.Time, reason string) error {
	if _, err := tx.Exec(ctx, `
		UPDATE calls SET status='ended',ended_at=$2,end_reason=$3,version=version+1
		WHERE id=$1 AND status='ringing'
	`, callID, now, reason); err != nil {
		return fmt.Errorf("end ringing call: %w", err)
	}
	return nil
}

func expireOverdueForUsersTx(ctx context.Context, tx pgx.Tx, userIDs []uuid.UUID, now time.Time) ([]uuid.UUID, error) {
	rows, err := tx.Query(ctx, `
		SELECT id,caller_user_id,callee_user_id,caller_device_id,answered_device_id,
		       conversation_id,kind,status,accepted_at,ring_expires_at
		FROM calls
		WHERE status='ringing' AND ring_expires_at<=$2
		  AND (caller_user_id=ANY($1::uuid[]) OR callee_user_id=ANY($1::uuid[]))
		ORDER BY id
		FOR UPDATE
	`, userIDs, now)
	if err != nil {
		return nil, fmt.Errorf("load overdue calls: %w", err)
	}
	type overdueCall struct {
		id    uuid.UUID
		state callState
	}
	overdue := make([]overdueCall, 0)
	for rows.Next() {
		var item overdueCall
		if err := rows.Scan(
			&item.id,
			&item.state.callerUserID,
			&item.state.calleeUserID,
			&item.state.callerDeviceID,
			&item.state.answeredDeviceID,
			&item.state.conversationID,
			&item.state.kind,
			&item.state.status,
			&item.state.acceptedAt,
			&item.state.ringExpiresAt,
		); err != nil {
			rows.Close()
			return nil, fmt.Errorf("scan overdue call: %w", err)
		}
		overdue = append(overdue, item)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate overdue calls: %w", err)
	}

	seen := map[uuid.UUID]struct{}{}
	for _, item := range overdue {
		if err := endRingingCallTx(ctx, tx, item.id, now, "timeout"); err != nil {
			return nil, err
		}
		if err := writeCallSystemMessageTx(ctx, tx, item.id, item.state, "timeout", now); err != nil {
			return nil, err
		}
		seen[item.state.callerUserID] = struct{}{}
		seen[item.state.calleeUserID] = struct{}{}
	}
	result := make([]uuid.UUID, 0, len(seen))
	for userID := range seen {
		result = append(result, userID)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].String() < result[j].String() })
	return result, nil
}

func writeCallSystemMessageTx(ctx context.Context, tx pgx.Tx, callID uuid.UUID, state callState, reason string, now time.Time) error {
	if state.conversationID == uuid.Nil || state.callerUserID == uuid.Nil || state.callerDeviceID == uuid.Nil {
		return fmt.Errorf("call system message missing conversation or sender identity")
	}
	label := "语音通话"
	if state.kind == KindVideo {
		label = "视频通话"
	}
	text := "[" + label + "] "
	switch reason {
	case "hung_up":
		if state.acceptedAt != nil {
			duration := now.Sub(state.acceptedAt.UTC())
			if duration < 0 {
				duration = 0
			}
			seconds := int(duration.Round(time.Second) / time.Second)
			text += fmt.Sprintf("通话时长 %02d:%02d", seconds/60, seconds%60)
		} else {
			text += "通话已结束"
		}
	case "rejected":
		text += "已拒绝"
	case "timeout":
		text += "对方无应答"
	case "cancelled":
		text += "已取消"
	default:
		text += "通话已结束"
	}
	contentJSON, err := json.Marshal(map[string]any{"text": text})
	if err != nil {
		return fmt.Errorf("marshal call system message: %w", err)
	}
	var sequence int64
	if err := tx.QueryRow(ctx, `
		UPDATE conversations
		SET last_sequence=last_sequence+1,updated_at=$2
		WHERE id=$1 AND type='DIRECT'
		RETURNING last_sequence
	`, state.conversationID, now).Scan(&sequence); errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("call conversation unavailable")
	} else if err != nil {
		return fmt.Errorf("allocate call system message sequence: %w", err)
	}
	messageID := uuid.New()
	clientMessageID := "call-" + strings.ReplaceAll(callID.String(), "-", "")
	if _, err := tx.Exec(ctx, `
		INSERT INTO messages(
		  id,conversation_id,sequence,sender_user_id,sender_device_id,
		  client_message_id,type,content_json,created_at
		) VALUES($1,$2,$3,$4,$5,$6,'SYSTEM',$7::jsonb,$8)
	`, messageID, state.conversationID, sequence, state.callerUserID, state.callerDeviceID, clientMessageID, string(contentJSON), now); err != nil {
		return fmt.Errorf("insert call system message: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE conversations SET last_message_id=$2,updated_at=$3 WHERE id=$1
	`, state.conversationID, messageID, now); err != nil {
		return fmt.Errorf("update conversation call message: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE conversation_members
		SET archived_at=NULL,hidden_through_sequence=NULL
		WHERE conversation_id=$1 AND status='ACTIVE'
	`, state.conversationID); err != nil {
		return fmt.Errorf("wake call conversation: %w", err)
	}
	payloadJSON, err := json.Marshal(map[string]any{
		"messageId":      messageID.String(),
		"conversationId": state.conversationID.String(),
		"sequence":       sequence,
	})
	if err != nil {
		return fmt.Errorf("marshal call outbox payload: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO outbox_events(
		  aggregate_type,aggregate_id,event_type,conversation_id,sequence,
		  payload_json,created_at,available_at
		) VALUES('MESSAGE',$1,'MESSAGE_CREATED',$2,$3,$4::jsonb,$5,$5)
	`, messageID, state.conversationID, sequence, string(payloadJSON), now); err != nil {
		return fmt.Errorf("insert call message outbox: %w", err)
	}
	return nil
}

func lockCallParticipants(ctx context.Context, tx pgx.Tx, a, b uuid.UUID) error {
	keys := []string{a.String(), b.String()}
	sort.Strings(keys)
	for _, key := range keys {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, key); err != nil {
			return fmt.Errorf("lock call participant: %w", err)
		}
	}
	return nil
}
