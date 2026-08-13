package groups

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var (
	ErrGroupCallConflict    = errors.New("group call conflict")
	ErrGroupCallFull        = errors.New("group call participant limit reached")
	ErrGroupCallUnavailable = errors.New("group call unavailable")
)

type GroupCallParticipant struct {
	User     UserPreview `json:"user"`
	JoinedAt time.Time   `json:"joinedAt"`
}

type GroupCall struct {
	ID              string                 `json:"id"`
	GroupID         string                 `json:"groupId"`
	Kind            string                 `json:"kind"`
	Status          string                 `json:"status"`
	StartedBy       UserPreview            `json:"startedBy"`
	StartedAt       time.Time              `json:"startedAt"`
	MaxParticipants int                    `json:"maxParticipants"`
	Participants    []GroupCallParticipant `json:"participants"`
}

type GroupCallJoin struct {
	Call       GroupCall `json:"call"`
	LiveKitURL string    `json:"livekitUrl"`
	Token      string    `json:"token"`
}

type groupCallConfig struct {
	media           groupCallMediaConfig
	maxParticipants int
}

type groupCallMediaConfig struct {
	url       string
	apiKey    string
	apiSecret string
}

func newGroupCallConfig(liveKitURL, liveKitAPIKey, liveKitAPISecret string, maxParticipants int) groupCallConfig {
	return groupCallConfig{
		media: groupCallMediaConfig{
			url:       strings.TrimSpace(liveKitURL),
			apiKey:    strings.TrimSpace(liveKitAPIKey),
			apiSecret: strings.TrimSpace(liveKitAPISecret),
		},
		maxParticipants: normalizeGroupCallParticipantLimit(maxParticipants),
	}
}

func (config groupCallConfig) runtime() (groupCallMediaConfig, error) {
	if config.media.url == "" || config.media.apiKey == "" || config.media.apiSecret == "" {
		return groupCallMediaConfig{}, ErrGroupCallUnavailable
	}
	return config.media, nil
}

func (service *Service) StartGroupCall(
	ctx context.Context,
	principal account.Principal,
	groupID uuid.UUID,
	kind string,
) (GroupCallJoin, []uuid.UUID, error) {
	kind = strings.ToUpper(strings.TrimSpace(kind))
	if kind != "AUDIO" && kind != "VIDEO" {
		return GroupCallJoin{}, nil, ErrInvalidInput
	}
	mediaConfig, err := service.groupCall.runtime()
	if err != nil {
		return GroupCallJoin{}, nil, err
	}
	maxParticipants := service.groupCall.maxParticipants
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return GroupCallJoin{}, nil, fmt.Errorf("begin group call: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := lockActiveGroupTx(ctx, tx, groupID); err != nil {
		return GroupCallJoin{}, nil, err
	}
	if err := requireGroupCallMemberTx(ctx, tx, principal.UserID, groupID); err != nil {
		return GroupCallJoin{}, nil, err
	}

	var sessionID uuid.UUID
	var roomName, existingKind string
	var sessionMaxParticipants int
	err = tx.QueryRow(ctx, `
		SELECT id,room_name,kind,max_participants
		FROM group_call_sessions
		WHERE conversation_id=$1 AND status='ACTIVE'
		FOR UPDATE
	`, groupID).Scan(&sessionID, &roomName, &existingKind, &sessionMaxParticipants)
	created := false
	if errors.Is(err, pgx.ErrNoRows) {
		sessionID = uuid.New()
		roomName = "dd-group-" + sessionID.String()
		sessionMaxParticipants = maxParticipants
		if _, err := tx.Exec(ctx, `
			INSERT INTO group_call_sessions(
				id,conversation_id,kind,status,room_name,started_by_user_id,
				started_by_device_id,max_participants,started_at
			) VALUES($1,$2,$3,'ACTIVE',$4,$5,$6,$7,$8)
		`, sessionID, groupID, kind, roomName, principal.UserID, principal.DeviceID, sessionMaxParticipants, now); err != nil {
			return GroupCallJoin{}, nil, fmt.Errorf("insert group call: %w", err)
		}
		created = true
	} else if err != nil {
		return GroupCallJoin{}, nil, fmt.Errorf("load active group call: %w", err)
	} else if existingKind != kind {
		return GroupCallJoin{}, nil, ErrGroupCallConflict
	}

	if err := joinGroupCallParticipantTx(
		ctx,
		tx,
		sessionID,
		principal.UserID,
		sessionMaxParticipants,
		now,
	); err != nil {
		return GroupCallJoin{}, nil, err
	}

	recipients, err := activeGroupMemberIDsTx(ctx, tx, groupID)
	if err != nil {
		return GroupCallJoin{}, nil, err
	}
	if created {
		if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_CALL_STARTED", nil, map[string]any{
			"groupId":         groupID.String(),
			"callId":          sessionID.String(),
			"kind":            kind,
			"startedByUserId": principal.UserID.String(),
		}, now); err != nil {
			return GroupCallJoin{}, nil, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return GroupCallJoin{}, nil, fmt.Errorf("commit group call: %w", err)
	}
	return service.groupCallJoinPayload(ctx, principal, groupID, sessionID, roomName, recipients, mediaConfig)
}

