package transcription_test

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/messaging"
	"example.com/selfhosted-im/server/internal/transcription"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestWhisperHTTPProviderFailureClassification(t *testing.T) {
	for _, test := range []struct {
		name   string
		status int
		want   error
	}{
		{name: "temporary", status: http.StatusServiceUnavailable, want: transcription.ErrProviderTemp},
		{name: "permanent", status: http.StatusBadRequest, want: transcription.ErrProviderPerm},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
				response.WriteHeader(test.status)
			}))
			defer server.Close()
			provider, err := transcription.NewWhisperHTTPProvider(transcription.WhisperHTTPConfig{Endpoint: server.URL, Model: "whisper-test"})
			if err != nil { t.Fatal(err) }
			_, err = provider.Transcribe(context.Background(), transcription.ProviderInput{FileName: "voice.m4a", Audio: []byte("audio")})
			if !errors.Is(err, test.want) { t.Fatalf("err=%v want=%v", err, test.want) }
		})
	}
}

func TestVoiceTranscriptionLifecycleWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_MESSAGING_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_MESSAGING_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil { t.Fatal(err) }
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil { t.Fatal(err) }

	var migrationReady bool
	if err := pool.QueryRow(ctx, `SELECT to_regclass('voice_transcriptions') IS NOT NULL`).Scan(&migrationReady); err != nil || !migrationReady {
		t.Fatalf("000035_voice_transcriptions migration is not applied: ready=%v err=%v", migrationReady, err)
	}

	suffix := fmt.Sprintf("%x", time.Now().UnixNano())
	if len(suffix) > 10 { suffix = suffix[len(suffix)-10:] }
	alice, aliceDevice := insertUser(t, ctx, pool, "ta"+suffix)
	bob, bobDevice := insertUser(t, ctx, pool, "tb"+suffix)
	eve, eveDevice := insertUser(t, ctx, pool, "te"+suffix)
	defer cleanupUsers(t, pool, []uuid.UUID{alice, bob, eve})
	if _, err := pool.Exec(ctx, `INSERT INTO contacts(owner_user_id,contact_user_id) VALUES($1,$2),($2,$1)`, alice, bob); err != nil {
		t.Fatal(err)
	}

	now := time.Date(2026, 8, 14, 1, 0, 0, 0, time.UTC)
	messagingService, err := messaging.NewService(messaging.Config{Pool: pool, Now: func() time.Time { return now }})
	if err != nil { t.Fatal(err) }
	alicePrincipal := account.Principal{UserID: alice, DeviceID: aliceDevice}
	bobPrincipal := account.Principal{UserID: bob, DeviceID: bobDevice}
	evePrincipal := account.Principal{UserID: eve, DeviceID: eveDevice}
	conversation, err := messagingService.EnsureDirectConversation(ctx, alicePrincipal, bob)
	if err != nil { t.Fatal(err) }
	conversationID := uuid.MustParse(conversation.ID)

	audioServer := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "audio/mp4")
		_, _ = response.Write([]byte("voice-bytes"))
	}))
	defer audioServer.Close()
	mediaGateway := fakeMediaGateway{url: audioServer.URL + "/voice"}
	provider := &fakeProvider{result: transcription.ProviderResult{Transcript: "hello from voice", Language: "en", Model: "whisper-test"}}
	service, err := transcription.NewService(transcription.Config{
		Pool: pool, Provider: provider, Media: mediaGateway, Now: func() time.Time { return now },
	})
	if err != nil { t.Fatal(err) }

	oldVoice := sendVoice(t, ctx, pool, messagingService, alicePrincipal, conversationID, "old", now)
	if _, err := service.Request(ctx, evePrincipal, uuid.MustParse(oldVoice.ID)); !errors.Is(err, transcription.ErrNotFound) {
		t.Fatalf("unauthorized request error=%v", err)
	}
	text, err := messagingService.SendMessage(ctx, alicePrincipal, conversationID, messaging.SendMessageInput{
		ClientMessageID: "text-client-" + suffix,
		Type: "TEXT",
		Content: &messaging.TextContent{Text: "not voice"},
	})
	if err != nil { t.Fatal(err) }
	if _, err := service.Request(ctx, bobPrincipal, uuid.MustParse(text.Message.ID)); !errors.Is(err, transcription.ErrNotVoice) {
		t.Fatalf("non-voice request error=%v", err)
	}

	unavailable, err := transcription.NewService(transcription.Config{Pool: pool, Media: mediaGateway, Now: func() time.Time { return now }})
	if err != nil { t.Fatal(err) }
	if _, err := unavailable.Request(ctx, bobPrincipal, uuid.MustParse(oldVoice.ID)); !errors.Is(err, transcription.ErrUnavailable) {
		t.Fatalf("unavailable request error=%v", err)
	}
	prefs, err := unavailable.GetPreferences(ctx, bobPrincipal)
	if err != nil || prefs.ProviderAvailable || prefs.AutoTranscribeEnabled {
		t.Fatalf("unavailable prefs=%#v err=%v", prefs, err)
	}
	if _, err := unavailable.UpdatePreferences(ctx, bobPrincipal, transcription.UpdatePreferencesInput{AutoTranscribeEnabled: true}); !errors.Is(err, transcription.ErrUnavailable) {
		t.Fatalf("enable unavailable provider error=%v", err)
	}

	first, err := service.Request(ctx, bobPrincipal, uuid.MustParse(oldVoice.ID))
	if err != nil { t.Fatal(err) }
	second, err := service.Request(ctx, bobPrincipal, uuid.MustParse(oldVoice.ID))
	if err != nil { t.Fatal(err) }
	if first.ID != second.ID || first.Status != transcription.StatusPending {
		t.Fatalf("idempotent request first=%#v second=%#v", first, second)
	}
	processed, err := service.ProcessJobs(ctx, 1)
	if err != nil || processed != 1 { t.Fatalf("process success=%d err=%v", processed, err) }
	completed, err := service.Get(ctx, bobPrincipal, uuid.MustParse(oldVoice.ID))
	if err != nil || completed.Status != transcription.StatusCompleted || completed.Transcript != "hello from voice" || completed.Language != "en" {
		t.Fatalf("completed transcription=%#v err=%v", completed, err)
	}

	if _, err := messagingService.RecallMessage(ctx, alicePrincipal, uuid.MustParse(oldVoice.ID)); err != nil { t.Fatal(err) }
	if _, err := service.Get(ctx, bobPrincipal, uuid.MustParse(oldVoice.ID)); !errors.Is(err, transcription.ErrNotFound) {
		t.Fatalf("recalled transcript leaked: err=%v", err)
	}

	// Enabling auto transcription is a time boundary: history before enabled_at is not swept.
	now = now.Add(time.Minute)
	prefs, err = service.UpdatePreferences(ctx, bobPrincipal, transcription.UpdatePreferencesInput{AutoTranscribeEnabled: true})
	if err != nil || !prefs.AutoTranscribeEnabled || !prefs.ProviderAvailable { t.Fatalf("enable prefs=%#v err=%v", prefs, err) }
	queued, err := service.EnqueueEligibleAuto(ctx, 100)
	if err != nil || queued != 0 { t.Fatalf("historical auto queue=%d err=%v", queued, err) }

	now = now.Add(time.Second)
	autoVoice := sendVoice(t, ctx, pool, messagingService, alicePrincipal, conversationID, "auto", now)
	queued, err = service.EnqueueEligibleAuto(ctx, 100)
	if err != nil || queued != 1 { t.Fatalf("new auto queue=%d err=%v", queued, err) }
	queuedAgain, err := service.EnqueueEligibleAuto(ctx, 100)
	if err != nil || queuedAgain != 0 { t.Fatalf("dedupe auto queue=%d err=%v", queuedAgain, err) }
	if _, err := service.Get(ctx, bobPrincipal, uuid.MustParse(autoVoice.ID)); err != nil { t.Fatalf("auto queued status: %v", err) }
	if processed, err := service.ProcessJobs(ctx, 1); err != nil || processed != 1 {
		t.Fatalf("auto process=%d err=%v", processed, err)
	}

	if _, err := service.UpdatePreferences(ctx, bobPrincipal, transcription.UpdatePreferencesInput{AutoTranscribeEnabled: false}); err != nil { t.Fatal(err) }
	now = now.Add(time.Second)
	_ = sendVoice(t, ctx, pool, messagingService, alicePrincipal, conversationID, "disabled", now)
	queued, err = service.EnqueueEligibleAuto(ctx, 100)
	if err != nil || queued != 0 { t.Fatalf("disabled auto queue=%d err=%v", queued, err) }

	// Temporary provider failure is durable and explicitly retryable, without inventing transcript text.
	now = now.Add(time.Second)
	retryVoice := sendVoice(t, ctx, pool, messagingService, alicePrincipal, conversationID, "retry", now)
	retryProvider := &fakeProvider{err: transcription.ErrProviderTemp}
	retryService, err := transcription.NewService(transcription.Config{Pool: pool, Provider: retryProvider, Media: mediaGateway, Now: func() time.Time { return now }})
	if err != nil { t.Fatal(err) }
	if _, err := retryService.Request(ctx, bobPrincipal, uuid.MustParse(retryVoice.ID)); err != nil { t.Fatal(err) }
	if processed, err := retryService.ProcessJobs(ctx, 1); err != nil || processed != 1 { t.Fatalf("retry process=%d err=%v", processed, err) }
	retrying, err := retryService.Get(ctx, bobPrincipal, uuid.MustParse(retryVoice.ID))
	if err != nil || retrying.Status != transcription.StatusPending || !retrying.Retryable || retrying.ErrorCategory != "PROVIDER_TEMPORARY" || retrying.Transcript != "" {
		t.Fatalf("retryable status=%#v err=%v", retrying, err)
	}
}

