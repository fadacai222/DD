package messaging

import (
	"context"
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

func TestMessagingLoadAtLeast100MessagesPerSecond(t *testing.T) {
	if strings.TrimSpace(os.Getenv("DD_RUN_P4_LOAD")) != "1" {
		t.Skip("DD_RUN_P4_LOAD=1 is required")
	}
	databaseURL := strings.TrimSpace(os.Getenv("DD_MESSAGING_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_MESSAGING_TEST_DATABASE_URL is not set")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		t.Fatal(err)
	}

	service, err := NewService(Config{Pool: pool})
	if err != nil {
		t.Fatal(err)
	}

	const conversationCount = 20
	const messagesPerConversation = 10
	const totalMessages = conversationCount * messagesPerConversation

	principals := make([]account.Principal, 0, conversationCount)
	conversationIDs := make([]uuid.UUID, 0, conversationCount)
	allUserIDs := make([]uuid.UUID, 0, conversationCount*2)
	suffix := fmt.Sprintf("%x", time.Now().UnixNano())
	if len(suffix) > 7 {
		suffix = suffix[len(suffix)-7:]
	}
	defer func() { cleanupMessagingUsers(t, pool, allUserIDs) }()

	for index := 0; index < conversationCount; index++ {
		leftUser, leftDevice := insertMessagingTestUser(t, ctx, pool, fmt.Sprintf("l%s%02d", suffix, index), fmt.Sprintf("Load Left %02d", index))
		rightUser, _ := insertMessagingTestUser(t, ctx, pool, fmt.Sprintf("r%s%02d", suffix, index), fmt.Sprintf("Load Right %02d", index))
		allUserIDs = append(allUserIDs, leftUser, rightUser)
		if _, err := pool.Exec(ctx, `INSERT INTO contacts(owner_user_id,contact_user_id) VALUES ($1,$2),($2,$1)`, leftUser, rightUser); err != nil {
			t.Fatalf("create load contacts %d: %v", index, err)
		}
		principal := account.Principal{UserID: leftUser, DeviceID: leftDevice}
		conversation, err := service.EnsureDirectConversation(ctx, principal, rightUser)
		if err != nil {
			t.Fatalf("create load conversation %d: %v", index, err)
		}
		principals = append(principals, principal)
		conversationIDs = append(conversationIDs, uuid.MustParse(conversation.ID))
	}

	startGate := make(chan struct{})
	errorsCh := make(chan error, totalMessages)
	var wg sync.WaitGroup
	for conversationIndex := 0; conversationIndex < conversationCount; conversationIndex++ {
		principal := principals[conversationIndex]
		conversationID := conversationIDs[conversationIndex]
		for messageIndex := 0; messageIndex < messagesPerConversation; messageIndex++ {
			messageIndex := messageIndex
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-startGate
				_, err := service.SendMessage(ctx, principal, conversationID, SendMessageInput{
					ClientMessageID: fmt.Sprintf("load-%02d-%04d-%d", conversationIndex, messageIndex, time.Now().UnixNano()),
					Type:            "TEXT",
					Content:         &TextContent{Text: "P4 load baseline"},
				})
				if err != nil {
					errorsCh <- err
				}
			}()
		}
	}

	started := time.Now()
	close(startGate)
	wg.Wait()
	duration := time.Since(started)
	close(errorsCh)
	for sendErr := range errorsCh {
		if sendErr != nil {
			t.Fatalf("load send failed: %v", sendErr)
		}
	}

	rate := float64(totalMessages) / duration.Seconds()
	t.Logf("P4 messaging load baseline: messages=%d duration=%s rate=%.1f msg/s", totalMessages, duration, rate)
	if rate < 100 {
		t.Fatalf("P4 messaging baseline %.1f msg/s is below required 100 msg/s", rate)
	}

	var persisted int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM messages WHERE conversation_id=ANY($1::uuid[])`, conversationIDs).Scan(&persisted); err != nil {
		t.Fatalf("count persisted load messages: %v", err)
	}
	if persisted != totalMessages {
		t.Fatalf("persisted messages=%d want=%d", persisted, totalMessages)
	}
}
