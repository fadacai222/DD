package stickers

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/media"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestStickerLibraryWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_STICKERS_TEST_DATABASE_URL"))
	if databaseURL == "" {
		databaseURL = strings.TrimSpace(os.Getenv("DD_MESSAGING_TEST_DATABASE_URL"))
	}
	if databaseURL == "" {
		t.Skip("DD_STICKERS_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
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
	alice, aliceDevice := insertStickerTestUser(t, ctx, pool, "sa"+suffix[len(suffix)-8:])
	bob, bobDevice := insertStickerTestUser(t, ctx, pool, "sb"+suffix[len(suffix)-8:])
	defer cleanupStickerTestData(t, pool, []uuid.UUID{alice, bob})

	alicePrincipal := account.Principal{UserID: alice, DeviceID: aliceDevice}
	bobPrincipal := account.Principal{UserID: bob, DeviceID: bobDevice}
	customMediaID := insertOwnedStickerMedia(t, ctx, pool, alice)
	provider := &fakeTelegramProvider{
		set: TelegramStickerSet{
			Name:  "Animals_by_TestBot",
			Title: "Animals",
			Stickers: []TelegramSticker{
				{FileID: "file-cat", FileUniqueID: "unique-cat", Emoji: "🐱", Width: 512, Height: 512, FileSize: 19},
				{FileID: "file-dog", FileUniqueID: "unique-dog", Emoji: "🐶", Width: 512, Height: 512, FileSize: 19},
				{FileID: "file-video", FileUniqueID: "unique-video", Emoji: "🎬", Width: 512, Height: 512, FileSize: 1024, IsVideo: true},
			},
		},
	}
	importer := &fakeManagedMediaImporter{pool: pool}
	service, err := NewService(Config{Pool: pool, Provider: provider, Media: importer, Now: func() time.Time {
		return time.Date(2026, 8, 10, 7, 30, 0, 0, time.UTC)
	}})
	if err != nil {
		t.Fatal(err)
	}

	created, err := service.CreateCustomSticker(ctx, alicePrincipal, CreateCustomStickerInput{
		MediaID: customMediaID.String(), Width: 512, Height: 512,
	})
	if err != nil {
		t.Fatalf("create custom sticker: %v", err)
	}
	if _, err := service.CreateCustomSticker(ctx, bobPrincipal, CreateCustomStickerInput{
		MediaID: customMediaID.String(), Width: 512, Height: 512,
	}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("non-owner create error = %v, want ErrForbidden", err)
	}
	aliceOtherDevice := alicePrincipal
	aliceOtherDevice.DeviceID = uuid.New()
	listed, err := service.ListCustomStickers(ctx, aliceOtherDevice)
	if err != nil || len(listed) != 1 || listed[0].ID != created.ID {
		t.Fatalf("multi-device custom sticker list = %#v, err=%v", listed, err)
	}
	if _, err := service.DeleteCustomStickers(ctx, bobPrincipal, DeleteCustomStickersInput{StickerIDs: []string{created.ID}}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("non-owner delete error = %v, want ErrNotFound", err)
	}
	if count, err := service.DeleteCustomStickers(ctx, alicePrincipal, DeleteCustomStickersInput{StickerIDs: []string{created.ID}}); err != nil || count != 1 {
		t.Fatalf("delete custom sticker count=%d err=%v", count, err)
	}
	listed, err = service.ListCustomStickers(ctx, alicePrincipal)
	if err != nil || len(listed) != 0 {
		t.Fatalf("custom stickers after delete = %#v, err=%v", listed, err)
	}

	alicePack, err := service.ImportTelegramPack(ctx, alicePrincipal, "Animals_by_TestBot")
	if err != nil {
		t.Fatalf("alice import pack: %v", err)
	}
	if len(alicePack.Items) != 2 || alicePack.UnsupportedStickerCount != 1 {
		t.Fatalf("alice pack = %#v", alicePack)
	}
	if provider.getSetCalls != 1 || provider.downloadCalls != 2 || importer.calls != 2 {
		t.Fatalf("unexpected first import calls: provider=%d/%d importer=%d", provider.getSetCalls, provider.downloadCalls, importer.calls)
	}

	bobPack, err := service.ImportTelegramPack(ctx, bobPrincipal, "Animals_by_TestBot")
	if err != nil {
		t.Fatalf("bob cached import pack: %v", err)
	}
	if len(bobPack.Items) != 2 {
		t.Fatalf("bob pack items = %d", len(bobPack.Items))
	}
	if provider.getSetCalls != 1 || provider.downloadCalls != 2 || importer.calls != 2 {
		t.Fatalf("cached pack should not refetch Telegram: provider=%d/%d importer=%d", provider.getSetCalls, provider.downloadCalls, importer.calls)
	}

	if err := service.RemoveStickerPack(ctx, alicePrincipal, uuid.MustParse(alicePack.ID)); err != nil {
		t.Fatalf("remove alice pack: %v", err)
	}
	alicePacks, err := service.ListStickerPacks(ctx, alicePrincipal)
	if err != nil || len(alicePacks) != 0 {
		t.Fatalf("alice packs after remove = %#v, err=%v", alicePacks, err)
	}
	bobPacks, err := service.ListStickerPacks(ctx, bobPrincipal)
	if err != nil || len(bobPacks) != 1 || len(bobPacks[0].Items) != 2 {
		t.Fatalf("bob pack must survive alice removal: %#v, err=%v", bobPacks, err)
	}
	if err := service.RemoveStickerPack(ctx, bobPrincipal, uuid.MustParse(bobPack.ID)); err != nil {
		t.Fatalf("remove bob pack: %v", err)
	}
	if _, err := pool.Exec(ctx, `UPDATE telegram_sticker_packs SET cache_refreshed_at=$2 WHERE id=$1`, uuid.MustParse(bobPack.ID), time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC)); err != nil {
		t.Fatalf("age unused sticker pack: %v", err)
	}
	removed, err := service.CleanupUnusedPacks(ctx, 10, 30*24*time.Hour)
	if err != nil || removed != 1 {
		t.Fatalf("cleanup unused sticker pack removed=%d err=%v", removed, err)
	}
	var packExists bool
	if err := pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM telegram_sticker_packs WHERE id=$1)`, uuid.MustParse(bobPack.ID)).Scan(&packExists); err != nil || packExists {
		t.Fatalf("unused sticker pack must be deleted exists=%v err=%v", packExists, err)
	}
}

type fakeTelegramProvider struct {
	set           TelegramStickerSet
	getSetCalls   int
	downloadCalls int
}

func (fake *fakeTelegramProvider) GetStickerSet(_ context.Context, setName string) (TelegramStickerSet, error) {
	fake.getSetCalls++
	if setName != fake.set.Name {
		return TelegramStickerSet{}, ErrNotFound
	}
	return fake.set, nil
}

func (fake *fakeTelegramProvider) DownloadSticker(_ context.Context, fileID string, maxBytes int64) (TelegramFile, error) {
	fake.downloadCalls++
	if maxBytes < 19 || (fileID != "file-cat" && fileID != "file-dog") {
		return TelegramFile{}, ErrInvalidInput
	}
	data := append([]byte("RIFF\x10\x00\x00\x00WEBP"), []byte(fileID[:7])...)
	return TelegramFile{Bytes: data, MIMEType: "image/webp", FileName: fileID + ".webp"}, nil
}

type fakeManagedMediaImporter struct {
	pool  *pgxpool.Pool
	calls int
}

func (fake *fakeManagedMediaImporter) ImportManagedSticker(ctx context.Context, input media.ManagedStickerInput) (media.MediaObject, error) {
	fake.calls++
	id := uuid.New()
	digest := sha256.Sum256(input.Bytes)
	sha := hex.EncodeToString(digest[:])
	now := time.Date(2026, 8, 10, 7, 30, 0, 0, time.UTC)
	_, err := fake.pool.Exec(ctx, `
		INSERT INTO media_objects(id,owner_user_id,storage_key,original_name,mime_type,size_bytes,sha256,purpose,status,encryption_mode,created_at,ready_at)
		VALUES($1,NULL,$2,$3,$4,$5,$6,'STICKER','READY','NONE',$7,$7)
	`, id, "sticker/test/"+id.String(), input.FileName, input.MIMEType, len(input.Bytes), sha, now)
	if err != nil {
		return media.MediaObject{}, err
	}
	return media.MediaObject{
		ID: id.String(), OriginalName: input.FileName, MIMEType: input.MIMEType,
		SizeBytes: int64(len(input.Bytes)), SHA256: sha, Purpose: media.PurposeSticker,
		Status: media.StatusReady, EncryptionMode: "NONE", CreatedAt: now, ReadyAt: &now,
	}, nil
}

func insertStickerTestUser(t *testing.T, ctx context.Context, pool *pgxpool.Pool, handle string) (uuid.UUID, uuid.UUID) {
	t.Helper()
	var userID uuid.UUID
	if err := pool.QueryRow(ctx, `
		INSERT INTO users(email_normalized,email_verified_at,handle_normalized,display_name,status)
		VALUES($1,now(),$2,$3,'ACTIVE') RETURNING id
	`, handle+"@stickers.example.test", handle, handle).Scan(&userID); err != nil {
		t.Fatalf("insert sticker user: %v", err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO user_privacy_settings(user_id) VALUES($1)`, userID); err != nil {
		t.Fatalf("insert privacy: %v", err)
	}
	var deviceID uuid.UUID
	if err := pool.QueryRow(ctx, `
		INSERT INTO devices(user_id,name,platform,app_version)
		VALUES($1,'Sticker Test','WINDOWS','test') RETURNING id
	`, userID).Scan(&deviceID); err != nil {
		t.Fatalf("insert sticker device: %v", err)
	}
	return userID, deviceID
}

