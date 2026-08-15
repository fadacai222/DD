package contacts

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestRelationshipLifecycleWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_CONTACTS_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_CONTACTS_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("ping postgres: %v", err)
	}

	suffix := fmt.Sprintf("%x", time.Now().UnixNano())
	if len(suffix) > 10 {
		suffix = suffix[len(suffix)-10:]
	}
	alice := insertRelationshipTestUser(t, ctx, pool, "a"+suffix, "Alice")
	bob := insertRelationshipTestUser(t, ctx, pool, "b"+suffix, "Bob")
	carol := insertRelationshipTestUser(t, ctx, pool, "c"+suffix, "Carol")
	dave := insertRelationshipTestUser(t, ctx, pool, "d"+suffix, "Dave")
	userIDs := []uuid.UUID{alice, bob, carol, dave}
	defer func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		for _, left := range userIDs {
			for _, right := range userIDs {
				if left == right {
					continue
				}
				_, _ = pool.Exec(cleanupCtx, `DELETE FROM conversations WHERE direct_pair_key=$1`, directPairKey(left, right))
			}
		}
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM outbox_events WHERE aggregate_id = ANY($1::uuid[]) OR target_user_id = ANY($1::uuid[])`, userIDs)
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM users WHERE id = ANY($1::uuid[])`, userIDs)
	}()

	now := time.Date(2026, 8, 8, 3, 0, 0, 0, time.UTC)
	service, err := NewService(Config{Pool: pool, Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	alicePrincipal := account.Principal{UserID: alice, DeviceID: insertRelationshipTestDevice(t, ctx, pool, alice, "Alice device")}
	bobPrincipal := account.Principal{UserID: bob, DeviceID: insertRelationshipTestDevice(t, ctx, pool, bob, "Bob device")}
	carolPrincipal := account.Principal{UserID: carol, DeviceID: insertRelationshipTestDevice(t, ctx, pool, carol, "Carol device")}
	davePrincipal := account.Principal{UserID: dave, DeviceID: insertRelationshipTestDevice(t, ctx, pool, dave, "Dave device")}
	bobHandle := relationshipTestHandle(t, ctx, pool, bob)
	aliceHandle := relationshipTestHandle(t, ctx, pool, alice)
	carolHandle := relationshipTestHandle(t, ctx, pool, carol)

	search, err := service.SearchByHandle(ctx, alicePrincipal, bobHandle)
	if err != nil || search.Relationship != "NONE" || search.User.ID != bob.String() {
		t.Fatalf("initial search=%#v err=%v", search, err)
	}

	// Telegram-style contacts are unilateral address-book entries. Adding
	// someone must not require their approval or create a reciprocal contact.
	added, err := service.AddContact(ctx, davePrincipal, carol)
	if err != nil || added.User.ID != carol.String() {
		t.Fatalf("add unilateral contact=%#v err=%v", added, err)
	}
	assertRelationshipCount(t, ctx, pool, `SELECT count(*) FROM contacts WHERE owner_user_id=$1 AND contact_user_id=$2`, dave, carol, 1)
	assertRelationshipCount(t, ctx, pool, `SELECT count(*) FROM contacts WHERE owner_user_id=$1 AND contact_user_id=$2`, carol, dave, 0)
	if err := service.DeleteContact(ctx, davePrincipal, carol); err != nil {
		t.Fatalf("delete unilateral contact: %v", err)
	}
	if err := service.DeleteContact(ctx, davePrincipal, carol); err != nil {
		t.Fatalf("idempotent repeated delete: %v", err)
	}

	outgoing, err := service.SendRequest(ctx, alicePrincipal, SendRequestInput{TargetHandle: bobHandle, Message: "  hello Bob  "})
	if err != nil || outgoing.Status != "PENDING" || outgoing.Message != "hello Bob" {
		t.Fatalf("send request=%#v err=%v", outgoing, err)
	}
	repeated, err := service.SendRequest(ctx, alicePrincipal, SendRequestInput{TargetHandle: bobHandle, Message: "ignored retry body"})
	if err != nil || repeated.ID != outgoing.ID {
		t.Fatalf("idempotent request=%#v err=%v", repeated, err)
	}

	mutual, err := service.SendRequest(ctx, bobPrincipal, SendRequestInput{TargetHandle: aliceHandle, Message: "mutual"})
	if err != nil || mutual.Status != "ACCEPTED" || mutual.ConversationID == nil || *mutual.ConversationID == "" {
		t.Fatalf("mutual accept=%#v err=%v", mutual, err)
	}
	assertRelationshipCount(t, ctx, pool, `SELECT count(*) FROM contacts WHERE (owner_user_id=$1 AND contact_user_id=$2) OR (owner_user_id=$2 AND contact_user_id=$1)`, alice, bob, 2)
	conversationID := uuid.MustParse(*mutual.ConversationID)
	assertRelationshipCount(t, ctx, pool, `SELECT count(*) FROM conversation_members WHERE conversation_id=$1`, conversationID, uuid.Nil, 2)
	var systemType, systemText string
	var systemSender uuid.UUID
	if err := pool.QueryRow(ctx, `
		SELECT type,content_json->>'text',sender_user_id
		FROM messages WHERE conversation_id=$1 ORDER BY sequence DESC LIMIT 1
	`, conversationID).Scan(&systemType, &systemText, &systemSender); err != nil {
		t.Fatalf("load friend accepted system message: %v", err)
	}
	if systemType != "SYSTEM" || systemText != "我刚刚同意了你的好友请求" || systemSender != bob {
		t.Fatalf("friend accepted system message type=%q text=%q sender=%s", systemType, systemText, systemSender)
	}

	remark := "工作伙伴"
	starred := true
	tags := []string{"Work", "work", "海外"}
	updated, err := service.UpdateContact(ctx, alicePrincipal, bob, UpdateContactInput{Remark: &remark, IsStarred: &starred, Tags: &tags})
	if err != nil || updated.Remark != remark || !updated.IsStarred || len(updated.Tags) != 2 {
		t.Fatalf("update contact=%#v err=%v", updated, err)
	}
	aliceSearch, err := service.GetUserByID(ctx, alicePrincipal, bob)
	if err != nil || aliceSearch.EffectiveDisplayName != remark {
		t.Fatalf("alice viewer display name=%q err=%v", aliceSearch.EffectiveDisplayName, err)
	}
	bobSearch, err := service.GetUserByID(ctx, bobPrincipal, alice)
	if err != nil || bobSearch.EffectiveDisplayName != "Alice" {
		t.Fatalf("bob must not see alice private remark display=%q err=%v", bobSearch.EffectiveDisplayName, err)
	}
	carolSearch, err := service.GetUserByID(ctx, carolPrincipal, bob)
	if err != nil || carolSearch.EffectiveDisplayName != "Bob" {
		t.Fatalf("carol without remark display=%q err=%v", carolSearch.EffectiveDisplayName, err)
	}
	bobContacts, err := service.ListContacts(ctx, bobPrincipal, 1, 50)
	if err != nil || len(bobContacts.Items) != 1 || bobContacts.Items[0].Remark != "" || bobContacts.Items[0].IsStarred {
		t.Fatalf("owner-specific metadata leaked: %#v err=%v", bobContacts, err)
	}

	blocked, err := service.BlockUser(ctx, bobPrincipal, alice)
	if err != nil || blocked.User.ID != alice.String() {
		t.Fatalf("block user=%#v err=%v", blocked, err)
	}
	var blockEventType string
	var blockTarget uuid.UUID
	var blockPayload string
	if err := pool.QueryRow(ctx, `
		SELECT event_type,target_user_id,payload_json::text
		FROM outbox_events
		WHERE event_type='RELATIONSHIP_BLOCKED_BY_PEER' AND aggregate_id=$1 AND target_user_id=$2
		ORDER BY created_at DESC LIMIT 1
	`, bob, alice).Scan(&blockEventType, &blockTarget, &blockPayload); err != nil {
		t.Fatalf("load targeted block event: %v", err)
	}
	if blockEventType != "RELATIONSHIP_BLOCKED_BY_PEER" || blockTarget != alice || !strings.Contains(blockPayload, bob.String()) {
		t.Fatalf("unexpected targeted block event type=%s target=%s payload=%s", blockEventType, blockTarget, blockPayload)
	}
	assertRelationshipCount(t, ctx, pool, `SELECT count(*) FROM contacts WHERE (owner_user_id=$1 AND contact_user_id=$2) OR (owner_user_id=$2 AND contact_user_id=$1)`, alice, bob, 0)
	if _, err := service.SearchByHandle(ctx, alicePrincipal, bobHandle); !errors.Is(err, ErrNotFound) {
		t.Fatalf("blocked-by-peer search must preserve block privacy with ErrNotFound, err=%v", err)
	}
	if _, err := service.SearchByHandle(ctx, bobPrincipal, aliceHandle); !errors.Is(err, ErrNotFound) {
		t.Fatalf("blocked-by-me search must preserve block privacy with ErrNotFound, err=%v", err)
	}
	if _, err := service.SendRequest(ctx, alicePrincipal, SendRequestInput{TargetHandle: bobHandle}); !errors.Is(err, ErrBlocked) {
		t.Fatalf("blocked request should fail explicitly, error=%v", err)
	}
	// Deleting a contact is intentionally idempotent. A peer-side delete/block
	// can make a still-rendered contact stale before this device refreshes.
	if err := service.DeleteContact(ctx, alicePrincipal, bob); err != nil {
		t.Fatalf("idempotent delete after peer block: %v", err)
	}
	if err := service.UnblockUser(ctx, bobPrincipal, alice); err != nil {
		t.Fatalf("unblock: %v", err)
	}

	pending, err := service.SendRequest(ctx, alicePrincipal, SendRequestInput{TargetHandle: bobHandle})
	if err != nil {
		t.Fatalf("send post-unblock request: %v", err)
	}
	pendingID := uuid.MustParse(pending.ID)
	if _, err := service.RejectRequest(ctx, carolPrincipal, pendingID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("IDOR reject error=%v", err)
	}
	rejected, err := service.RejectRequest(ctx, bobPrincipal, pendingID)
	if err != nil || rejected.Status != "REJECTED" {
		t.Fatalf("reject request=%#v err=%v", rejected, err)
	}

	var wg sync.WaitGroup
	wg.Add(2)
	results := make(chan ContactRequest, 2)
	errorsCh := make(chan error, 2)
	go func() {
		defer wg.Done()
		result, err := service.SendRequest(ctx, alicePrincipal, SendRequestInput{TargetHandle: carolHandle})
		results <- result
		errorsCh <- err
	}()
	go func() {
		defer wg.Done()
		result, err := service.SendRequest(ctx, carolPrincipal, SendRequestInput{TargetHandle: aliceHandle})
		results <- result
		errorsCh <- err
	}()
	wg.Wait()
	close(results)
	close(errorsCh)
	for err := range errorsCh {
		if err != nil {
			t.Fatalf("concurrent opposite request: %v", err)
		}
	}
	acceptedCount := 0
	for result := range results {
		if result.Status == "ACCEPTED" {
			acceptedCount++
		}
	}
	if acceptedCount < 1 {
		t.Fatalf("concurrent opposite requests never reached ACCEPTED")
	}
	assertRelationshipCount(t, ctx, pool, `SELECT count(*) FROM contacts WHERE (owner_user_id=$1 AND contact_user_id=$2) OR (owner_user_id=$2 AND contact_user_id=$1)`, alice, carol, 2)

	for index := 0; index < handleSearchLimit; index++ {
		if _, err := service.SearchByHandle(ctx, davePrincipal, relationshipTestHandle(t, ctx, pool, dave)); err != nil {
			t.Fatalf("search %d before limit: %v", index, err)
		}
	}
	if _, err := service.SearchByHandle(ctx, davePrincipal, relationshipTestHandle(t, ctx, pool, dave)); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("search rate limit error=%v", err)
	}
}

