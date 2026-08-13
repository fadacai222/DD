package messaging

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

func TestDurableUnreadMentionsWithPostgres(t *testing.T) {
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
	if len(suffix) > 8 {
		suffix = suffix[len(suffix)-8:]
	}
	alice, aliceDevice := insertMessagingTestUser(t, ctx, pool, "dma"+suffix, "Durable Alice")
	bob, bobDevice := insertMessagingTestUser(t, ctx, pool, "dmb"+suffix, "Durable Bob")
	carol, carolDevice := insertMessagingTestUser(t, ctx, pool, "dmc"+suffix, "Durable Carol")
	defer cleanupMessagingUsers(t, pool, []uuid.UUID{alice, bob, carol})

	groupID := insertDurableMentionGroup(t, ctx, pool, alice, []durableMentionMember{
		{alice, "OWNER"},
		{bob, "MEMBER"},
		{carol, "MEMBER"},
	})
	now := time.Date(2026, 8, 14, 6, 0, 0, 0, time.UTC)
	service, err := NewService(Config{Pool: pool, Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	alicePrincipal := account.Principal{UserID: alice, DeviceID: aliceDevice}
	bobPrincipal := account.Principal{UserID: bob, DeviceID: bobDevice}
	carolPrincipal := account.Principal{UserID: carol, DeviceID: carolDevice}
	bobHandle := durableMentionHandle(t, ctx, pool, bob)

	mention, err := service.SendMessage(ctx, alicePrincipal, groupID, SendMessageInput{
		ClientMessageID: "durable-mention-0001",
		Type:            "TEXT",
		Content:         &TextContent{Text: "@" + bobHandle + " 请看这里"},
	})
	if err != nil {
		t.Fatalf("send direct mention: %v", err)
	}
	assertDurableMention(t, ctx, service, bobPrincipal, groupID, mention.Message.ID, mention.Message.Sequence)
	assertNoDurableMention(t, ctx, service, carolPrincipal, groupID)

	plain, err := service.SendMessage(ctx, alicePrincipal, groupID, SendMessageInput{
		ClientMessageID: "durable-plain-00001",
		Type:            "TEXT",
		Content:         &TextContent{Text: "后续普通消息"},
	})
	if err != nil {
		t.Fatalf("send plain message: %v", err)
	}
	if plain.Message.Sequence <= mention.Message.Sequence {
		t.Fatalf("plain sequence=%d mention=%d", plain.Message.Sequence, mention.Message.Sequence)
	}
	assertDurableMention(t, ctx, service, bobPrincipal, groupID, mention.Message.ID, mention.Message.Sequence)

	reconnected, err := NewService(Config{Pool: pool, Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	items, err := reconnected.ListConversations(ctx, bobPrincipal, 100)
	if err != nil {
		t.Fatalf("list after reconnect: %v", err)
	}
	listed := durableMentionConversation(t, items, groupID.String())
	if listed.LatestUnreadMentionMessageID == nil || *listed.LatestUnreadMentionMessageID != mention.Message.ID ||
		listed.LatestUnreadMentionSequence == nil || *listed.LatestUnreadMentionSequence != mention.Message.Sequence {
		t.Fatalf("reconnected target=%#v sequence=%#v", listed.LatestUnreadMentionMessageID, listed.LatestUnreadMentionSequence)
	}

	if err := service.DeleteMessageLocally(ctx, bobPrincipal, uuid.MustParse(mention.Message.ID)); err != nil {
		t.Fatalf("delete mention locally: %v", err)
	}
	assertNoDurableMention(t, ctx, service, bobPrincipal, groupID)

	readMention, err := service.SendMessage(ctx, alicePrincipal, groupID, SendMessageInput{
		ClientMessageID: "durable-read-000001",
		Type:            "TEXT",
		Content:         &TextContent{Text: "@" + bobHandle + " 读游标测试"},
	})
	if err != nil {
		t.Fatalf("send read mention: %v", err)
	}
	assertDurableMention(t, ctx, service, bobPrincipal, groupID, readMention.Message.ID, readMention.Message.Sequence)
	if _, _, err := service.MarkRead(ctx, bobPrincipal, groupID, readMention.Message.Sequence); err != nil {
		t.Fatalf("mark mention read: %v", err)
	}
	assertNoDurableMention(t, ctx, service, bobPrincipal, groupID)

	recalled, err := service.SendMessage(ctx, alicePrincipal, groupID, SendMessageInput{
		ClientMessageID: "durable-recall-0001",
		Type:            "TEXT",
		Content:         &TextContent{Text: "@" + bobHandle + " 即将撤回"},
	})
	if err != nil {
		t.Fatalf("send recalled mention: %v", err)
	}
	assertDurableMention(t, ctx, service, bobPrincipal, groupID, recalled.Message.ID, recalled.Message.Sequence)
	if _, err := service.RecallMessage(ctx, alicePrincipal, uuid.MustParse(recalled.Message.ID)); err != nil {
		t.Fatalf("recall mention: %v", err)
	}
	assertNoDurableMention(t, ctx, service, bobPrincipal, groupID)

	editable, err := service.SendMessage(ctx, alicePrincipal, groupID, SendMessageInput{
		ClientMessageID: "durable-edit-000001",
		Type:            "TEXT",
		Content:         &TextContent{Text: "初始无提及"},
	})
	if err != nil {
		t.Fatalf("send editable: %v", err)
	}
	edited, err := service.EditMessage(ctx, alicePrincipal, uuid.MustParse(editable.Message.ID), EditMessageInput{
		Text: "@" + bobHandle + " 编辑后提及", ExpectedEditVersion: 0,
	})
	if err != nil {
		t.Fatalf("edit into mention: %v", err)
	}
	assertDurableMention(t, ctx, service, bobPrincipal, groupID, edited.Message.ID, edited.Message.Sequence)
	if _, err := service.EditMessage(ctx, alicePrincipal, uuid.MustParse(editable.Message.ID), EditMessageInput{
		Text: "编辑移除提及", ExpectedEditVersion: 1,
	}); err != nil {
		t.Fatalf("edit out mention: %v", err)
	}
	assertNoDurableMention(t, ctx, service, bobPrincipal, groupID)

	ownerAll, err := service.SendMessage(ctx, alicePrincipal, groupID, SendMessageInput{
		ClientMessageID: "durable-all-0000001",
		Type:            "TEXT",
		Content:         &TextContent{Text: "@all owner broadcast"},
	})
	if err != nil {
		t.Fatalf("owner @all: %v", err)
	}
	assertDurableMention(t, ctx, service, bobPrincipal, groupID, ownerAll.Message.ID, ownerAll.Message.Sequence)
	assertDurableMention(t, ctx, service, carolPrincipal, groupID, ownerAll.Message.ID, ownerAll.Message.Sequence)
	assertNoDurableMention(t, ctx, service, alicePrincipal, groupID)

	if _, _, err := service.MarkRead(ctx, bobPrincipal, groupID, ownerAll.Message.Sequence); err != nil {
		t.Fatalf("mark bob @all read: %v", err)
	}
	if _, _, err := service.MarkRead(ctx, carolPrincipal, groupID, ownerAll.Message.Sequence); err != nil {
		t.Fatalf("mark carol @all read: %v", err)
	}
	memberAll, err := service.SendMessage(ctx, carolPrincipal, groupID, SendMessageInput{
		ClientMessageID: "durable-all-0000002",
		Type:            "TEXT",
		Content:         &TextContent{Text: "@all member text"},
	})
	if err != nil {
		t.Fatalf("member @all: %v", err)
	}
	if durableMentionHasEntity(memberAll.Message.Content, "MENTION_ALL") {
		t.Fatalf("member unexpectedly produced MENTION_ALL: %+v", memberAll.Message.Content)
	}
	assertNoDurableMention(t, ctx, service, bobPrincipal, groupID)

	forged, err := service.SendMessage(ctx, alicePrincipal, groupID, SendMessageInput{
		ClientMessageID: "durable-fake-000001",
		Type:            "TEXT",
		Content: &TextContent{Text: "plain text", Entities: []MessageEntity{{
			Type: "MENTION", UserID: bob.String(), Offset: 0, Length: 5,
		}}},
	})
	if err != nil {
		t.Fatalf("send forged entity: %v", err)
	}
	if forged.Message.Content != nil && len(forged.Message.Content.Entities) != 0 {
		t.Fatalf("forged entities survived: %+v", forged.Message.Content.Entities)
	}
	assertNoDurableMention(t, ctx, service, bobPrincipal, groupID)

	if _, err := pool.Exec(ctx, `UPDATE conversation_members SET status='REMOVED',left_at=$3 WHERE conversation_id=$1 AND user_id=$2`, groupID, carol, now); err != nil {
		t.Fatalf("remove member: %v", err)
	}
	if _, err := service.GetConversation(ctx, carolPrincipal, groupID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("removed member err=%v want ErrNotFound", err)
	}
}

type durableMentionMember struct {
	userID uuid.UUID
	role   string
}

func insertDurableMentionGroup(t *testing.T, ctx context.Context, pool *pgxpool.Pool, ownerID uuid.UUID, members []durableMentionMember) uuid.UUID {
	t.Helper()
	var conversationID uuid.UUID
	if err := pool.QueryRow(ctx, `INSERT INTO conversations(type) VALUES('GROUP') RETURNING id`).Scan(&conversationID); err != nil {
		t.Fatalf("insert group conversation: %v", err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO groups(conversation_id,name,created_by_user_id) VALUES($1,'Durable Mentions',$2)`, conversationID, ownerID); err != nil {
		t.Fatalf("insert group: %v", err)
	}
	for _, member := range members {
		if _, err := pool.Exec(ctx, `
			INSERT INTO conversation_members(conversation_id,user_id,role,status,joined_at,last_read_sequence)
			VALUES($1,$2,$3,'ACTIVE',now(),0)
		`, conversationID, member.userID, member.role); err != nil {
			t.Fatalf("insert group member %s: %v", member.userID, err)
		}
	}
	return conversationID
}

func durableMentionHandle(t *testing.T, ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID) string {
	t.Helper()
	var handle string
	if err := pool.QueryRow(ctx, `SELECT handle_normalized FROM users WHERE id=$1`, userID).Scan(&handle); err != nil {
		t.Fatalf("load handle: %v", err)
	}
	return handle
}

func assertDurableMention(t *testing.T, ctx context.Context, service *Service, principal account.Principal, conversationID uuid.UUID, messageID string, sequence int64) {
	t.Helper()
	conversation, err := service.GetConversation(ctx, principal, conversationID)
	if err != nil {
		t.Fatalf("get mention conversation: %v", err)
	}
	if conversation.LatestUnreadMentionMessageID == nil || *conversation.LatestUnreadMentionMessageID != messageID {
		t.Fatalf("mention message=%#v want=%s", conversation.LatestUnreadMentionMessageID, messageID)
	}
	if conversation.LatestUnreadMentionSequence == nil || *conversation.LatestUnreadMentionSequence != sequence {
		t.Fatalf("mention sequence=%#v want=%d", conversation.LatestUnreadMentionSequence, sequence)
	}
}

func assertNoDurableMention(t *testing.T, ctx context.Context, service *Service, principal account.Principal, conversationID uuid.UUID) {
	t.Helper()
	conversation, err := service.GetConversation(ctx, principal, conversationID)
	if err != nil {
		t.Fatalf("get no-mention conversation: %v", err)
	}
	if conversation.LatestUnreadMentionMessageID != nil || conversation.LatestUnreadMentionSequence != nil {
		t.Fatalf("unexpected mention target message=%#v sequence=%#v", conversation.LatestUnreadMentionMessageID, conversation.LatestUnreadMentionSequence)
	}
}

func durableMentionConversation(t *testing.T, items []Conversation, conversationID string) Conversation {
	t.Helper()
	for _, item := range items {
		if item.ID == conversationID {
			return item
		}
	}
	t.Fatalf("conversation %s not listed", conversationID)
	return Conversation{}
}

func durableMentionHasEntity(content *TextContent, entityType string) bool {
	if content == nil {
		return false
	}
	for _, entity := range content.Entities {
		if entity.Type == entityType {
			return true
		}
	}
	return false
}
