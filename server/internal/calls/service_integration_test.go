package calls

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestCallLifecycleWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_CALLS_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_CALLS_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatalf("connect postgres: %v", err)
	}
	defer pool.Close()

	suffix := strings.ToLower(strings.ReplaceAll(uuid.New().String(), "-", ""))[:10]
	alice := insertCallTestUser(t, ctx, pool, "ca"+suffix, "Call Alice")
	bob := insertCallTestUser(t, ctx, pool, "cb"+suffix, "Call Bob")
	carol := insertCallTestUser(t, ctx, pool, "cc"+suffix, "Call Carol")
	users := []uuid.UUID{alice, bob, carol}
	insertCallTestContactPair(t, ctx, pool, alice, bob)
	insertCallTestContactPair(t, ctx, pool, bob, carol)
	aliceBobConversation := insertCallTestDirectConversation(t, ctx, pool, alice, bob, "call-ab-"+suffix)
	insertCallTestDirectConversation(t, ctx, pool, bob, carol, "call-bc-"+suffix)
	aliceDevice1 := insertCallTestDevice(t, ctx, pool, alice, "alice-1")
	aliceDevice2 := insertCallTestDevice(t, ctx, pool, alice, "alice-2")
	bobDevice1 := insertCallTestDevice(t, ctx, pool, bob, "bob-1")
	bobDevice2 := insertCallTestDevice(t, ctx, pool, bob, "bob-2")
	carolDevice := insertCallTestDevice(t, ctx, pool, carol, "carol-1")
	principals := map[string]account.Principal{
		"alice1": {UserID: alice, DeviceID: aliceDevice1},
		"alice2": {UserID: alice, DeviceID: aliceDevice2},
		"bob1":   {UserID: bob, DeviceID: bobDevice1},
		"bob2":   {UserID: bob, DeviceID: bobDevice2},
		"carol":  {UserID: carol, DeviceID: carolDevice},
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM calls WHERE caller_user_id=ANY($1::uuid[]) OR callee_user_id=ANY($1::uuid[])`, users)
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM users WHERE id=ANY($1::uuid[])`, users)
	})

	current := time.Date(2026, 8, 10, 12, 0, 0, 0, time.UTC)
	service, err := NewService(Config{
		Pool:        pool,
		RingTimeout: 30 * time.Second,
		Now:         func() time.Time { return current },
	})
	if err != nil {
		t.Fatalf("new calls service: %v", err)
	}

	created, err := service.Create(ctx, principals["alice1"], CreateInput{
		CalleeUserID: bob.String(),
		Kind:         KindVideo,
	})
	if err != nil {
		t.Fatalf("create call: %v", err)
	}
	if created.Status != StatusRinging || created.Kind != KindVideo || created.CallerIdentity != alice.String() || created.CalleeIdentity != bob.String() {
		t.Fatalf("unexpected created call: %+v", created)
	}
	callID := uuid.MustParse(created.ID)

	if active, err := service.GetActive(ctx, principals["alice1"]); err != nil || active == nil || active.ID != created.ID {
		t.Fatalf("caller origin active=%+v err=%v", active, err)
	}
	if active, err := service.GetActive(ctx, principals["alice2"]); err != nil || active != nil {
		t.Fatalf("caller other device active=%+v err=%v want nil", active, err)
	}
	for _, key := range []string{"bob1", "bob2"} {
		if active, err := service.GetActive(ctx, principals[key]); err != nil || active == nil || active.ID != created.ID {
			t.Fatalf("ringing callee device %s active=%+v err=%v", key, active, err)
		}
	}

	if _, err := service.Create(ctx, principals["carol"], CreateInput{CalleeUserID: bob.String(), Kind: KindAudio}); !errors.Is(err, ErrBusy) {
		t.Fatalf("busy callee create err=%v want ErrBusy", err)
	}
	if _, err := service.Create(ctx, principals["carol"], CreateInput{CalleeUserID: alice.String(), Kind: KindAudio}); !errors.Is(err, ErrContactRequired) {
		t.Fatalf("non-contact create err=%v want ErrContactRequired", err)
	}

	accepted, err := service.ApplyAction(ctx, principals["bob1"], callID, ActionInput{Action: "accept"})
	if err != nil {
		t.Fatalf("accept call: %v", err)
	}
	if accepted.Status != StatusAccepted || accepted.AcceptedAt == nil {
		t.Fatalf("unexpected accepted call: %+v", accepted)
	}
	if active, err := service.GetActive(ctx, principals["bob2"]); err != nil || active != nil {
		t.Fatalf("losing callee device active=%+v err=%v want nil", active, err)
	}
	if _, err := service.ApplyAction(ctx, principals["bob2"], callID, ActionInput{Action: "hangup"}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("losing callee device hangup err=%v want forbidden", err)
	}
	if _, err := service.AuthorizeToken(ctx, principals["alice1"], callID); err != nil {
		t.Fatalf("caller origin token authorization: %v", err)
	}
	if _, err := service.AuthorizeToken(ctx, principals["bob1"], callID); err != nil {
		t.Fatalf("accepted callee token authorization: %v", err)
	}
	if _, err := service.AuthorizeToken(ctx, principals["alice2"], callID); !errors.Is(err, ErrConflict) {
		t.Fatalf("caller other device token err=%v want conflict", err)
	}
	if _, err := service.AuthorizeToken(ctx, principals["bob2"], callID); !errors.Is(err, ErrConflict) {
		t.Fatalf("callee other device token err=%v want conflict", err)
	}

	current = current.Add(4*time.Minute + 12*time.Second)
	ended, err := service.ApplyAction(ctx, principals["bob1"], callID, ActionInput{Action: "hangup"})
	if err != nil {
		t.Fatalf("hangup accepted call: %v", err)
	}
	if ended.Status != StatusEnded || ended.EndReason != "hung_up" || ended.EndedAt == nil {
		t.Fatalf("unexpected ended call: %+v", ended)
	}
	assertCallSystemMessage(t, ctx, pool, aliceBobConversation, created.ID, "[视频通话] 通话时长 04:12")
	for _, key := range []string{"alice1", "bob1"} {
		if active, err := service.GetActive(ctx, principals[key]); err != nil || active != nil {
			t.Fatalf("post-hangup active %s=%+v err=%v", key, active, err)
		}
	}

	current = current.Add(time.Minute)
	rejectedCall, err := service.Create(ctx, principals["alice1"], CreateInput{CalleeUserID: bob.String(), Kind: KindAudio})
	if err != nil {
		t.Fatalf("create reject call: %v", err)
	}
	rejected, err := service.ApplyAction(ctx, principals["bob2"], uuid.MustParse(rejectedCall.ID), ActionInput{Action: "reject"})
	if err != nil || rejected.Status != StatusRejected || rejected.EndReason != "rejected" {
		t.Fatalf("reject result=%+v err=%v", rejected, err)
	}
	assertCallSystemMessage(t, ctx, pool, aliceBobConversation, rejectedCall.ID, "[语音通话] 已拒绝")

	current = current.Add(time.Minute)
	cancelledCall, err := service.Create(ctx, principals["alice1"], CreateInput{CalleeUserID: bob.String(), Kind: KindAudio})
	if err != nil {
		t.Fatalf("create cancel call: %v", err)
	}
	cancelled, err := service.ApplyAction(ctx, principals["alice1"], uuid.MustParse(cancelledCall.ID), ActionInput{Action: "hangup"})
	if err != nil || cancelled.Status != StatusEnded || cancelled.EndReason != "cancelled" {
		t.Fatalf("cancel result=%+v err=%v", cancelled, err)
	}
	assertCallSystemMessage(t, ctx, pool, aliceBobConversation, cancelledCall.ID, "[语音通话] 已取消")

	current = current.Add(time.Minute)
	timeoutCall, err := service.Create(ctx, principals["alice1"], CreateInput{CalleeUserID: bob.String(), Kind: KindAudio})
	if err != nil {
		t.Fatalf("create timeout call: %v", err)
	}
	current = current.Add(31 * time.Second)
	timedOut, changed, err := service.Timeout(ctx, uuid.MustParse(timeoutCall.ID))
	if err != nil || !changed || timedOut.Status != StatusEnded || timedOut.EndReason != "timeout" {
		t.Fatalf("timeout result=%+v changed=%v err=%v", timedOut, changed, err)
	}
	assertCallSystemMessage(t, ctx, pool, aliceBobConversation, timeoutCall.ID, "[语音通话] 对方无应答")

	if _, err := pool.Exec(ctx, `INSERT INTO blocks(owner_user_id,blocked_user_id) VALUES($1,$2) ON CONFLICT DO NOTHING`, alice, bob); err != nil {
		t.Fatalf("insert block: %v", err)
	}
	current = current.Add(time.Minute)
	if _, err := service.Create(ctx, principals["alice1"], CreateInput{CalleeUserID: bob.String(), Kind: KindAudio}); !errors.Is(err, ErrBlocked) {
		t.Fatalf("blocked create err=%v want ErrBlocked", err)
	}
}