func insertRelationshipTestUser(t *testing.T, ctx context.Context, pool *pgxpool.Pool, handle, displayName string) uuid.UUID {
	t.Helper()
	var id uuid.UUID
	email := handle + "@contacts.example.test"
	if err := pool.QueryRow(ctx, `
		INSERT INTO users (email_normalized,email_verified_at,handle_normalized,display_name,status)
		VALUES ($1,now(),$2,$3,'ACTIVE') RETURNING id
	`, email, handle, displayName).Scan(&id); err != nil {
		t.Fatalf("insert user %s: %v", handle, err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO user_privacy_settings (user_id) VALUES ($1)`, id); err != nil {
		t.Fatalf("insert privacy %s: %v", handle, err)
	}
	return id
}

func insertRelationshipTestDevice(t *testing.T, ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID, name string) uuid.UUID {
	t.Helper()
	var id uuid.UUID
	if err := pool.QueryRow(ctx, `
		INSERT INTO devices(user_id,name,platform,app_version,is_verified)
		VALUES($1,$2,'WINDOWS','test',true) RETURNING id
	`, userID, name).Scan(&id); err != nil {
		t.Fatalf("insert test device: %v", err)
	}
	return id
}

func relationshipTestHandle(t *testing.T, ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID) string {
	t.Helper()
	var handle string
	if err := pool.QueryRow(ctx, `SELECT handle_normalized FROM users WHERE id=$1`, userID).Scan(&handle); err != nil {
		t.Fatalf("load test handle: %v", err)
	}
	return handle
}

func assertRelationshipCount(t *testing.T, ctx context.Context, pool *pgxpool.Pool, query string, a, b uuid.UUID, want int) {
	t.Helper()
	var count int
	var err error
	if b == uuid.Nil {
		err = pool.QueryRow(ctx, query, a).Scan(&count)
	} else {
		err = pool.QueryRow(ctx, query, a, b).Scan(&count)
	}
	if err != nil || count != want {
		t.Fatalf("relationship count=%d want=%d err=%v query=%s", count, want, err, query)
	}
}