func sendVoice(t *testing.T, ctx context.Context, pool *pgxpool.Pool, service *messaging.Service, principal account.Principal, conversationID uuid.UUID, label string, now time.Time) messaging.Message {
	t.Helper()
	var mediaID uuid.UUID
	if err := pool.QueryRow(ctx, `
		INSERT INTO media_objects(owner_user_id,storage_key,original_name,mime_type,size_bytes,sha256,purpose,status,ready_at)
		VALUES($1,$2,$3,'audio/mp4',11,$4,'CHAT_VOICE','READY',$5) RETURNING id
	`, principal.UserID, "transcription/"+label+"/"+uuid.NewString(), label+".m4a", strings.Repeat("a", 64), now).Scan(&mediaID); err != nil {
		t.Fatalf("insert voice media: %v", err)
	}
	result, err := service.SendMessage(ctx, principal, conversationID, messaging.SendMessageInput{
		ClientMessageID: "voice-" + label + "-" + uuid.NewString(),
		Type: "VOICE",
		Content: &messaging.TextContent{MediaID: mediaID.String(), DurationMS: 1000},
	})
	if err != nil { t.Fatalf("send voice: %v", err) }
	return result.Message
}

func insertUser(t *testing.T, ctx context.Context, pool *pgxpool.Pool, handle string) (uuid.UUID, uuid.UUID) {
	t.Helper()
	var userID uuid.UUID
	if err := pool.QueryRow(ctx, `
		INSERT INTO users(email_normalized,email_verified_at,handle_normalized,display_name,status)
		VALUES($1,now(),$2,$2,'ACTIVE') RETURNING id
	`, handle+"@transcription.example.test", handle).Scan(&userID); err != nil { t.Fatal(err) }
	if _, err := pool.Exec(ctx, `INSERT INTO user_privacy_settings(user_id) VALUES($1)`, userID); err != nil { t.Fatal(err) }
	var deviceID uuid.UUID
	if err := pool.QueryRow(ctx, `INSERT INTO devices(user_id,name,platform,app_version) VALUES($1,$2,'WINDOWS','test') RETURNING id`, userID, handle+" device").Scan(&deviceID); err != nil { t.Fatal(err) }
	return userID, deviceID
}

func cleanupUsers(t *testing.T, pool *pgxpool.Pool, userIDs []uuid.UUID) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, _ = pool.Exec(ctx, `DELETE FROM conversations WHERE id IN (SELECT conversation_id FROM conversation_members WHERE user_id=ANY($1::uuid[]))`, userIDs)
	_, _ = pool.Exec(ctx, `DELETE FROM users WHERE id=ANY($1::uuid[])`, userIDs)
}

type fakeMediaGateway struct{ url string }
func (gateway fakeMediaGateway) CreateDownloadURL(context.Context, account.Principal, uuid.UUID) (string, time.Time, error) {
	return gateway.url, time.Now().Add(time.Minute), nil
}

type fakeProvider struct {
	result transcription.ProviderResult
	err error
}
func (provider *fakeProvider) Transcribe(context.Context, transcription.ProviderInput) (transcription.ProviderResult, error) {
	return provider.result, provider.err
}