func (service *Service) JoinGroupCall(
	ctx context.Context,
	principal account.Principal,
	groupID, callID uuid.UUID,
) (GroupCallJoin, []uuid.UUID, error) {
	mediaConfig, err := service.groupCall.runtime()
	if err != nil {
		return GroupCallJoin{}, nil, err
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return GroupCallJoin{}, nil, fmt.Errorf("begin join group call: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := lockActiveGroupTx(ctx, tx, groupID); err != nil {
		return GroupCallJoin{}, nil, err
	}
	if err := requireGroupCallMemberTx(ctx, tx, principal.UserID, groupID); err != nil {
		return GroupCallJoin{}, nil, err
	}

	var roomName string
	var maxParticipants int
	if err := tx.QueryRow(ctx, `
		SELECT room_name,max_participants FROM group_call_sessions
		WHERE id=$1 AND conversation_id=$2 AND status='ACTIVE'
		FOR UPDATE
	`, callID, groupID).Scan(&roomName, &maxParticipants); errors.Is(err, pgx.ErrNoRows) {
		return GroupCallJoin{}, nil, ErrNotFound
	} else if err != nil {
		return GroupCallJoin{}, nil, fmt.Errorf("load group call join: %w", err)
	}
	if err := joinGroupCallParticipantTx(
		ctx,
		tx,
		callID,
		principal.UserID,
		maxParticipants,
		now,
	); err != nil {
		return GroupCallJoin{}, nil, err
	}
	recipients, err := activeGroupMemberIDsTx(ctx, tx, groupID)
	if err != nil {
		return GroupCallJoin{}, nil, err
	}
	if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_CALL_PARTICIPANTS_CHANGED", nil, map[string]any{
		"groupId": groupID.String(), "callId": callID.String(),
	}, now); err != nil {
		return GroupCallJoin{}, nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return GroupCallJoin{}, nil, fmt.Errorf("commit join group call: %w", err)
	}
	return service.groupCallJoinPayload(ctx, principal, groupID, callID, roomName, recipients, mediaConfig)
}

