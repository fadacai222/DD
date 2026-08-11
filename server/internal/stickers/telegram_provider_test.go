package stickers

import (
	"bytes"
	"compress/gzip"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestNormalizeSetNameRejectsURLsAndInvalidCharacters(t *testing.T) {
	valid := []string{"Animals_by_TestBot", "abc", "A1_b2"}
	for _, value := range valid {
		if got, err := normalizeSetName(value); err != nil || got != value {
			t.Fatalf("normalizeSetName(%q) = %q, %v", value, got, err)
		}
	}
	invalid := []string{"", "https://t.me/addstickers/test", "../test", "with space", strings.Repeat("a", 65)}
	for _, value := range invalid {
		if _, err := normalizeSetName(value); err != ErrInvalidInput {
			t.Fatalf("normalizeSetName(%q) error = %v, want %v", value, err, ErrInvalidInput)
		}
	}
}

func TestTelegramBotProviderFetchesStaticStickerWithoutLeakingToken(t *testing.T) {
	const token = "123456:super-secret-token"
	webp := append([]byte("RIFF\x10\x00\x00\x00WEBP"), []byte("payload")...)
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/bot" + token + "/getStickerSet":
			if request.URL.Query().Get("name") != "Animals_by_TestBot" {
				t.Fatalf("unexpected set name: %s", request.URL.RawQuery)
			}
			response.Header().Set("Content-Type", "application/json")
			fmt.Fprint(response, `{"ok":true,"result":{"name":"Animals_by_TestBot","title":"Animals","stickers":[{"file_id":"file-1","file_unique_id":"unique-1","width":512,"height":512,"is_animated":false,"is_video":false,"emoji":"🐱","file_size":19}]}}`)
		case "/bot" + token + "/getFile":
			response.Header().Set("Content-Type", "application/json")
			fmt.Fprint(response, `{"ok":true,"result":{"file_path":"stickers/cat.webp","file_size":19}}`)
		case "/file/bot" + token + "/stickers/cat.webp":
			response.Header().Set("Content-Type", "image/webp")
			_, _ = response.Write(webp)
		default:
			http.NotFound(response, request)
		}
	}))
	defer server.Close()

	provider, err := NewTelegramBotProvider(TelegramBotProviderConfig{Token: token, BaseURL: server.URL, HTTPClient: server.Client()})
	if err != nil {
		t.Fatal(err)
	}
	set, err := provider.GetStickerSet(context.Background(), "Animals_by_TestBot")
	if err != nil {
		t.Fatalf("GetStickerSet() error = %v", err)
	}
	if set.Title != "Animals" || len(set.Stickers) != 1 || set.Stickers[0].FileUniqueID != "unique-1" {
		t.Fatalf("unexpected set: %#v", set)
	}
	file, err := provider.DownloadSticker(context.Background(), "file-1", MaximumTelegramStickerSize)
	if err != nil {
		t.Fatalf("DownloadSticker() error = %v", err)
	}
	if file.MIMEType != "image/webp" || file.FileName != "cat.webp" || string(file.Bytes) != string(webp) {
		t.Fatalf("unexpected file: %#v", file)
	}
	if err := validateStaticTelegramSticker(file); err != nil {
		t.Fatalf("validateStaticTelegramSticker() error = %v", err)
	}
}

func TestValidateTelegramStickerFileSupportsStaticAnimatedAndVideo(t *testing.T) {
	webp := TelegramFile{
		Bytes:    append([]byte("RIFF\x10\x00\x00\x00WEBP"), []byte("payload")...),
		MIMEType: "image/webp",
		FileName: "static.webp",
	}
	if err := validateTelegramStickerFile(TelegramSticker{}, webp); err != nil {
		t.Fatalf("static WebP validation error = %v", err)
	}

	var tgsBuffer bytes.Buffer
	zipper := gzip.NewWriter(&tgsBuffer)
	_, _ = zipper.Write([]byte(`{"v":"5.7.4","fr":60,"ip":0,"op":60,"w":512,"h":512,"layers":[]}`))
	if err := zipper.Close(); err != nil {
		t.Fatal(err)
	}
	tgs := TelegramFile{
		Bytes:    tgsBuffer.Bytes(),
		MIMEType: "application/x-tgsticker",
		FileName: "animated.tgs",
	}
	if err := validateTelegramStickerFile(TelegramSticker{IsAnimated: true}, tgs); err != nil {
		t.Fatalf("TGS validation error = %v", err)
	}

	webm := TelegramFile{
		Bytes:    append([]byte{0x1A, 0x45, 0xDF, 0xA3}, []byte("webm-payload")...),
		MIMEType: "video/webm",
		FileName: "video.webm",
	}
	if err := validateTelegramStickerFile(TelegramSticker{IsVideo: true}, webm); err != nil {
		t.Fatalf("WebM validation error = %v", err)
	}

	if err := validateTelegramStickerFile(TelegramSticker{IsAnimated: true}, webm); err == nil {
		t.Fatal("animated sticker must reject a WebM payload")
	}
	if err := validateTelegramStickerFile(TelegramSticker{IsVideo: true}, tgs); err == nil {
		t.Fatal("video sticker must reject a TGS payload")
	}
	if err := validateTelegramStickerFile(
		TelegramSticker{IsAnimated: true},
		TelegramFile{Bytes: []byte("not-gzip"), MIMEType: "application/x-tgsticker"},
	); err == nil {
		t.Fatal("invalid TGS payload must be rejected")
	}
}

func TestTelegramBotProviderRejectsOversizedDownloadLimit(t *testing.T) {
	provider := &TelegramBotProvider{}
	_, err := provider.DownloadSticker(context.Background(), "file", MaximumTelegramStickerSize+1)
	if err != ErrInvalidInput {
		t.Fatalf("oversized maxBytes error = %v, want %v", err, ErrInvalidInput)
	}
}
