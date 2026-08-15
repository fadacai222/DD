package groups

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestGroupCallLifecycleWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_GROUPS_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_GROUPS_TEST_DATABASE_URL is not set")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatalf("connect postgres: %v", err)
	}
	defer pool.Close()

	suffix := strings.ToLower(strings.ReplaceAll(uuid.New().String(), "-", ""))[:10]
	alice := insertGroupTestUser(t, ctx, pool, "ca"+suffix, "Call Alice")
	bob := insertGroupTestUser(t, ctx, pool, "cb"+suffix, "Call Bob")
	carol := insertGroupTestUser(t, ctx, pool, "cc"+suffix, "Call Carol")
	dave := insertGroupTestUser(t, ctx, pool, "cd"+suffix, "Call Dave")
	users := []uuid.UUID{alice, bob, carol, dave}
	for _, peer := range []uuid.UUID{bob, carol, dave} {
		insertGroupTestContactPair(t, ctx, pool, alice, peer)
	}
	principals := map[uuid.UUID]account.Principal{}
	for _, userID := range users {
		principals[userID] = account.Principal{
			UserID:   userID,
			DeviceID: insertGroupTestDevice(t, ctx, pool, userID),
		}
	}

	service, err := NewService(Config{
		Pool:                     pool,
		LiveKitURL:               "ws://127.0.0.1:7880",
		LiveKitAPIKey:            "group-call-test-key",
		LiveKitAPISecret:         "group-call-test-secret",
		GroupCallMaxParticipants: 3,
	})
	if err != nil {
		t.Fatalf("new groups service: %v", err)
	}
	group, err := service.Create(ctx, principals[alice], CreateGroupInput{
		Name: "群通话集成测试",
		MemberIDs: []string{
			bob.String(),
			carol.String(),
			dave.String(),
		},
	})
	if err != nil {
		t.Fatalf("create group: %v", err)
	}
	groupID := uuid.MustParse(group.ID)
	if _, err := pool.Exec(ctx, `UPDATE contacts SET remark='Call Alice Alias' WHERE owner_user_id=$1 AND contact_user_id=$2`, bob, alice); err != nil {
		t.Fatalf("set bob group-call remark: %v", err)
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM conversations WHERE id=$1`, groupID)
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM users WHERE id=ANY($1::uuid[])`, users)
	})

	started, _, err := service.StartGroupCall(ctx, principals[alice], groupID, "VIDEO")
	if err != nil {
		t.Fatalf("start group call: %v", err)
	}
	callID := uuid.MustParse(started.Call.ID)
	if started.Call.Kind != "VIDEO" || started.Call.MaxParticipants != 3 || len(started.Call.Participants) != 1 {
		t.Fatalf("unexpected started group call: %+v", started.Call)
	}
	if !strings.Contains(started.Token, ".") || started.LiveKitURL == "" {
		t.Fatalf("missing signed media credentials: %+v", started)
	}

	bobJoined, _, err := service.JoinGroupCall(ctx, principals[bob], groupID, callID)
	if err != nil {
		t.Fatalf("bob join group call: %v", err)
	}
	if bobJoined.Call.StartedBy.DisplayName != "Call Alice Alias" || bobJoined.Call.Participants[0].User.DisplayName != "Call Alice Alias" {
		t.Fatalf("bob viewer-relative group-call names=%+v", bobJoined.Call)
	}
	joined, _, err := service.JoinGroupCall(ctx, principals[carol], groupID, callID)
	if err != nil || len(joined.Call.Participants) != 3 {
		t.Fatalf("carol join participants=%d err=%v", len(joined.Call.Participants), err)
	}
	if _, _, err := service.JoinGroupCall(ctx, principals[dave], groupID, callID); !errors.Is(err, ErrGroupCallFull) {
		t.Fatalf("fourth participant err=%v want ErrGroupCallFull", err)
	}

	if err := service.RemoveMember(ctx, principals[alice], groupID, carol); err != nil {
		t.Fatalf("remove active call participant from group: %v", err)
	}
	if _, _, err := service.JoinGroupCall(ctx, principals[carol], groupID, callID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("removed member rejoin err=%v want ErrForbidden", err)
	}
	if _, _, err := service.JoinGroupCall(ctx, principals[dave], groupID, callID); err != nil {
		t.Fatalf("dave joins released slot: %v", err)
	}

	if _, _, err := service.LeaveGroupCall(ctx, principals[alice], groupID, callID); err != nil {
		t.Fatalf("alice leaves call: %v", err)
	}
	if _, _, err := service.LeaveGroupCall(ctx, principals[bob], groupID, callID); err != nil {
		t.Fatalf("bob leaves call: %v", err)
	}
	ended, _, err := service.LeaveGroupCall(ctx, principals[dave], groupID, callID)
	if err != nil {
		t.Fatalf("last participant leaves call: %v", err)
	}
	if ended.Status != "ENDED" || len(ended.Participants) != 0 {
		t.Fatalf("ended call=%+v", ended)
	}

	var status string
	var endedAt *time.Time
	if err := pool.QueryRow(ctx, `
		SELECT status,ended_at FROM group_call_sessions WHERE id=$1
	`, callID).Scan(&status, &endedAt); err != nil {
		t.Fatalf("load persisted group call: %v", err)
	}
	if status != "ENDED" || endedAt == nil {
		t.Fatalf("persisted status=%s endedAt=%v", status, endedAt)
	}

	var systemText string
	if err := pool.QueryRow(ctx, `
		SELECT content_json->>'text'
		FROM messages
		WHERE conversation_id=$1 AND client_message_id=$2 AND type='SYSTEM'
	`, groupID, "group-call-"+strings.ReplaceAll(callID.String(), "-", "")).Scan(&systemText); err != nil {
		t.Fatalf("load group call system message: %v", err)
	}
	if !strings.Contains(systemText, "群视频通话") || !strings.Contains(systemText, "4 人参与") {
		t.Fatalf("system message=%q", systemText)
	}
}