func (service *Service) LeaveGroupCall(
	ctx context.Context,
	principal account.Principal,
	groupID, callID uuid.UUID,
) (GroupCall, []uuid.UUID, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return GroupCall{}, nil, fmt.Errorf("begin leave group call: %w", err)
	}
	defer tx.Rollback(ctx)

	var status, kind string
	var startedAt time.Time
	var startedByUserID, startedByDeviceID uuid.UUID
	if err := tx.QueryRow(ctx, `
		SELECT status,kind,started_at,started_by_user_id,started_by_device_id
		FROM group_call_sessions
		WHERE id=$1 AND conversation_id=$2
		FOR UPDATE
	`, callID, groupID).Scan(
		&status,
		&kind,
		&startedAt,
		&startedByUserID,
		&startedByDeviceID,
	); errors.Is(err, pgx.ErrNoRows) {
		return GroupCall{}, nil, ErrNotFound
	} else if err != nil {
		return GroupCall{}, nil, fmt.Errorf("load group call leave: %w", err)
	}
	tag, err := tx.Exec(ctx, `
		UPDATE group_call_participants
		SET left_at=$3
		WHERE session_id=$1 AND user_id=$2 AND left_at IS NULL
	`, callID, principal.UserID, now)
	if err != nil {
		return GroupCall{}, nil, fmt.Errorf("leave group call participant: %w", err)
	}
	if tag.RowsAffected() == 0 {
		var knownParticipant bool
		if err := tx.QueryRow(ctx, `
			SELECT EXISTS(
				SELECT 1 FROM group_call_participants
				WHERE session_id=$1 AND user_id=$2
			)
		`, callID, principal.UserID).Scan(&knownParticipant); err != nil {
			return GroupCall{}, nil, fmt.Errorf("verify group call participant leave: %w", err)
		}
		if !knownParticipant {
			return GroupCall{}, nil, ErrForbidden
		}
	}
	var activeCount int
	if err := tx.QueryRow(ctx, `
		SELECT count(*) FROM group_call_participants
		WHERE session_id=$1 AND left_at IS NULL
	`, callID).Scan(&activeCount); err != nil {
		return GroupCall{}, nil, fmt.Errorf("count group call participants: %w", err)
	}
	eventType := "GROUP_CALL_PARTICIPANTS_CHANGED"
	if activeCount == 0 && status == "ACTIVE" {
		if _, err := tx.Exec(ctx, `
			UPDATE group_call_sessions SET status='ENDED',ended_at=$2
			WHERE id=$1 AND status='ACTIVE'
		`, callID, now); err != nil {
			return GroupCall{}, nil, fmt.Errorf("end empty group call: %w", err)
		}
		var participantCount int
		if err := tx.QueryRow(ctx, `
			SELECT count(*) FROM group_call_participants WHERE session_id=$1
		`, callID).Scan(&participantCount); err != nil {
			return GroupCall{}, nil, fmt.Errorf("count historical group call participants: %w", err)
		}
		if err := writeGroupCallSystemMessageTx(
			ctx,
			tx,
			groupID,
			callID,
			kind,
			startedAt,
			startedByUserID,
			startedByDeviceID,
			participantCount,
			now,
		); err != nil {
			return GroupCall{}, nil, err
		}
		eventType = "GROUP_CALL_ENDED"
	}
	recipients, err := activeGroupMemberIDsTx(ctx, tx, groupID)
	if err != nil {
		return GroupCall{}, nil, err
	}
	if err := insertGroupOutboxTx(ctx, tx, groupID, eventType, nil, map[string]any{
		"groupId": groupID.String(), "callId": callID.String(),
	}, now); err != nil {
		return GroupCall{}, nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return GroupCall{}, nil, fmt.Errorf("commit leave group call: %w", err)
	}
	call, err := service.loadGroupCall(ctx, groupID, callID)
	return call, recipients, err
}

func (service *Service) GetActiveGroupCall(
	ctx context.Context,
	principal account.Principal,
	groupID uuid.UUID,
) (GroupCall, error) {
	if err := service.requireActiveGroupMember(ctx, groupID, principal.UserID); err != nil {
		return GroupCall{}, err
	}
	var callID uuid.UUID
	if err := service.pool.QueryRow(ctx, `
		SELECT id FROM group_call_sessions
		WHERE conversation_id=$1 AND status='ACTIVE'
	`, groupID).Scan(&callID); errors.Is(err, pgx.ErrNoRows) {
		return GroupCall{}, ErrNotFound
	} else if err != nil {
		return GroupCall{}, fmt.Errorf("load active group call: %w", err)
	}
	return service.GetGroupCall(ctx, principal, groupID, callID)
}

func (service *Service) GetGroupCall(
	ctx context.Context,
	principal account.Principal,
	groupID, callID uuid.UUID,
) (GroupCall, error) {
	if err := service.requireActiveGroupMember(ctx, groupID, principal.UserID); err != nil {
		return GroupCall{}, err
	}
	return service.loadGroupCall(ctx, groupID, callID)
}