func insertOwnedStickerMedia(t *testing.T, ctx context.Context, pool *pgxpool.Pool, owner uuid.UUID) uuid.UUID {
	t.Helper()
	id := uuid.New()
	_, err := pool.Exec(ctx, `
		INSERT INTO media_objects(id,owner_user_id,storage_key,original_name,mime_type,size_bytes,sha256,purpose,status,encryption_mode,created_at,ready_at)
		VALUES($1,$2,$3,'custom.webp','image/webp',1024,$4,'STICKER','READY','NONE',now(),now())
	`, id, owner, "sticker/custom/"+id.String(), strings.Repeat("a", 64))
	if err != nil {
		t.Fatalf("insert custom sticker media: %v", err)
	}
	return id
}

func cleanupStickerTestData(t *testing.T, pool *pgxpool.Pool, userIDs []uuid.UUID) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, _ = pool.Exec(ctx, `DELETE FROM user_sticker_packs WHERE user_id=ANY($1::uuid[])`, userIDs)
	_, _ = pool.Exec(ctx, `DELETE FROM custom_stickers WHERE owner_user_id=ANY($1::uuid[])`, userIDs)
	_, _ = pool.Exec(ctx, `DELETE FROM telegram_sticker_packs WHERE set_name='Animals_by_TestBot'`)
	_, _ = pool.Exec(ctx, `DELETE FROM media_objects WHERE owner_user_id IS NULL AND purpose='STICKER' AND storage_key LIKE 'sticker/test/%'`)
	_, _ = pool.Exec(ctx, `DELETE FROM users WHERE id=ANY($1::uuid[])`, userIDs)
}
