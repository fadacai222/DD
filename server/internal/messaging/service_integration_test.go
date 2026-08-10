package messaging

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

func TestMessagingLifecycleWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_MESSAGING_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_MESSAGING_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
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
	alice, aliceDevice := insertMessagingTestUser(t, ctx, pool, "ma"+suffix, "Alice")
	bob, bobDevice := insertMessagingTestUser(t, ctx, pool, "mb"+suffix, "Bob")
	eve, eveDevice := insertMessagingTestUser(t, ctx, pool, "me"+suffix, "Eve")
	userIDs := []uuid.UUID{alice, bob, eve}
	defer cleanupMessagingUsers(t, pool, userIDs)

	if _, err := pool.Exec(ctx, `
		INSERT INTO contacts(owner_user_id,contact_user_id) VALUES ($1,$2),($2,$1)
	`, alice, bob); err != nil {
		t.Fatalf("create contacts: %v", err)
	}

	now := time.Date(2026, 8, 8, 6, 0, 0, 0, time.UTC)
	service, err := NewService(Config{Pool: pool, Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	alicePrincipal := account.Principal{UserID: alice, DeviceID: aliceDevice}
	bobPrincipal := account.Principal{UserID: bob, DeviceID: bobDevice}
	evePrincipal := account.Principal{UserID: eve, DeviceID: eveDevice}

	// P4-002: concurrent direct-conversation creation must converge to one logical row.
	var wg sync.WaitGroup
	conversationIDs := make(chan string, 100)
	errorsCh := make(chan error, 100)
	for index := 0; index < 100; index++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			conversation, err := service.EnsureDirectConversation(ctx, alicePrincipal, bob)
			if err != nil {
				errorsCh <- err
				return
			}
			conversationIDs <- conversation.ID
		}()
	}
	wg.Wait()
	close(conversationIDs)
	close(errorsCh)
	for err := range errorsCh {
		if err != nil {
			t.Fatalf("concurrent conversation create: %v", err)
		}
	}
	var conversationID string
	for id := range conversationIDs {
		if conversationID == "" {
			conversationID = id
		}
		if id != conversationID {
			t.Fatalf("multiple direct conversations: %s vs %s", conversationID, id)
		}
	}
	conversationUUID := uuid.MustParse(conversationID)
	var conversationCount int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM conversations WHERE direct_pair_key=$1`, directPairKey(alice, bob)).Scan(&conversationCount); err != nil || conversationCount != 1 {
		t.Fatalf("direct conversation count=%d err=%v", conversationCount, err)
	}

	// P4-005: 100 retries with the same device/clientMessageId must all return one message.
	messageIDs := make(chan string, 100)
	errorsCh = make(chan error, 100)
	for index := 0; index < 100; index++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			result, err := service.SendMessage(ctx, alicePrincipal, conversationUUID, SendMessageInput{
				ClientMessageID: "retry-client-0001",
				Type:            "TEXT",
				Content:         &TextContent{Text: "hello bob"},
			})
			if err != nil {
				errorsCh <- err
				return
			}
			messageIDs <- result.Message.ID
		}()
	}
	wg.Wait()
	close(messageIDs)
	close(errorsCh)
	for err := range errorsCh {
		if err != nil {
			t.Fatalf("idempotent send: %v", err)
		}
	}
	var firstMessageID string
	for id := range messageIDs {
		if firstMessageID == "" {
			firstMessageID = id
		}
		if id != firstMessageID {
			t.Fatalf("duplicate logical message ids: %s vs %s", firstMessageID, id)
		}
	}
	var messageCount int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM messages WHERE sender_device_id=$1 AND client_message_id='retry-client-0001'`, aliceDevice).Scan(&messageCount); err != nil || messageCount != 1 {
		t.Fatalf("idempotent row count=%d err=%v", messageCount, err)
	}

	now = now.Add(time.Second)
	second, err := service.SendMessage(ctx, bobPrincipal, conversationUUID, SendMessageInput{
		ClientMessageID:  "bob-client-000002",
		Type:             "TEXT",
		Content:          &TextContent{Text: "reply"},
		ReplyToMessageID: stringPointer(firstMessageID),
	})
	if err != nil || second.Message.Sequence != 2 {
		t.Fatalf("second send=%#v err=%v", second, err)
	}

	// T10: text edits are owner-only, versioned and idempotent for repeated bodies.
	if _, err := service.EditMessage(ctx, bobPrincipal, uuid.MustParse(firstMessageID), EditMessageInput{Text: "hijacked", ExpectedEditVersion: 0}); !errors.Is(err, ErrEditForbidden) {
		t.Fatalf("other user edit error=%v", err)
	}
	now = now.Add(time.Second)
	edited, err := service.EditMessage(ctx, alicePrincipal, uuid.MustParse(firstMessageID), EditMessageInput{Text: "replacement body", ExpectedEditVersion: 0})
	if err != nil || edited.Message.Content == nil || edited.Message.Content.Text != "replacement body" || edited.Message.EditVersion != 1 || edited.Message.EditedAt == nil {
		t.Fatalf("edit result=%#v err=%v", edited, err)
	}
	idempotentEdit, err := service.EditMessage(ctx, alicePrincipal, uuid.MustParse(firstMessageID), EditMessageInput{Text: "replacement body", ExpectedEditVersion: 0})
	if err != nil || idempotentEdit.Message.EditVersion != 1 {
		t.Fatalf("idempotent edit=%#v err=%v", idempotentEdit, err)
	}
	if _, err := service.EditMessage(ctx, alicePrincipal, uuid.MustParse(firstMessageID), EditMessageInput{Text: "stale overwrite", ExpectedEditVersion: 0}); !errors.Is(err, ErrEditConflict) {
		t.Fatalf("stale edit error=%v", err)
	}
	oldHits, err := service.SearchMessages(ctx, alicePrincipal, "hello bob", &conversationUUID, 20)
	if err != nil {
		t.Fatalf("search old edited body: %v", err)
	}
	for _, hit := range oldHits {
		if hit.Message.ID == firstMessageID {
			t.Fatalf("old edited text still searchable: %#v", oldHits)
		}
	}
	newHits, err := service.SearchMessages(ctx, alicePrincipal, "replacement body", &conversationUUID, 20)
	if err != nil || len(newHits) != 1 || newHits[0].Message.ID != firstMessageID {
		t.Fatalf("search new edited body=%#v err=%v", newHits, err)
	}

	history, err := service.ListMessages(ctx, alicePrincipal, conversationUUID, 0, 1)
	if err != nil || len(history.Items) != 1 || history.Items[0].Sequence != 2 || !history.HasMore || history.NextBeforeSequence == nil {
		t.Fatalf("history page 1=%#v err=%v", history, err)
	}
	history2, err := service.ListMessages(ctx, alicePrincipal, conversationUUID, *history.NextBeforeSequence, 1)
	if err != nil || len(history2.Items) != 1 || history2.Items[0].Sequence != 1 {
		t.Fatalf("history page 2=%#v err=%v", history2, err)
	}

	read, _, err := service.MarkRead(ctx, alicePrincipal, conversationUUID, 2)
	if err != nil || read.LastReadSequence != 2 {
		t.Fatalf("mark read=%#v err=%v", read, err)
	}
	read, _, err = service.MarkRead(ctx, alicePrincipal, conversationUUID, 1)
	if err != nil || read.LastReadSequence != 2 {
		t.Fatalf("read sequence regressed=%#v err=%v", read, err)
	}
	bobConversation, err := service.GetConversation(ctx, bobPrincipal, conversationUUID)
	if err != nil || bobConversation.PeerLastReadSequence == nil || *bobConversation.PeerLastReadSequence != 2 {
		t.Fatalf("peer read receipt=%#v err=%v", bobConversation.PeerLastReadSequence, err)
	}
	if _, err := pool.Exec(ctx, `UPDATE user_privacy_settings SET read_receipts_enabled=false WHERE user_id=$1`, alice); err != nil {
		t.Fatalf("disable read receipts: %v", err)
	}
	bobConversation, err = service.GetConversation(ctx, bobPrincipal, conversationUUID)
	if err != nil || bobConversation.PeerLastReadSequence != nil {
		t.Fatalf("private peer read receipt should be hidden=%#v err=%v", bobConversation.PeerLastReadSequence, err)
	}
	if _, err := pool.Exec(ctx, `UPDATE user_privacy_settings SET read_receipts_enabled=true WHERE user_id=$1`, alice); err != nil {
		t.Fatalf("restore read receipts: %v", err)
	}
	if _, _, err := service.MarkRead(ctx, alicePrincipal, conversationUUID, 3); !errors.Is(err, ErrConflict) {
		t.Fatalf("read past last sequence error=%v", err)
	}

	processed, err := service.DispatchOutbox(ctx, 100)
	if err != nil || processed < 2 {
		t.Fatalf("dispatch processed=%d err=%v", processed, err)
	}
	aliceSync, err := service.Sync(ctx, alicePrincipal, 0, 100)
	if err != nil || len(aliceSync.Items) < 2 || aliceSync.NextCursor == 0 {
		t.Fatalf("alice sync=%#v err=%v", aliceSync, err)
	}
	bobSync, err := service.Sync(ctx, bobPrincipal, 0, 100)
	if err != nil || len(bobSync.Items) < 2 {
		t.Fatalf("bob sync=%#v err=%v", bobSync, err)
	}
	for label, page := range map[string]SyncPage{"alice": aliceSync, "bob": bobSync} {
		foundEdited := false
		for _, event := range page.Items {
			if event.Type != "MESSAGE_EDITED" {
				continue
			}
			foundEdited = event.ResourceID != nil && *event.ResourceID == firstMessageID && event.Sequence != nil && *event.Sequence == 1
			if foundEdited {
				break
			}
		}
		if !foundEdited {
			t.Fatalf("%s sync missing MESSAGE_EDITED for %s: %#v", label, firstMessageID, page.Items)
		}
	}
	repeatSync, err := service.Sync(ctx, alicePrincipal, aliceSync.NextCursor, 100)
	if err != nil || len(repeatSync.Items) != 0 || repeatSync.NextCursor != aliceSync.NextCursor {
		t.Fatalf("repeat sync=%#v err=%v", repeatSync, err)
	}

	// Local delete hides only the current user's conversation through the
	// current last_sequence. History stays readable, the peer is unaffected,
	// and either a new message or explicit reopen makes the conversation visible.
	hideConversation, err := service.EnsureDirectConversation(ctx, evePrincipal, alice)
	if err != nil {
		t.Fatalf("create hide test conversation: %v", err)
	}
	hideConversationID := uuid.MustParse(hideConversation.ID)
	if _, err := service.SendMessage(ctx, evePrincipal, hideConversationID, SendMessageInput{
		ClientMessageID: "hide-seq-1",
		Type:            "TEXT",
		Content:         &TextContent{Text: "first"},
	}); err != nil {
		t.Fatalf("send hide sequence 1: %v", err)
	}
	if err := service.HideConversation(ctx, alicePrincipal, hideConversationID); err != nil {
		t.Fatalf("hide conversation: %v", err)
	}
	aliceConversations, err := service.ListConversations(ctx, alicePrincipal, 100)
	if err != nil {
		t.Fatalf("list alice after hide: %v", err)
	}
	for _, item := range aliceConversations {
		if item.ID == hideConversation.ID {
			t.Fatalf("hidden conversation still visible to alice: %#v", item)
		}
	}
	if hiddenHistory, err := service.ListMessages(ctx, alicePrincipal, hideConversationID, 0, 10); err != nil || len(hiddenHistory.Items) != 1 {
		t.Fatalf("hidden history should remain readable=%#v err=%v", hiddenHistory, err)
	}
	eveConversations, err := service.ListConversations(ctx, evePrincipal, 100)
	if err != nil {
		t.Fatalf("list eve after alice hide: %v", err)
	}
	peerStillSees := false
	for _, item := range eveConversations {
		if item.ID == hideConversation.ID {
			peerStillSees = true
		}
	}
	if !peerStillSees {
		t.Fatal("alice local hide unexpectedly hid conversation from eve")
	}
	if _, err := service.SendMessage(ctx, evePrincipal, hideConversationID, SendMessageInput{
		ClientMessageID: "hide-seq-2",
		Type:            "TEXT",
		Content:         &TextContent{Text: "wake"},
	}); err != nil {
		t.Fatalf("send hide wake sequence: %v", err)
	}
	aliceConversations, err = service.ListConversations(ctx, alicePrincipal, 100)
	if err != nil {
		t.Fatalf("list alice after wake: %v", err)
	}
	woke := false
	for _, item := range aliceConversations {
		if item.ID == hideConversation.ID {
			woke = true
		}
	}
	if !woke {
		t.Fatal("new message did not wake hidden conversation")
	}
	if err := service.HideConversation(ctx, alicePrincipal, hideConversationID); err != nil {
		t.Fatalf("hide conversation second time: %v", err)
	}
	if _, err := service.EnsureDirectConversation(ctx, alicePrincipal, eve); err != nil {
		t.Fatalf("explicit reopen hidden conversation: %v", err)
	}
	var hiddenThrough *int64
	if err := pool.QueryRow(ctx, `SELECT hidden_through_sequence FROM conversation_members WHERE conversation_id=$1 AND user_id=$2`, hideConversationID, alice).Scan(&hiddenThrough); err != nil || hiddenThrough != nil {
		t.Fatalf("explicit reopen should clear hidden cursor hidden=%v err=%v", hiddenThrough, err)
	}

	// P3/P4 cross-module rule: block forbids new writes but keeps old history readable.
	if _, err := pool.Exec(ctx, `INSERT INTO blocks(owner_user_id,blocked_user_id) VALUES ($1,$2)`, bob, alice); err != nil {
		t.Fatalf("block pair: %v", err)
	}
	if _, err := service.SendMessage(ctx, alicePrincipal, conversationUUID, SendMessageInput{ClientMessageID: "blocked-client-01", Type: "TEXT", Content: &TextContent{Text: "blocked"}}); !errors.Is(err, ErrBlocked) {
		t.Fatalf("blocked send error=%v", err)
	}
	if oldHistory, err := service.ListMessages(ctx, alicePrincipal, conversationUUID, 0, 10); err != nil || len(oldHistory.Items) != 2 {
		t.Fatalf("history after block=%#v err=%v", oldHistory, err)
	}

	now = now.Add(10 * time.Second)
	recalled, err := service.RecallMessage(ctx, alicePrincipal, uuid.MustParse(firstMessageID))
	if err != nil || recalled.Message.RecalledAt == nil || recalled.Message.Content == nil || recalled.Message.Content.Text != "" {
		t.Fatalf("recall=%#v err=%v", recalled, err)
	}
	if err := service.DeleteMessageLocally(ctx, alicePrincipal, uuid.MustParse(second.Message.ID)); err != nil {
		t.Fatalf("local delete: %v", err)
	}
	aliceHistory, err := service.ListMessages(ctx, alicePrincipal, conversationUUID, 0, 10)
	if err != nil || len(aliceHistory.Items) != 1 {
		t.Fatalf("alice local history=%#v err=%v", aliceHistory, err)
	}
	bobHistory, err := service.ListMessages(ctx, bobPrincipal, conversationUUID, 0, 10)
	if err != nil || len(bobHistory.Items) != 2 {
		t.Fatalf("bob history should retain locally deleted message=%#v err=%v", bobHistory, err)
	}

	// Telegram-style direct messaging: knowing an active user's DDID is enough
	// to start and write a direct conversation. Contact approval and the legacy
	// allow_stranger_messages privacy bit must not gate chat delivery; blocking
	// remains the only relationship-level hard stop.
	strangerConversation, err := service.EnsureDirectConversation(ctx, evePrincipal, alice)
	if err != nil {
		t.Fatalf("open stranger conversation: %v", err)
	}
	if !strangerConversation.CanWrite {
		t.Fatalf("stranger conversation should be writable without approval: %#v", strangerConversation)
	}
	strangerConversationID := uuid.MustParse(strangerConversation.ID)
	oldMessage, err := service.SendMessage(ctx, evePrincipal, strangerConversationID, SendMessageInput{
		ClientMessageID: "eve-recall-window-01",
		Type:            "TEXT",
		Content:         &TextContent{Text: "this message will age out"},
	})
	if err != nil {
		t.Fatalf("send recall-window message: %v", err)
	}
	if _, err := service.RecallMessage(ctx, alicePrincipal, uuid.MustParse(oldMessage.Message.ID)); !errors.Is(err, ErrForbidden) {
		t.Fatalf("other user recall error=%v", err)
	}
	now = now.Add(24*time.Hour + time.Second)
	recalledOldMessage, err := service.RecallMessage(ctx, evePrincipal, uuid.MustParse(oldMessage.Message.ID))
	if err != nil {
		t.Fatalf("old own message should remain recallable: %v", err)
	}
	if recalledOldMessage.Message.RecalledAt == nil {
		t.Fatalf("old own message was not recalled")
	}
}