func (service *Service) loadGroupCall(
	ctx context.Context,
	groupID, callID uuid.UUID,
) (GroupCall, error) {
	var call GroupCall
	var startedByID, startedByHandle, startedByName string
	if err := service.pool.QueryRow(ctx, `
		SELECT s.id::text,s.conversation_id::text,s.kind,s.status,
		       u.id::text,u.handle_normalized,u.display_name,s.started_at,s.max_participants
		FROM group_call_sessions s
		JOIN users u ON u.id=s.started_by_user_id
		WHERE s.id=$1 AND s.conversation_id=$2
	`, callID, groupID).Scan(
		&call.ID,
		&call.GroupID,
		&call.Kind,
		&call.Status,
		&startedByID,
		&startedByHandle,
		&startedByName,
		&call.StartedAt,
		&call.MaxParticipants,
	); errors.Is(err, pgx.ErrNoRows) {
		return GroupCall{}, ErrNotFound
	} else if err != nil {
		return GroupCall{}, fmt.Errorf("load group call: %w", err)
	}
	call.StartedBy = UserPreview{ID: startedByID, Handle: startedByHandle, DisplayName: startedByName}
	rows, err := service.pool.Query(ctx, `
		SELECT u.id::text,u.handle_normalized,u.display_name,p.joined_at
		FROM group_call_participants p
		JOIN users u ON u.id=p.user_id
		WHERE p.session_id=$1 AND p.left_at IS NULL
		ORDER BY p.joined_at ASC,u.id ASC
	`, callID)
	if err != nil {
		return GroupCall{}, fmt.Errorf("list group call participants: %w", err)
	}
	defer rows.Close()
	call.Participants = []GroupCallParticipant{}
	for rows.Next() {
		var item GroupCallParticipant
		if err := rows.Scan(&item.User.ID, &item.User.Handle, &item.User.DisplayName, &item.JoinedAt); err != nil {
			return GroupCall{}, fmt.Errorf("scan group call participant: %w", err)
		}
		call.Participants = append(call.Participants, item)
	}
	if err := rows.Err(); err != nil {
		return GroupCall{}, fmt.Errorf("iterate group call participants: %w", err)
	}
	return call, nil
}

func (service *Service) groupCallJoinPayload(
	ctx context.Context,
	principal account.Principal,
	groupID, callID uuid.UUID,
	roomName string,
	recipients []uuid.UUID,
	mediaConfig groupCallMediaConfig,
) (GroupCallJoin, []uuid.UUID, error) {
	call, err := service.GetGroupCall(ctx, principal, groupID, callID)
	if err != nil {
		return GroupCallJoin{}, nil, err
	}
	identity := principal.UserID.String() + ":" + principal.DeviceID.String()
	var participantName string
	if err := service.pool.QueryRow(ctx, `SELECT display_name FROM users WHERE id=$1 AND status='ACTIVE'`, principal.UserID).Scan(&participantName); err != nil {
		return GroupCallJoin{}, nil, fmt.Errorf("load group call participant name: %w", err)
	}
	token, err := issueLiveKitRoomToken(
		mediaConfig.apiKey,
		mediaConfig.apiSecret,
		identity,
		participantName,
		roomName,
		service.now().UTC(),
	)
	if err != nil {
		return GroupCallJoin{}, nil, err
	}
	return GroupCallJoin{Call: call, LiveKitURL: mediaConfig.url, Token: token}, recipients, nil
}

func requireGroupCallMemberTx(
	ctx context.Context,
	tx pgx.Tx,
	userID, groupID uuid.UUID,
) error {
	if _, err := requireGroupRoleTx(ctx, tx, userID, groupID); err != nil {
		if errors.Is(err, ErrNotFound) {
			return ErrForbidden
		}
		return err
	}
	return nil
}