func insertCallTestUser(t *testing.T, ctx context.Context, pool *pgxpool.Pool, handle, displayName string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := pool.Exec(ctx, `
		INSERT INTO users(id,email_normalized,email_verified_at,handle_normalized,display_name,status,created_at,updated_at)
		VALUES($1,$2,now(),$3,$4,'ACTIVE',now(),now())
	`, id, fmt.Sprintf("%s@example.invalid", handle), handle, displayName); err != nil {
		t.Fatalf("insert call test user %s: %v", handle, err)
	}
	return id
}

func insertCallTestDevice(t *testing.T, ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID, name string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := pool.Exec(ctx, `
		INSERT INTO devices(id,user_id,name,platform,created_at,last_seen_at)
		VALUES($1,$2,$3,'WINDOWS',now(),now())
	`, id, userID, name); err != nil {
		t.Fatalf("insert call test device: %v", err)
	}
	return id
}

func insertCallTestDirectConversation(t *testing.T, ctx context.Context, pool *pgxpool.Pool, a, b uuid.UUID, pairKey string) uuid.UUID {
	t.Helper()
	conversationID := uuid.New()
	if _, err := pool.Exec(ctx, `
		INSERT INTO conversations(id,type,direct_pair_key,last_sequence,created_at,updated_at)
		VALUES($1,'DIRECT',$2,0,now(),now())
	`, conversationID, pairKey); err != nil {
		t.Fatalf("insert call test conversation: %v", err)
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO conversation_members(conversation_id,user_id,role,status,joined_at,last_read_sequence,is_pinned)
		VALUES($1,$2,'MEMBER','ACTIVE',now(),0,false),($1,$3,'MEMBER','ACTIVE',now(),0,false)
	`, conversationID, a, b); err != nil {
		t.Fatalf("insert call test conversation members: %v", err)
	}
	return conversationID
}

func assertCallSystemMessage(t *testing.T, ctx context.Context, pool *pgxpool.Pool, conversationID uuid.UUID, callID, wantText string) {
	t.Helper()
	clientMessageID := "call-" + strings.ReplaceAll(callID, "-", "")
	var text string
	var count int
	if err := pool.QueryRow(ctx, `
		SELECT count(*),COALESCE(max(content_json->>'text'),'')
		FROM messages
		WHERE conversation_id=$1 AND client_message_id=$2 AND type='SYSTEM'
	`, conversationID, clientMessageID).Scan(&count, &text); err != nil {
		t.Fatalf("load call system message: %v", err)
	}
	if count != 1 || text != wantText {
		t.Fatalf("call system message count=%d text=%q want 1/%q", count, text, wantText)
	}
}

func insertCallTestContactPair(t *testing.T, ctx context.Context, pool *pgxpool.Pool, a, b uuid.UUID) {
	t.Helper()
	if _, err := pool.Exec(ctx, `
		INSERT INTO contacts(owner_user_id,contact_user_id,remark,is_starred,created_at,updated_at)
		VALUES($1,$2,'',false,now(),now()),($2,$1,'',false,now(),now())
		ON CONFLICT(owner_user_id,contact_user_id) DO NOTHING
	`, a, b); err != nil {
		t.Fatalf("insert call test contact pair: %v", err)
	}
}
