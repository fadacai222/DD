package messaging

import (
	"context"
	"encoding/json"
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

func TestMessagingProductivityWithPostgres(t *testing.T) {
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
		t.Fatalf("ping postgres: %v", err)
	}

	suffix := fmt.Sprintf("%x", time.Now().UnixNano())
	if len(suffix) > 8 {
		suffix = suffix[len(suffix)-8:]
	}
	ownerID, ownerDevice := insertMessagingTestUser(t, ctx, pool, "po"+suffix, "Productivity Owner")
	userIDs := []uuid.UUID{ownerID}
	peerIDs := make([]uuid.UUID, 0, 11)
	peerDevices := make([]uuid.UUID, 0, 11)
	for index := 0; index < 11; index++ {
		peerID, peerDevice := insertMessagingTestUser(
			t,
			ctx,
			pool,
			fmt.Sprintf("pp%s%02d", suffix, index),
			fmt.Sprintf("Peer %02d", index),
		)
		peerIDs = append(peerIDs, peerID)
		peerDevices = append(peerDevices, peerDevice)
		userIDs = append(userIDs, peerID)
		if _, err := pool.Exec(ctx, `
			INSERT INTO contacts(owner_user_id,contact_user_id)
			VALUES ($1,$2),($2,$1)
		`, ownerID, peerID); err != nil {
			t.Fatalf("create contact %d: %v", index, err)
		}
	}
	defer cleanupMessagingUsers(t, pool, userIDs)

	now := time.Date(2026, 8, 9, 4, 20, 0, 0, time.UTC)
	service, err := NewService(Config{Pool: pool, Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	owner := account.Principal{UserID: ownerID, DeviceID: ownerDevice}
	peers := make([]account.Principal, len(peerIDs))
	conversations := make([]uuid.UUID, len(peerIDs))
	for index := range peerIDs {
		peers[index] = account.Principal{UserID: peerIDs[index], DeviceID: peerDevices[index]}
		conversation, err := service.EnsureDirectConversation(ctx, owner, peerIDs[index])
		if err != nil {
			t.Fatalf("ensure conversation %d: %v", index, err)
		}
		conversations[index] = uuid.MustParse(conversation.ID)
	}

	t.Run("pin limit remains ten under concurrent devices", func(t *testing.T) {
		for index := 0; index < 9; index++ {
			pinned := true
			if _, err := service.UpdatePreferences(ctx, owner, conversations[index], UpdatePreferencesInput{IsPinned: &pinned}); err != nil {
				t.Fatalf("pin conversation %d: %v", index, err)
			}
		}

		start := make(chan struct{})
		results := make(chan error, 2)
		var wg sync.WaitGroup
		for _, conversationID := range conversations[9:11] {
			conversationID := conversationID
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				pinned := true
				_, err := service.UpdatePreferences(ctx, owner, conversationID, UpdatePreferencesInput{IsPinned: &pinned})
				results <- err
			}()
		}
		close(start)
		wg.Wait()
		close(results)

		successes := 0
		limitErrors := 0
		for err := range results {
			switch {
			case err == nil:
				successes++
			case errors.Is(err, ErrPinnedLimit):
				limitErrors++
			default:
				t.Fatalf("unexpected concurrent pin error: %v", err)
			}
		}
		if successes != 1 || limitErrors != 1 {
			t.Fatalf("concurrent pin results success=%d limit=%d", successes, limitErrors)
		}
		var count int
		if err := pool.QueryRow(ctx, `
			SELECT count(*) FROM conversation_members
			WHERE user_id=$1 AND status='ACTIVE' AND is_pinned=true
		`, ownerID).Scan(&count); err != nil {
			t.Fatalf("count pinned: %v", err)
		}
		if count != MaximumPinnedChats {
			t.Fatalf("pinned count=%d want=%d", count, MaximumPinnedChats)
		}
	})

	t.Run("far future mute remains JSON serializable", func(t *testing.T) {
		conversationID := conversations[0]
		farFuture := time.Date(9999, 12, 31, 23, 59, 59, 0, time.UTC)
		conversation, err := service.UpdatePreferences(ctx, owner, conversationID, UpdatePreferencesInput{MutedUntil: &farFuture})
		if err != nil {
			t.Fatalf("set far future mute: %v", err)
		}
		if _, err := json.Marshal(conversation); err != nil {
			t.Fatalf("far future muted conversation must remain JSON serializable: %v (mute=%v)", err, conversation.Preferences.MutedUntil)
		}
		if _, err := service.UpdatePreferences(ctx, owner, conversationID, UpdatePreferencesInput{ClearMute: true}); err != nil {
			t.Fatalf("clear far future mute: %v", err)
		}
	})

	t.Run("archive wakes only when conversation is not muted", func(t *testing.T) {
		conversationID := conversations[0]
		archived := true
		if _, err := service.UpdatePreferences(ctx, owner, conversationID, UpdatePreferencesInput{IsArchived: &archived, ClearMute: true}); err != nil {
			t.Fatalf("archive unmuted: %v", err)
		}
		now = now.Add(time.Second)
		if _, err := service.SendMessage(ctx, peers[0], conversationID, SendMessageInput{
			ClientMessageID: "archive-wake-unmuted-01",
			Type:            "TEXT",
			Content:         &TextContent{Text: "wake archive"},
		}); err != nil {
			t.Fatalf("send unmuted archive message: %v", err)
		}
		conversation, err := service.GetConversation(ctx, owner, conversationID)
		if err != nil || conversation.Preferences.ArchivedAt != nil {
			t.Fatalf("unmuted archive should wake: %#v err=%v", conversation.Preferences, err)
		}

		muteUntil := now.Add(24 * time.Hour)
		if _, err := service.UpdatePreferences(ctx, owner, conversationID, UpdatePreferencesInput{IsArchived: &archived, MutedUntil: &muteUntil}); err != nil {
			t.Fatalf("archive muted: %v", err)
		}
		now = now.Add(time.Second)
		if _, err := service.SendMessage(ctx, peers[0], conversationID, SendMessageInput{
			ClientMessageID: "archive-stay-muted-001",
			Type:            "TEXT",
			Content:         &TextContent{Text: "stay archived"},
		}); err != nil {
			t.Fatalf("send muted archive message: %v", err)
		}
		conversation, err = service.GetConversation(ctx, owner, conversationID)
		if err != nil || conversation.Preferences.ArchivedAt == nil {
			t.Fatalf("muted archive should remain archived: %#v err=%v", conversation.Preferences, err)
		}
	})

	t.Run("saved pinned search and forward respect current visibility", func(t *testing.T) {
		conversationID := conversations[1]
		query := "needle-" + suffix
		sent := make([]Message, 0, 4)
		for index, text := range []string{
			query + " visible",
			query + " local-delete",
			query + " recalled",
			"saved secret",
		} {
			now = now.Add(time.Second)
			result, err := service.SendMessage(ctx, owner, conversationID, SendMessageInput{
				ClientMessageID: fmt.Sprintf("productivity-text-%02d-%s", index, suffix),
				Type:            "TEXT",
				Content:         &TextContent{Text: text},
			})
			if err != nil {
				t.Fatalf("send text %d: %v", index, err)
			}
			sent = append(sent, result.Message)
		}

		visibleID := uuid.MustParse(sent[0].ID)
		deletedID := uuid.MustParse(sent[1].ID)
		recalledID := uuid.MustParse(sent[2].ID)
		secretID := uuid.MustParse(sent[3].ID)

		if _, err := service.SaveMessage(ctx, owner, visibleID); err != nil {
			t.Fatalf("save visible: %v", err)
		}
		if _, _, err := service.PinMessage(ctx, peers[1], visibleID); err != nil {
			t.Fatalf("peer pin visible: %v", err)
		}
		if err := service.DeleteMessageLocally(ctx, owner, deletedID); err != nil {
			t.Fatalf("local delete search hit: %v", err)
		}
		if _, err := service.RecallMessage(ctx, owner, recalledID); err != nil {
			t.Fatalf("recall search hit: %v", err)
		}

		hits, err := service.SearchMessages(ctx, owner, query, nil, 20)
		if err != nil {
			t.Fatalf("search: %v", err)
		}
		if len(hits) != 1 || hits[0].Message.ID != sent[0].ID {
			t.Fatalf("search leaked invisible messages: %#v", hits)
		}

		forwarded, err := service.ForwardMessage(ctx, owner, visibleID, ForwardMessageInput{
			TargetConversationID: conversations[2].String(),
			ClientMessageID:      "forward-visible-" + suffix,
		})
		if err != nil {
			t.Fatalf("forward visible: %v", err)
		}
		if forwarded.Message.ForwardedFromMessageID == nil || *forwarded.Message.ForwardedFromMessageID != sent[0].ID {
			t.Fatalf("forward source metadata=%#v", forwarded.Message.ForwardedFromMessageID)
		}
		if forwarded.Message.Content == nil || forwarded.Message.Content.Text != sent[0].Content.Text {
			t.Fatalf("forwarded content=%#v", forwarded.Message.Content)
		}

		if _, err := service.SaveMessage(ctx, owner, secretID); err != nil {
			t.Fatalf("save secret: %v", err)
		}
		if _, err := service.RecallMessage(ctx, owner, secretID); err != nil {
			t.Fatalf("recall saved secret: %v", err)
		}
		saved, err := service.ListSavedMessages(ctx, owner, 20)
		if err != nil {
			t.Fatalf("list saved after recall: %v", err)
		}
		foundRecalled := false
		for _, item := range saved {
			if item.Message.ID != sent[3].ID {
				continue
			}
			foundRecalled = true
			if item.Message.RecalledAt == nil || item.Message.Content == nil || item.Message.Content.Text != "" {
				t.Fatalf("saved recalled message leaked body: %#v", item.Message)
			}
		}
		if !foundRecalled {
			t.Fatal("saved recalled message disappeared instead of becoming unavailable metadata")
		}

		if err := service.DeleteMessageLocally(ctx, owner, visibleID); err != nil {
			t.Fatalf("local delete saved/pinned source: %v", err)
		}
		saved, err = service.ListSavedMessages(ctx, owner, 20)
		if err != nil {
			t.Fatalf("list saved after local delete: %v", err)
		}
		for _, item := range saved {
			if item.Message.ID == sent[0].ID {
				t.Fatal("locally deleted message leaked through saved messages")
			}
		}
		ownerPinned, err := service.ListPinnedMessages(ctx, owner, conversationID, 20)
		if err != nil {
			t.Fatalf("owner list pinned: %v", err)
		}
		for _, item := range ownerPinned {
			if item.Message.ID == sent[0].ID {
				t.Fatal("locally deleted message leaked through pinned messages")
			}
		}
		peerPinned, err := service.ListPinnedMessages(ctx, peers[1], conversationID, 20)
		if err != nil {
			t.Fatalf("peer list pinned: %v", err)
		}
		if len(peerPinned) == 0 || peerPinned[0].Message.ID != sent[0].ID {
			t.Fatalf("one user's local delete incorrectly hid peer pin: %#v", peerPinned)
		}
		if _, err := service.ForwardMessage(ctx, owner, visibleID, ForwardMessageInput{
			TargetConversationID: conversations[2].String(),
			ClientMessageID:      "forward-hidden-" + suffix,
		}); !errors.Is(err, ErrNotFound) {
			t.Fatalf("forward locally deleted source error=%v", err)
		}
	})

	t.Run("media content survives database round trip", func(t *testing.T) {
		conversationID := conversations[3]
		tests := []struct {
			name        string
			messageType string
			purpose     string
			mimeType    string
			content     func(uuid.UUID) *TextContent
		}{
			{name: "image", messageType: "IMAGE", purpose: "CHAT_IMAGE", mimeType: "image/jpeg", content: func(id uuid.UUID) *TextContent { return &TextContent{MediaID: id.String(), Width: 1080, Height: 1440} }},
			{name: "gif", messageType: "GIF", purpose: "GIF", mimeType: "image/gif", content: func(id uuid.UUID) *TextContent { return &TextContent{MediaID: id.String(), Width: 480, Height: 320} }},
			{name: "sticker", messageType: "STICKER", purpose: "STICKER", mimeType: "image/webp", content: func(id uuid.UUID) *TextContent { return &TextContent{MediaID: id.String(), Width: 512, Height: 512} }},
			{name: "file", messageType: "FILE", purpose: "CHAT_FILE", mimeType: "application/pdf", content: func(id uuid.UUID) *TextContent { return &TextContent{MediaID: id.String()} }},
			{name: "voice", messageType: "VOICE", purpose: "CHAT_VOICE", mimeType: "audio/mp4", content: func(id uuid.UUID) *TextContent { return &TextContent{MediaID: id.String(), DurationMS: 4200} }},
		}
		for index, test := range tests {
			mediaID := insertReadyMessagingMedia(t, ctx, pool, ownerID, suffix, index, test.purpose, test.mimeType)
			now = now.Add(time.Second)
			result, err := service.SendMessage(ctx, owner, conversationID, SendMessageInput{
				ClientMessageID: fmt.Sprintf("media-roundtrip-%s-%s", test.name, suffix),
				Type:            test.messageType,
				Content:         test.content(mediaID),
			})
			if err != nil {
				t.Fatalf("send %s: %v", test.name, err)
			}
			if result.Message.Content == nil || result.Message.Content.MediaID != mediaID.String() {
				t.Fatalf("%s content lost after insert/load: %#v", test.name, result.Message.Content)
			}
			loaded, err := service.GetMessage(ctx, owner, uuid.MustParse(result.Message.ID))
			if err != nil {
				t.Fatalf("reload %s: %v", test.name, err)
			}
			if loaded.Content == nil || loaded.Content.MediaID != mediaID.String() {
				t.Fatalf("%s content lost after database reload: %#v", test.name, loaded.Content)
			}
			if test.messageType == "FILE" && (loaded.Content.FileName == "" || loaded.Content.SizeBytes <= 0 || loaded.Content.MIMEType == "") {
				t.Fatalf("file metadata missing after reload: %#v", loaded.Content)
			}
			if test.messageType == "VOICE" && loaded.Content.DurationMS != 4200 {
				t.Fatalf("voice duration missing after reload: %#v", loaded.Content)
			}
		}
	})
}

func insertReadyMessagingMedia(
	t *testing.T,
	ctx context.Context,
	pool *pgxpool.Pool,
	ownerID uuid.UUID,
	suffix string,
	index int,
	purpose string,
	mimeType string,
) uuid.UUID {
	t.Helper()
	var mediaID uuid.UUID
	if err := pool.QueryRow(ctx, `
		INSERT INTO media_objects(
			owner_user_id,storage_key,original_name,mime_type,size_bytes,sha256,purpose,status,ready_at
		) VALUES ($1,$2,$3,$4,$5,$6,$7,'READY',now())
		RETURNING id
	`,
		ownerID,
		fmt.Sprintf("test/productivity/%s/%02d", suffix, index),
		fmt.Sprintf("asset-%02d.bin", index),
		mimeType,
		int64(1024+index),
		strings.Repeat(fmt.Sprintf("%x", (index+1)%16), 64),
		purpose,
	).Scan(&mediaID); err != nil {
		t.Fatalf("insert ready media %s: %v", purpose, err)
	}
	return mediaID
}