func (service *Service) requireActiveGroupMember(ctx context.Context, groupID, userID uuid.UUID) error {
	var active bool
	if err := service.pool.QueryRow(ctx, `
		SELECT EXISTS(
			SELECT 1 FROM groups g
			JOIN conversation_members m ON m.conversation_id=g.conversation_id
			WHERE g.conversation_id=$1 AND g.status='ACTIVE'
			  AND m.user_id=$2 AND m.status='ACTIVE'
		)
	`, groupID, userID).Scan(&active); err != nil {
		return fmt.Errorf("verify group call membership: %w", err)
	}
	if !active {
		return ErrForbidden
	}
	return nil
}

func activeGroupMemberIDsTx(ctx context.Context, tx pgx.Tx, groupID uuid.UUID) ([]uuid.UUID, error) {
	rows, err := tx.Query(ctx, `
		SELECT user_id FROM conversation_members
		WHERE conversation_id=$1 AND status='ACTIVE'
		ORDER BY joined_at ASC,user_id ASC
	`, groupID)
	if err != nil {
		return nil, fmt.Errorf("list group call recipients: %w", err)
	}
	defer rows.Close()
	recipients := []uuid.UUID{}
	for rows.Next() {
		var userID uuid.UUID
		if err := rows.Scan(&userID); err != nil {
			return nil, fmt.Errorf("scan group call recipient: %w", err)
		}
		recipients = append(recipients, userID)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate group call recipients: %w", err)
	}
	return recipients, nil
}

