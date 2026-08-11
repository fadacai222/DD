package messaging

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestStickerSendAuthorizationWithPostgres(t *testing.T) {
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
		t.Fatal(err)
	}

	suffix := fmt.Sprintf("%x", time.Now().UnixNano())
	if len(suffix) > 8 {
		suffix = suffix[len(suffix)-8:]
	}
	aliceID, aliceDevice := insertMessagingTestUser(t, ctx, pool, "sta"+suffix, "Sticker Alice")
	bobID, bobDevice := insertMessagingTestUser(t, ctx, pool, "stb"+suffix, "Sticker Bob")
	defer cleanupMessagingUsers(t, pool, []uuid.UUID{aliceID, bobID})

	service, err := NewService(Config{Pool: pool, Now: func() time.Time {
		return time.Date(2026, 8, 10, 8, 0, 0, 0, time.UTC)
	}})
	if err != nil {
		t.Fatal(err)
	}
	alice := account.Principal{UserID: aliceID, DeviceID: aliceDevice}
	bob := account.Principal{UserID: bobID, DeviceID: bobDevice}
	conversation, err := service.EnsureDirectConversation(ctx, alice, bobID)
	if err != nil {
		t.Fatalf("ensure direct conversation: %v", err)
	}
	conversationID := uuid.MustParse(conversation.ID)

	mediaID := uuid.New()
	packID := uuid.New()
	itemID := uuid.New()
	setName := "AuthPack_" + suffix
	if _, err := pool.Exec(ctx, `
		INSERT INTO media_objects(id,owner_user_id,storage_key,original_name,mime_type,size_bytes,sha256,purpose,status,encryption_mode,created_at,ready_at)
		VALUES($1,NULL,$2,'pack.webp','image/webp',2048,$3,'STICKER','READY','NONE',now(),now())
	`, mediaID, "sticker/auth/"+mediaID.String(), strings.Repeat("b", 64)); err != nil {
		t.Fatalf("seed sticker media: %v", err)
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO telegram_sticker_packs(id,set_name,title,source_identifier,cover_media_id,supported_sticker_count,unsupported_sticker_count)
		VALUES($1,$2,'Authorization Pack',$2,$3,1,0)
	`, packID, setName, mediaID); err != nil {
		t.Fatalf("seed sticker pack: %v", err)
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO telegram_sticker_items(id,pack_id,source_file_id,source_file_unique_id,media_id,emoji,mime_type,width,height,size_bytes,sort_order)
		VALUES($1,$2,'tg-file',$3,$4,'','image/webp',512,512,2048,0)
	`, itemID, packID, "tg-unique-"+setName, mediaID); err != nil {
		t.Fatalf("seed sticker item: %v", err)
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO user_sticker_packs(user_id,pack_id,sort_order) VALUES($1,$2,0)
	`, aliceID, packID); err != nil {
		t.Fatalf("seed sticker subscription: %v", err)
	}
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM telegram_sticker_packs WHERE id=$1`, packID)
		_, _ = pool.Exec(context.Background(), `DELETE FROM media_objects WHERE id=$1`, mediaID)
	}()

	if _, err := service.SendMessage(ctx, alice, conversationID, SendMessageInput{
		ClientMessageID: "sticker-owned-0001",
		Type:            "STICKER",
		Content:         &TextContent{MediaID: mediaID.String(), Width: 512, Height: 512},
	}); err != nil {
		t.Fatalf("subscribed user should send sticker: %v", err)
	}

	share, err := service.SendMessage(ctx, alice, conversationID, SendMessageInput{
		ClientMessageID: "sticker-pack-00001",
		Type:            "STICKER_PACK",
		Content:         &TextContent{MediaID: mediaID.String(), Width: 512, Height: 512},
	})
	if err != nil {
		t.Fatalf("subscribed user should share sticker pack: %v", err)
	}
	if share.Message.Type != "STICKER_PACK" || share.Message.Content == nil {
		t.Fatalf("sticker pack share message=%#v", share.Message)
	}
	shareURI, err := url.Parse(share.Message.Content.Text)
	if err != nil {
		t.Fatalf("parse sticker pack share uri: %v", err)
	}
	if shareURI.Scheme != "dd" || shareURI.Host != "stickers" ||
		shareURI.Path != "/telegram/"+setName || shareURI.Query().Get("title") != "Authorization Pack" {
		t.Fatalf("sticker pack share uri=%q", share.Message.Content.Text)
	}
	var attached bool
	if err := pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM message_media WHERE message_id=$1 AND media_id=$2 AND role='PRIMARY')`, share.Message.ID, mediaID).Scan(&attached); err != nil || !attached {
		t.Fatalf("sticker pack preview attachment attached=%v err=%v", attached, err)
	}

	forwarded, err := service.ForwardMessage(ctx, bob, uuid.MustParse(share.Message.ID), ForwardMessageInput{
		TargetConversationID: conversationID.String(),
		ClientMessageID:      "sticker-pack-fwd01",
	})
	if err != nil {
		t.Fatalf("recipient should forward shared sticker pack without subscribing: %v", err)
	}
	if forwarded.Message.Type != "STICKER_PACK" || forwarded.Message.Content == nil || forwarded.Message.Content.Text != share.Message.Content.Text {
		t.Fatalf("forwarded sticker pack=%#v", forwarded.Message)
	}

	if _, err := service.SendMessage(ctx, bob, conversationID, SendMessageInput{
		ClientMessageID: "sticker-seen-00001",
		Type:            "STICKER",
		Content:         &TextContent{MediaID: mediaID.String(), Width: 512, Height: 512},
	}); err != ErrForbidden {
		t.Fatalf("viewer without subscription send error=%v want ErrForbidden", err)
	}

	if _, err := pool.Exec(ctx, `INSERT INTO user_sticker_packs(user_id,pack_id,sort_order) VALUES($1,$2,0)`, bobID, packID); err != nil {
		t.Fatalf("subscribe bob: %v", err)
	}
	if _, err := service.SendMessage(ctx, bob, conversationID, SendMessageInput{
		ClientMessageID: "sticker-subscribe1",
		Type:            "STICKER",
		Content:         &TextContent{MediaID: mediaID.String(), Width: 512, Height: 512},
	}); err != nil {
		t.Fatalf("subscribed bob should send sticker: %v", err)
	}

	if _, err := pool.Exec(ctx, `DELETE FROM user_sticker_packs WHERE pack_id=$1`, packID); err != nil {
		t.Fatalf("remove sticker subscriptions before archived-share forward: %v", err)
	}
	if _, err := pool.Exec(ctx, `DELETE FROM telegram_sticker_packs WHERE id=$1`, packID); err != nil {
		t.Fatalf("remove sticker pack cache before archived-share forward: %v", err)
	}
	archivedForward, err := service.ForwardMessage(ctx, bob, uuid.MustParse(share.Message.ID), ForwardMessageInput{
		TargetConversationID: conversationID.String(),
		ClientMessageID:      "sticker-pack-fwd02",
	})
	if err != nil {
		t.Fatalf("shared sticker pack should remain forwardable after pack cache removal: %v", err)
	}
	if archivedForward.Message.Content == nil || archivedForward.Message.Content.Text != share.Message.Content.Text {
		t.Fatalf("archived sticker pack forward=%#v", archivedForward.Message)
	}
}
