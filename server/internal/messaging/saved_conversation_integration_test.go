package messaging

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestSavedConversationWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_MESSAGING_TEST_DATABASE_URL"))
	if databaseURL == "" {
		databaseURL = strings.TrimSpace(os.Getenv("DD_CONTACTS_TEST_DATABASE_URL"))
	}
	if databaseURL == "" {
		t.Skip("DD_MESSAGING_TEST_DATABASE_URL is not set")
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
	ownerID, ownerDevice := insertMessagingTestUser(t, ctx, pool, "so"+suffix, "Owner")
	peerID, peerDevice := insertMessagingTestUser(t, ctx, pool, "sp"+suffix, "Peer")
	defer cleanupMessagingUsers(t, pool, []uuid.UUID{ownerID, peerID})

	now := time.Date(2026, 8, 9, 3, 0, 0, 0, time.UTC)
	service, err := NewService(Config{Pool: pool, Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	owner := account.Principal{UserID: ownerID, DeviceID: ownerDevice}
	peer := account.Principal{UserID: peerID, DeviceID: peerDevice}

	// Create a normal source message, then save it with the legacy bookmark API.
	sourceConversation, err := service.EnsureDirectConversation(ctx, owner, peerID)
	if err != nil {
		t.Fatalf("ensure source conversation: %v", err)
	}
	sourceID := uuid.MustParse(sourceConversation.ID)
	source, err := service.SendMessage(ctx, peer, sourceID, SendMessageInput{
		ClientMessageID: "saved-source-0001",
		Type:            "TEXT",
		Content:         &TextContent{Text: "keep this message"},
	})
	if err != nil {
		t.Fatalf("send source message: %v", err)
	}
	if _, err := service.SaveMessage(ctx, owner, uuid.MustParse(source.Message.ID)); err != nil {
		t.Fatalf("save legacy message: %v", err)
	}

	// Saved Messages is a real singleton SELF conversation.
	saved, err := service.EnsureSavedConversation(ctx, owner)
	if err != nil {
		t.Fatalf("ensure saved conversation: %v", err)
	}
	if saved.Type != "SELF" || saved.Peer == nil || saved.Peer.ID != ownerID.String() || !saved.CanWrite {
		t.Fatalf("saved conversation shape=%#v", saved)
	}
	savedAgain, err := service.EnsureSavedConversation(ctx, owner)
	if err != nil || savedAgain.ID != saved.ID {
		t.Fatalf("saved conversation must be singleton: first=%s second=%#v err=%v", saved.ID, savedAgain, err)
	}

	savedID := uuid.MustParse(saved.ID)
	history, err := service.ListMessages(ctx, owner, savedID, 0, 20)
	if err != nil {
		t.Fatalf("list migrated saved messages: %v", err)
	}
	if len(history.Items) != 1 || history.Items[0].ForwardedFromMessageID == nil || *history.Items[0].ForwardedFromMessageID != source.Message.ID {
		t.Fatalf("legacy saved message was not migrated once: %#v", history.Items)
	}

	// Opening the singleton again must not duplicate already migrated bookmarks.
	if _, err := service.EnsureSavedConversation(ctx, owner); err != nil {
		t.Fatalf("ensure saved conversation again: %v", err)
	}
	history, err = service.ListMessages(ctx, owner, savedID, 0, 20)
	if err != nil || len(history.Items) != 1 {
		t.Fatalf("legacy migration duplicated message: %#v err=%v", history.Items, err)
	}

	// The user can send notes directly to self; own sends are immediately read.
	now = now.Add(time.Second)
	note, err := service.SendMessage(ctx, owner, savedID, SendMessageInput{
		ClientMessageID: "saved-note-000001",
		Type:            "TEXT",
		Content:         &TextContent{Text: "private note"},
	})
	if err != nil {
		t.Fatalf("send self note: %v", err)
	}
	if note.Message.Sequence != 2 {
		t.Fatalf("self note sequence=%d want=2", note.Message.Sequence)
	}
	updated, err := service.GetConversation(ctx, owner, savedID)
	if err != nil {
		t.Fatalf("get saved conversation: %v", err)
	}
	if updated.UnreadCount != 0 || updated.LastReadSequence != updated.LastSequence {
		t.Fatalf("self note created unread state: %#v", updated)
	}

	var selfCount int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM conversations WHERE type='SELF' AND direct_pair_key=$1`, selfConversationPairKey(ownerID)).Scan(&selfCount); err != nil || selfCount != 1 {
		t.Fatalf("self conversation rows=%d err=%v", selfCount, err)
	}
}
