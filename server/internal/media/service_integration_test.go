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

func TestVideoMediaAuthorizationAndForwardingWithPostgres(t *testing.T) {
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
	alice, aliceDevice := insertMediaIntegrationUser(t, ctx, pool, "va"+suffix, "Video Alice")
	bob, bobDevice := insertMediaIntegrationUser(t, ctx, pool, "vb"+suffix, "Video Bob")
	eve, eveDevice := insertMediaIntegrationUser(t, ctx, pool, "ve"+suffix, "Video Eve")
	userIDs := []uuid.UUID{alice, bob, eve}
	defer cleanupMediaIntegrationUsers(t, pool, userIDs)

	now := time.Date(2026, 8, 10, 3, 0, 0, 0, time.UTC)
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

	videoID := uuid.New()
	posterID := uuid.New()
	if _, err := pool.Exec(ctx, `
		INSERT INTO media_objects(
			id,owner_user_id,storage_key,original_name,mime_type,size_bytes,sha256,purpose,status,encryption_mode,created_at,ready_at
		) VALUES
			($1,$3,$4,'clip.mp4','video/mp4',1048576,$6,'CHAT_VIDEO','READY','NONE',$8,$8),
			($2,$3,$5,'clip-poster.jpg','image/jpeg',65536,$7,'CHAT_IMAGE','READY','NONE',$8,$8)
	`, videoID, posterID, alice, "chat-video/2026/08/"+videoID.String(), "chat-image/2026/08/"+posterID.String(), strings.Repeat("a", 64), strings.Repeat("b", 64), now); err != nil {
		t.Fatalf("insert ready video media: %v", err)
	}

	sent, err := messagingService.SendMessage(ctx, alicePrincipal, uuid.MustParse(aliceBob.ID), messaging.SendMessageInput{
		ClientMessageID: "video-postgres-0001",
		Type:            "VIDEO",
		Content: &messaging.TextContent{
			MediaID:       videoID.String(),
			PosterMediaID: posterID.String(),
			Width:         1920,
			Height:        1080,
			DurationMS:    3210,
		},
	})
	if err != nil {
		t.Fatalf("send VIDEO message: %v", err)
	}
	if sent.Message.Type != "VIDEO" || sent.Message.Content == nil || sent.Message.Content.PosterMediaID != posterID.String() {
		t.Fatalf("VIDEO message payload=%#v", sent.Message)
	}
	var primaryCount, thumbnailCount int
	if err := pool.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE role='PRIMARY'), count(*) FILTER (WHERE role='THUMBNAIL')
		FROM message_media WHERE message_id=$1
	`, uuid.MustParse(sent.Message.ID)).Scan(&primaryCount, &thumbnailCount); err != nil || primaryCount != 1 || thumbnailCount != 1 {
		t.Fatalf("VIDEO message media roles primary=%d thumbnail=%d err=%v", primaryCount, thumbnailCount, err)
	}

	store := &integrationObjectStore{now: func() time.Time { return now }}
	mediaService, err := NewService(Config{
		Pool:  pool,
		Store: store,
		Now:   func() time.Time { return now },
	})
	if err != nil {
		t.Fatal(err)
	}

	for _, mediaID := range []uuid.UUID{videoID, posterID} {
		if _, err := mediaService.GetMedia(ctx, bobPrincipal, mediaID); err != nil {
			t.Fatalf("conversation member get media %s: %v", mediaID, err)
		}
		url, expiresAt, err := mediaService.CreateDownloadURL(ctx, bobPrincipal, mediaID)
		if err != nil || !strings.HasPrefix(url, "https://download.example/") || !expiresAt.After(now) {
			t.Fatalf("conversation member download media %s url=%q expires=%v err=%v", mediaID, url, expiresAt, err)
		}
		if _, err := mediaService.GetMedia(ctx, evePrincipal, mediaID); !errors.Is(err, ErrForbidden) {
			t.Fatalf("non-member get media %s err=%v", mediaID, err)
		}
		if _, _, err := mediaService.CreateDownloadURL(ctx, evePrincipal, mediaID); !errors.Is(err, ErrForbidden) {
			t.Fatalf("non-member download media %s err=%v", mediaID, err)
		}
	}

	forwarded, err := messagingService.ForwardMessage(ctx, bobPrincipal, uuid.MustParse(sent.Message.ID), messaging.ForwardMessageInput{
		TargetConversationID: bobEve.ID,
		ClientMessageID:      "video-forward-0001",
	})
	if err != nil {
		t.Fatalf("forward VIDEO message: %v", err)
	}
	if forwarded.Message.Type != "VIDEO" || forwarded.Message.ForwardedFromMessageID == nil || *forwarded.Message.ForwardedFromMessageID != sent.Message.ID {
		t.Fatalf("forwarded VIDEO payload=%#v", forwarded.Message)
	}
	if forwarded.Message.Content == nil || forwarded.Message.Content.MediaID != videoID.String() || forwarded.Message.Content.PosterMediaID != posterID.String() {
		t.Fatalf("forwarded VIDEO media payload=%#v", forwarded.Message.Content)
	}

	for _, mediaID := range []uuid.UUID{videoID, posterID} {
		if _, err := mediaService.GetMedia(ctx, evePrincipal, mediaID); err != nil {
			t.Fatalf("forward target get media %s: %v", mediaID, err)
		}
		if _, _, err := mediaService.CreateDownloadURL(ctx, evePrincipal, mediaID); err != nil {
			t.Fatalf("forward target download media %s: %v", mediaID, err)
		}
	}
}

type integrationObjectStore struct {
	now func() time.Time
}

func (store *integrationObjectStore) PresignPut(key, contentType, sha256Hex string, ttl time.Duration) (string, map[string]string, time.Time, error) {
	return "https://upload.example/" + key, map[string]string{"Content-Type": contentType}, store.now().Add(ttl), nil
}

func (store *integrationObjectStore) PresignGet(key string, ttl time.Duration) (string, time.Time, error) {
	return "https://download.example/" + key, store.now().Add(ttl), nil
}

func (store *integrationObjectStore) Stat(context.Context, string) (ObjectInfo, error) {
	return ObjectInfo{}, ErrNotFound
}

func (store *integrationObjectStore) Delete(context.Context, string) error {
	return nil
}

func insertMediaIntegrationUser(t *testing.T, ctx context.Context, pool *pgxpool.Pool, handle, displayName string) (uuid.UUID, uuid.UUID) {
	t.Helper()
	var userID uuid.UUID
	if err := pool.QueryRow(ctx, `
		INSERT INTO users(email_normalized,email_verified_at,handle_normalized,display_name,status)
		VALUES ($1,now(),$2,$3,'ACTIVE') RETURNING id
	`, handle+"@media.example.test", handle, displayName).Scan(&userID); err != nil {
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

func cleanupMediaIntegrationUsers(t *testing.T, pool *pgxpool.Pool, userIDs []uuid.UUID) {
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
	_, _ = pool.Exec(ctx, `DELETE FROM media_objects WHERE owner_user_id=ANY($1::uuid[])`, userIDs)
	_, _ = pool.Exec(ctx, `DELETE FROM users WHERE id=ANY($1::uuid[])`, userIDs)
}