func detachActiveGroupCallParticipantTx(
	ctx context.Context,
	tx pgx.Tx,
	groupID, userID uuid.UUID,
	now time.Time,
) error {
	var callID, startedByUserID, startedByDeviceID uuid.UUID
	var kind string
	var startedAt time.Time
	if err := tx.QueryRow(ctx, `
		SELECT id,kind,started_at,started_by_user_id,started_by_device_id
		FROM group_call_sessions
		WHERE conversation_id=$1 AND status='ACTIVE'
		FOR UPDATE
	`, groupID).Scan(
		&callID,
		&kind,
		&startedAt,
		&startedByUserID,
		&startedByDeviceID,
	); errors.Is(err, pgx.ErrNoRows) {
		return nil
	} else if err != nil {
		return fmt.Errorf("load active group call for membership removal: %w", err)
	}
	tag, err := tx.Exec(ctx, `
		UPDATE group_call_participants SET left_at=$3
		WHERE session_id=$1 AND user_id=$2 AND left_at IS NULL
	`, callID, userID, now)
	if err != nil {
		return fmt.Errorf("detach removed group call participant: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return nil
	}
	return finalizeGroupCallParticipantChangeTx(
		ctx,
		tx,
		groupID,
		callID,
		kind,
		startedAt,
		startedByUserID,
		startedByDeviceID,
		now,
	)
}

func terminateActiveGroupCallTx(
	ctx context.Context,
	tx pgx.Tx,
	groupID uuid.UUID,
	now time.Time,
) error {
	var callID, startedByUserID, startedByDeviceID uuid.UUID
	var kind string
	var startedAt time.Time
	if err := tx.QueryRow(ctx, `
		SELECT id,kind,started_at,started_by_user_id,started_by_device_id
		FROM group_call_sessions
		WHERE conversation_id=$1 AND status='ACTIVE'
		FOR UPDATE
	`, groupID).Scan(
		&callID,
		&kind,
		&startedAt,
		&startedByUserID,
		&startedByDeviceID,
	); errors.Is(err, pgx.ErrNoRows) {
		return nil
	} else if err != nil {
		return fmt.Errorf("load active group call for dissolve: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE group_call_participants SET left_at=COALESCE(left_at,$2)
		WHERE session_id=$1
	`, callID, now); err != nil {
		return fmt.Errorf("detach dissolved group call participants: %w", err)
	}
	return endGroupCallTx(
		ctx,
		tx,
		groupID,
		callID,
		kind,
		startedAt,
		startedByUserID,
		startedByDeviceID,
		now,
	)
}

func finalizeGroupCallParticipantChangeTx(
	ctx context.Context,
	tx pgx.Tx,
	groupID, callID uuid.UUID,
	kind string,
	startedAt time.Time,
	startedByUserID, startedByDeviceID uuid.UUID,
	now time.Time,
) error {
	var activeCount int
	if err := tx.QueryRow(ctx, `
		SELECT count(*) FROM group_call_participants
		WHERE session_id=$1 AND left_at IS NULL
	`, callID).Scan(&activeCount); err != nil {
		return fmt.Errorf("count active group call participants: %w", err)
	}
	if activeCount == 0 {
		return endGroupCallTx(
			ctx,
			tx,
			groupID,
			callID,
			kind,
			startedAt,
			startedByUserID,
			startedByDeviceID,
			now,
		)
	}
	return insertGroupOutboxTx(ctx, tx, groupID, "GROUP_CALL_PARTICIPANTS_CHANGED", nil, map[string]any{
		"groupId": groupID.String(), "callId": callID.String(),
	}, now)
}

func endGroupCallTx(
	ctx context.Context,
	tx pgx.Tx,
	groupID, callID uuid.UUID,
	kind string,
	startedAt time.Time,
	startedByUserID, startedByDeviceID uuid.UUID,
	now time.Time,
) error {
	tag, err := tx.Exec(ctx, `
		UPDATE group_call_sessions SET status='ENDED',ended_at=$2
		WHERE id=$1 AND status='ACTIVE'
	`, callID, now)
	if err != nil {
		return fmt.Errorf("end group call: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return nil
	}
	var participantCount int
	if err := tx.QueryRow(ctx, `
		SELECT count(*) FROM group_call_participants WHERE session_id=$1
	`, callID).Scan(&participantCount); err != nil {
		return fmt.Errorf("count historical group call participants: %w", err)
	}
	if err := writeGroupCallSystemMessageTx(
		ctx,
		tx,
		groupID,
		callID,
		kind,
		startedAt,
		startedByUserID,
		startedByDeviceID,
		participantCount,
		now,
	); err != nil {
		return err
	}
	return insertGroupOutboxTx(ctx, tx, groupID, "GROUP_CALL_ENDED", nil, map[string]any{
		"groupId": groupID.String(), "callId": callID.String(),
	}, now)
}

func writeGroupCallSystemMessageTx(
	ctx context.Context,
	tx pgx.Tx,
	groupID, callID uuid.UUID,
	kind string,
	startedAt time.Time,
	startedByUserID, startedByDeviceID uuid.UUID,
	participantCount int,
	now time.Time,
) error {
	label := "群语音通话"
	if kind == "VIDEO" {
		label = "群视频通话"
	}
	duration := now.Sub(startedAt.UTC())
	if duration < 0 {
		duration = 0
	}
	seconds := int(duration.Round(time.Second) / time.Second)
	text := fmt.Sprintf(
		"[%s] 通话时长 %02d:%02d · %d 人参与",
		label,
		seconds/60,
		seconds%60,
		participantCount,
	)
	contentJSON, err := json.Marshal(map[string]any{"text": text})
	if err != nil {
		return fmt.Errorf("marshal group call system message: %w", err)
	}
	var sequence int64
	if err := tx.QueryRow(ctx, `
		UPDATE conversations
		SET last_sequence=last_sequence+1,updated_at=$2
		WHERE id=$1 AND type='GROUP'
		RETURNING last_sequence
	`, groupID, now).Scan(&sequence); errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("group call conversation unavailable")
	} else if err != nil {
		return fmt.Errorf("allocate group call system message sequence: %w", err)
	}
	messageID := uuid.New()
	clientMessageID := "group-call-" + strings.ReplaceAll(callID.String(), "-", "")
	if _, err := tx.Exec(ctx, `
		INSERT INTO messages(
			id,conversation_id,sequence,sender_user_id,sender_device_id,
			client_message_id,type,content_json,created_at
		) VALUES($1,$2,$3,$4,$5,$6,'SYSTEM',$7::jsonb,$8)
	`, messageID, groupID, sequence, startedByUserID, startedByDeviceID, clientMessageID, string(contentJSON), now); err != nil {
		return fmt.Errorf("insert group call system message: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE conversations SET last_message_id=$2,updated_at=$3 WHERE id=$1
	`, groupID, messageID, now); err != nil {
		return fmt.Errorf("update group call conversation message: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE conversation_members
		SET archived_at=NULL,hidden_through_sequence=NULL
		WHERE conversation_id=$1 AND status='ACTIVE'
	`, groupID); err != nil {
		return fmt.Errorf("wake group call conversation: %w", err)
	}
	payloadJSON, err := json.Marshal(map[string]any{
		"messageId":      messageID.String(),
		"conversationId": groupID.String(),
		"sequence":       sequence,
	})
	if err != nil {
		return fmt.Errorf("marshal group call outbox payload: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO outbox_events(
			aggregate_type,aggregate_id,event_type,conversation_id,sequence,
			payload_json,created_at,available_at
		) VALUES('MESSAGE',$1,'MESSAGE_CREATED',$2,$3,$4::jsonb,$5,$5)
	`, messageID, groupID, sequence, string(payloadJSON), now); err != nil {
		return fmt.Errorf("insert group call message outbox: %w", err)
	}
	return nil
}

func normalizeGroupCallParticipantLimit(value int) int {
	const defaultLimit = 32
	if value < 2 || value > MaximumGroupMembers {
		return defaultLimit
	}
	return value
}

func joinGroupCallParticipantTx(
	ctx context.Context,
	tx pgx.Tx,
	callID, userID uuid.UUID,
	maxParticipants int,
	now time.Time,
) error {
	var alreadyActive bool
	if err := tx.QueryRow(ctx, `
		SELECT EXISTS(
			SELECT 1 FROM group_call_participants
			WHERE session_id=$1 AND user_id=$2 AND left_at IS NULL
		)
	`, callID, userID).Scan(&alreadyActive); err != nil {
		return fmt.Errorf("check group call participant: %w", err)
	}
	if !alreadyActive {
		var activeCount int
		if err := tx.QueryRow(ctx, `
			SELECT count(*) FROM group_call_participants
			WHERE session_id=$1 AND left_at IS NULL
		`, callID).Scan(&activeCount); err != nil {
			return fmt.Errorf("count group call participants: %w", err)
		}
		if activeCount >= maxParticipants {
			return ErrGroupCallFull
		}
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO group_call_participants(session_id,user_id,joined_at,left_at)
		VALUES($1,$2,$3,NULL)
		ON CONFLICT(session_id,user_id)
		DO UPDATE SET joined_at=CASE
			WHEN group_call_participants.left_at IS NULL THEN group_call_participants.joined_at
			ELSE EXCLUDED.joined_at
		END,left_at=NULL
	`, callID, userID, now); err != nil {
		return fmt.Errorf("upsert group call participant: %w", err)
	}
	return nil
}

func issueLiveKitRoomToken(
	apiKey, apiSecret, identity, name, room string,
	now time.Time,
) (string, error) {
	if apiKey == "" || apiSecret == "" || identity == "" || room == "" {
		return "", ErrGroupCallUnavailable
	}
	header, _ := json.Marshal(map[string]any{"alg": "HS256", "typ": "JWT"})
	claims := map[string]any{
		"iss":  apiKey,
		"sub":  identity,
		"nbf":  now.Unix() - 5,
		"exp":  now.Add(2 * time.Hour).Unix(),
		"name": name,
		"video": map[string]any{
			"roomJoin":       true,
			"room":           room,
			"canPublish":     true,
			"canSubscribe":   true,
			"canPublishData": true,
		},
	}
	payload, err := json.Marshal(claims)
	if err != nil {
		return "", fmt.Errorf("marshal livekit claims: %w", err)
	}
	encode := base64.RawURLEncoding.EncodeToString
	unsigned := encode(header) + "." + encode(payload)
	mac := hmac.New(sha256.New, []byte(apiSecret))
	_, _ = mac.Write([]byte(unsigned))
	return unsigned + "." + encode(mac.Sum(nil)), nil
}