func insertMessagingTestUser(t *testing.T, ctx context.Context, pool *pgxpool.Pool, handle, displayName string) (uuid.UUID, uuid.UUID) {
	t.Helper()
	var userID uuid.UUID
	if err := pool.QueryRow(ctx, `
		INSERT INTO users(email_normalized,email_verified_at,handle_normalized,display_name,status)
		VALUES ($1,now(),$2,$3,'ACTIVE') RETURNING id
	`, handle+"@messaging.example.test", handle, displayName).Scan(&userID); err != nil {
		t.Fatalf("insert user %s: %v", handle, err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO user_privacy_settings(user_id) VALUES ($1)`, userID); err != nil {
		t.Fatalf("insert privacy %s: %v", handle, err)
	}
	var deviceID uuid.UUID
	if err := pool.QueryRow(ctx, `
		INSERT INTO devices(user_id,name,platform,app_version)
		VALUES ($1,$2,'WINDOWS','test') RETURNING id
	`, userID, displayName+" Device").Scan(&deviceID); err != nil {
		t.Fatalf("insert device %s: %v", handle, err)
	}
	return userID, deviceID
}

func cleanupMessagingUsers(t *testing.T, pool *pgxpool.Pool, userIDs []uuid.UUID) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	rows, err := pool.Query(ctx, `
		SELECT DISTINCT conversation_id FROM conversation_members WHERE user_id=ANY($1::uuid[])
	`, userIDs)
	if err == nil {
		var conversationIDs []uuid.UUID
		for rows.Next() {
			var id uuid.UUID
			if rows.Scan(&id) == nil {
				conversationIDs = append(conversationIDs, id)
			}
		}
		rows.Close()
		if len(conversationIDs) > 0 {
			_, _ = pool.Exec(ctx, `DELETE FROM conversations WHERE id=ANY($1::uuid[])`, conversationIDs)
		}
	}
	_, _ = pool.Exec(ctx, `DELETE FROM users WHERE id=ANY($1::uuid[])`, userIDs)
}
