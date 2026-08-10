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

func TestMentionEntitiesWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_MESSAGING_TEST_DATABASE_URL"))
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
	aliceHandle := "mxa" + suffix
	bobHandle := "mxb" + suffix
	newBobHandle := "mxc" + suffix
	alice, aliceDevice := insertMessagingTestUser(t, ctx, pool, aliceHandle, "Mention Alice")
	bob, _ := insertMessagingTestUser(t, ctx, pool, bobHandle, "Mention Bob")
	defer cleanupMessagingUsers(t, pool, []uuid.UUID{alice, bob})

	service, err := NewService(Config{Pool: pool})
	if err != nil {
		t.Fatal(err)
	}
	principal := account.Principal{UserID: alice, DeviceID: aliceDevice}
	conversation, err := service.EnsureDirectConversation(ctx, principal, bob)
	if err != nil {
		t.Fatalf("ensure direct conversation: %v", err)
	}
	conversationID := uuid.MustParse(conversation.ID)

	historical, err := service.SendMessage(ctx, principal, conversationID, SendMessageInput{
		ClientMessageID: "mention-historical-01",
		Type:            "TEXT",
		Content: &TextContent{
			Text: "hello @" + bobHandle + " @unknown_user",
			Entities: []MessageEntity{{
				Type:   "MENTION",
				Offset: 0,
				Length: 4,
				UserID: alice.String(),
				Handle: aliceHandle,
			}},
		},
	})
	if err != nil {
		t.Fatalf("send historical mention: %v", err)
	}
	assertSingleMentionEntity(t, historical.Message, bob, bobHandle)

	editable, err := service.SendMessage(ctx, principal, conversationID, SendMessageInput{
		ClientMessageID: "mention-editable-01",
		Type:            "TEXT",
		Content:         &TextContent{Text: "before @" + bobHandle},
	})
	if err != nil {
		t.Fatalf("send editable mention: %v", err)
	}
	assertSingleMentionEntity(t, editable.Message, bob, bobHandle)

	if _, err := pool.Exec(ctx, `UPDATE users SET handle_normalized=$2 WHERE id=$1`, bob, newBobHandle); err != nil {
		t.Fatalf("rename mentioned user: %v", err)
	}

	forwarded, err := service.ForwardMessage(ctx, principal, uuid.MustParse(historical.Message.ID), ForwardMessageInput{
		TargetConversationID: conversationID.String(),
		ClientMessageID:      "mention-forward-01",
	})
	if err != nil {
		t.Fatalf("forward historical mention: %v", err)
	}
	assertSingleMentionEntity(t, forwarded.Message, bob, bobHandle)
	if forwarded.Message.Content == nil || !strings.Contains(forwarded.Message.Content.Text, "@"+bobHandle) {
		t.Fatalf("forwarded historical text changed: %#v", forwarded.Message.Content)
	}

	edited, err := service.EditMessage(ctx, principal, uuid.MustParse(editable.Message.ID), EditMessageInput{
		Text:                "after @" + newBobHandle,
		ExpectedEditVersion: 0,
	})
	if err != nil {
		t.Fatalf("edit mention after handle change: %v", err)
	}
	assertSingleMentionEntity(t, edited.Message, bob, newBobHandle)
}

func assertSingleMentionEntity(t *testing.T, message Message, userID uuid.UUID, handle string) {
	t.Helper()
	if message.Content == nil {
		t.Fatalf("message has no content: %#v", message)
	}
	if len(message.Content.Entities) != 1 {
		t.Fatalf("entities=%#v", message.Content.Entities)
	}
	entity := message.Content.Entities[0]
	if entity.Type != "MENTION" || entity.UserID != userID.String() || entity.Handle != handle {
		t.Fatalf("entity=%#v want user=%s handle=%s", entity, userID, handle)
	}
	if entity.Offset < 0 || entity.Length != len(handle)+1 {
		t.Fatalf("entity offset/length=%#v", entity)
	}
}
