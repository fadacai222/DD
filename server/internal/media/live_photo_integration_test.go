package media

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/messaging"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestLivePhotoMediaAuthorizationAndLifecycleWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_MEDIA_TEST_DATABASE_URL"))
	if databaseURL == "" {
		databaseURL = strings.TrimSpace(os.Getenv("DD_MESSAGING_TEST_DATABASE_URL"))
	}
	if databaseURL == "" {
		t.Skip("DD_MEDIA_TEST_DATABASE_URL or DD_MESSAGING_TEST_DATABASE_URL is not set")
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
	alice, aliceDevice := insertMediaIntegrationUser(t, ctx, pool, "la"+suffix, "Live Alice")
	bob, bobDevice := insertMediaIntegrationUser(t, ctx, pool, "lb"+suffix, "Live Bob")
	eve, eveDevice := insertMediaIntegrationUser(t, ctx, pool, "le"+suffix, "Live Eve")
	defer cleanupMediaIntegrationUsers(t, pool, []uuid.UUID{alice, bob, eve})

	now := time.Date(2026, 8, 14, 1, 0, 0, 0, time.UTC)
	messagingService, err := messaging.NewService(messaging.Config{
		Pool: pool,
		Now:  func() time.Time { return now },
	})
	if err != nil {
		t.Fatal(err)
	}
	alicePrincipal := account.Principal{UserID: alice, DeviceID: aliceDevice}
	bobPrincipal := account.Principal{UserID: bob, DeviceID: bobDevice}
	evePrincipal := account.Principal{UserID: eve, DeviceID: eveDevice}
	aliceBob, err := messagingService.EnsureDirectConversation(ctx, alicePrincipal, bob)
	if err != nil {
		t.Fatalf("create alice/bob conversation: %v", err)
	}
	bobEve, err := messagingService.EnsureDirectConversation(ctx, bobPrincipal, eve)
	if err != nil {
		t.Fatalf("create bob/eve conversation: %v", err)
	}

	stillID := uuid.New()
	motionID := uuid.New()
	foreignMotionID := uuid.New()
	if _, err := pool.Exec(ctx, `
		INSERT INTO media_objects(
			id,owner_user_id,storage_key,original_name,mime_type,size_bytes,sha256,purpose,status,encryption_mode,created_at,ready_at
		) VALUES
			($1,$4,$6,'live.heic','image/heic',4000,$9,'CHAT_IMAGE','READY','NONE',$12,$12),
			($2,$4,$7,'live.mov','video/quicktime',8000,$10,'CHAT_VIDEO','READY','NONE',$12,$12),
			($3,$5,$8,'foreign.mov','video/quicktime',9000,$11,'CHAT_VIDEO','READY','NONE',$12,$12)
	`, stillID, motionID, foreignMotionID, alice, eve,
		"chat-image/live/"+stillID.String(), "chat-video/live/"+motionID.String(), "chat-video/live/"+foreignMotionID.String(),
		strings.Repeat("c", 64), strings.Repeat("d", 64), strings.Repeat("e", 64), now); err != nil {
		t.Fatalf("insert live photo media: %v", err)
	}

	_, err = messagingService.SendMessage(ctx, alicePrincipal, uuid.MustParse(aliceBob.ID), messaging.SendMessageInput{
		ClientMessageID: "live-idor-0001",
		Type:            "IMAGE",
		Content: &messaging.TextContent{
			MediaID:                stillID.String(),
			LivePhoto:              true,
			LivePhotoMotionMediaID: foreignMotionID.String(),
			Width:                  3024,
			Height:                 4032,
		},
	})
	if !errors.Is(err, messaging.ErrForbidden) {
		t.Fatalf("foreign Live Photo motion error=%v want forbidden", err)
	}

	sent, err := messagingService.SendMessage(ctx, alicePrincipal, uuid.MustParse(aliceBob.ID), messaging.SendMessageInput{
		ClientMessageID: "live-valid-0001",
		Type:            "IMAGE",
		Content: &messaging.TextContent{
			MediaID:                stillID.String(),
			LivePhoto:              true,
			LivePhotoMotionMediaID: motionID.String(),
			Width:                  3024,
			Height:                 4032,
		},
	})
	if err != nil {
		t.Fatalf("send Live Photo IMAGE: %v", err)
	}
	if sent.Message.Content == nil || !sent.Message.Content.LivePhoto || sent.Message.Content.LivePhotoMotionMediaID != motionID.String() {
		t.Fatalf("Live Photo message payload=%#v", sent.Message.Content)
	}
	var primaryCount, motionCount int
	if err := pool.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE role='PRIMARY'), count(*) FILTER (WHERE role='MOTION')
		FROM message_media WHERE message_id=$1
	`, uuid.MustParse(sent.Message.ID)).Scan(&primaryCount, &motionCount); err != nil || primaryCount != 1 || motionCount != 1 {
		t.Fatalf("Live Photo roles primary=%d motion=%d err=%v", primaryCount, motionCount, err)
	}

	mediaService, err := NewService(Config{
		Pool:  pool,
		Store: &integrationObjectStore{now: func() time.Time { return now }},
		Now:   func() time.Time { return now },
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, mediaID := range []uuid.UUID{stillID, motionID} {
		if _, err := mediaService.GetMedia(ctx, bobPrincipal, mediaID); err != nil {
			t.Fatalf("recipient get Live Photo media %s: %v", mediaID, err)
		}
	}
	if _, err := mediaService.GetMedia(ctx, evePrincipal, motionID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("non-member motion access error=%v want forbidden", err)
	}

	forwarded, err := messagingService.ForwardMessage(ctx, bobPrincipal, uuid.MustParse(sent.Message.ID), messaging.ForwardMessageInput{
		TargetConversationID: bobEve.ID,
		ClientMessageID:      "live-forward-0001",
	})
	if err != nil {
		t.Fatalf("forward Live Photo: %v", err)
	}
	if forwarded.Message.Content == nil || !forwarded.Message.Content.LivePhoto || forwarded.Message.Content.LivePhotoMotionMediaID != motionID.String() {
		t.Fatalf("forwarded Live Photo payload=%#v", forwarded.Message.Content)
	}
	if _, err := mediaService.GetMedia(ctx, evePrincipal, motionID); err != nil {
		t.Fatalf("forward recipient get motion: %v", err)
	}

	if _, err := messagingService.RecallMessage(ctx, alicePrincipal, uuid.MustParse(sent.Message.ID)); err != nil {
		t.Fatalf("recall Live Photo: %v", err)
	}
	var originalMediaRows int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM message_media WHERE message_id=$1`, uuid.MustParse(sent.Message.ID)).Scan(&originalMediaRows); err != nil {
		t.Fatalf("count recalled Live Photo media: %v", err)
	}
	if originalMediaRows != 0 {
		t.Fatalf("recalled Live Photo retained %d media links", originalMediaRows)
	}
	if _, err := mediaService.GetMedia(ctx, evePrincipal, motionID); err != nil {
		t.Fatalf("forwarded motion should remain accessible after source recall: %v", err)
	}

	if err := messagingService.DeleteMessageLocally(ctx, evePrincipal, uuid.MustParse(forwarded.Message.ID)); err != nil {
		t.Fatalf("delete forwarded Live Photo locally: %v", err)
	}
	if _, err := mediaService.GetMedia(ctx, evePrincipal, motionID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("locally deleted Live Photo motion access error=%v want forbidden", err)
	}
	if _, err := mediaService.GetMedia(ctx, bobPrincipal, motionID); err != nil {
		t.Fatalf("local delete must not remove sender motion access: %v", err)
	}
}
