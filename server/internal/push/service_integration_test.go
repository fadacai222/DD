package push

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

type captureProvider struct {
	deliveries []Delivery
	result     ProviderResult
	err        error
}

func (provider *captureProvider) Send(_ context.Context, delivery Delivery) (ProviderResult, error) {
	provider.deliveries = append(provider.deliveries, delivery)
	return provider.result, provider.err
}

func TestPushLifecycleWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_PUSH_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_PUSH_TEST_DATABASE_URL is not set")
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
	senderID, senderDevice := insertPushTestUser(t, ctx, pool, "ps"+suffix, "Alice")
	recipientID, recipientDevice := insertPushTestUser(t, ctx, pool, "pr"+suffix, "Bob")
	defer func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM users WHERE id=ANY($1::uuid[])`, []uuid.UUID{senderID, recipientID})
	}()

	now := time.Date(2026, 8, 11, 5, 0, 0, 0, time.UTC)
	queueTime := time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)
	service, err := NewService(Config{Pool: pool, Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	recipientPrincipal := account.Principal{UserID: recipientID, DeviceID: recipientDevice}
	preferences, err := service.GetPreferences(ctx, recipientPrincipal)
	if err != nil {
		t.Fatal(err)
	}
	if !preferences.PushEnabled || preferences.PreviewMode != PreviewSenderOnly {
		t.Fatalf("default preferences=%+v", preferences)
	}
	preferences, err = service.UpdatePreferences(ctx, recipientPrincipal, UpdatePreferencesInput{PushEnabled: true, PreviewMode: PreviewFull})
	if err != nil {
		t.Fatal(err)
	}
	if preferences.PreviewMode != PreviewFull {
		t.Fatalf("updated preferences=%+v", preferences)
	}
	endpoint, err := service.RegisterEndpoint(ctx, recipientPrincipal, RegisterEndpointInput{
		Provider: ProviderUnifiedPush, Endpoint: "https://push.example.test/capability-" + suffix,
		AppID: "org.openimx.client", Environment: "PRODUCTION",
	})
	if err != nil {
		t.Fatal(err)
	}
	if endpoint.Status != "ACTIVE" || endpoint.Provider != ProviderUnifiedPush {
		t.Fatalf("endpoint=%+v", endpoint)
	}

	conversationID := uuid.New()
	messageID := uuid.New()
	if _, err := pool.Exec(ctx, `
		INSERT INTO conversations(id,type,direct_pair_key,created_at,updated_at,last_sequence)
		VALUES($1,'DIRECT',LEAST($3::text,$4::text)||':'||GREATEST($3::text,$4::text),$2,$2,1)
	`, conversationID, now, senderID, recipientID); err != nil {
		t.Fatalf("seed conversation: %v", err)
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO conversation_members(conversation_id,user_id,role,status,joined_at) VALUES
		  ($1,$2,'MEMBER','ACTIVE',$4),($1,$3,'MEMBER','ACTIVE',$4)
	`, conversationID, senderID, recipientID, now); err != nil {
		t.Fatalf("seed conversation members: %v", err)
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO messages(id,conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,created_at)
		VALUES($1,$2,1,$3,$4,'push-test-message','TEXT',$5::jsonb,$6)
	`, messageID, conversationID, senderID, senderDevice, `{"text":"hello from push"}`, now); err != nil {
		t.Fatalf("seed message: %v", err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO contacts(owner_user_id,contact_user_id,remark) VALUES($1,$2,'Push Alice')`, recipientID, senderID); err != nil {
		t.Fatalf("seed recipient-private sender remark: %v", err)
	}
	foreignDedupe := "push-foreign:" + suffix
	if _, err := pool.Exec(ctx, `
		INSERT INTO push_jobs(recipient_user_id,event_type,resource_id,conversation_id,actor_user_id,dedupe_key,payload_json,status,available_at,created_at)
		VALUES($1,'MESSAGE_CREATED',$2,$3,$4,$5,'{}'::jsonb,'PENDING',$6,$6)
	`, senderID, messageID, conversationID, recipientID, foreignDedupe, now); err != nil {
		t.Fatalf("seed unrelated pending push job: %v", err)
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO push_jobs(recipient_user_id,event_type,resource_id,conversation_id,actor_user_id,dedupe_key,payload_json,status,available_at,created_at)
		VALUES($1,'MESSAGE_CREATED',$2,$3,$4,$5,'{}'::jsonb,'PENDING',$6,$6)
	`, recipientID, messageID, conversationID, senderID, "push-it:"+suffix, queueTime); err != nil {
		t.Fatalf("seed message push job: %v", err)
	}
	defer func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM conversations WHERE id=$1`, conversationID)
	}()

	provider := &captureProvider{}
	processed, err := service.DispatchJobs(ctx, Providers{UnifiedPush: provider}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if processed != 1 || len(provider.deliveries) != 1 {
		t.Fatalf("processed=%d deliveries=%d", processed, len(provider.deliveries))
	}
	delivery := provider.deliveries[0]
	if delivery.Title != "Push Alice" || delivery.Body != "hello from push" || delivery.ConversationID != conversationID.String() {
		t.Fatalf("delivery=%+v", delivery)
	}
	if delivery.Badge != 1 || delivery.Data["badge"] != "1" || delivery.Data["recipientUserId"] != recipientID.String() || delivery.Data["previewMode"] != PreviewFull {
		t.Fatalf("delivery badge/account/privacy facts=%+v", delivery)
	}
	var jobStatus string
	if err := pool.QueryRow(ctx, `SELECT status FROM push_jobs WHERE dedupe_key=$1`, "push-it:"+suffix).Scan(&jobStatus); err != nil {
		t.Fatal(err)
	}
	if jobStatus != "SENT" {
		t.Fatalf("job status=%s", jobStatus)
	}
	var foreignStatus string
	if err := pool.QueryRow(ctx, `SELECT status FROM push_jobs WHERE dedupe_key=$1`, foreignDedupe).Scan(&foreignStatus); err != nil {
		t.Fatal(err)
	}
	if foreignStatus != "PENDING" {
		t.Fatalf("dispatch consumed unrelated pending job status=%s", foreignStatus)
	}

	if _, err := pool.Exec(ctx, `
		UPDATE conversation_members SET muted_until=$3
		WHERE conversation_id=$1 AND user_id=$2
	`, conversationID, recipientID, now.Add(time.Hour)); err != nil {
		t.Fatalf("mute push conversation: %v", err)
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO push_jobs(recipient_user_id,event_type,resource_id,conversation_id,actor_user_id,dedupe_key,payload_json,status,available_at,created_at)
		VALUES($1,'MESSAGE_CREATED',$2,$3,$4,$5,'{}'::jsonb,'PENDING',$6,$6)
	`, recipientID, messageID, conversationID, senderID, "push-muted:"+suffix, queueTime); err != nil {
		t.Fatalf("seed muted message push job: %v", err)
	}
	mutedProvider := &captureProvider{}
	processed, err = service.DispatchJobs(ctx, Providers{UnifiedPush: mutedProvider}, 1)
	if err != nil {
		t.Fatalf("dispatch muted badge-only push: %v", err)
	}
	if processed != 1 || len(mutedProvider.deliveries) != 1 {
		t.Fatalf("muted processed=%d deliveries=%d", processed, len(mutedProvider.deliveries))
	}
	mutedDelivery := mutedProvider.deliveries[0]
	if !mutedDelivery.BadgeOnly || mutedDelivery.Title != "" || mutedDelivery.Body != "" || mutedDelivery.Badge != 1 || mutedDelivery.Data["badgeOnly"] != "1" {
		t.Fatalf("muted delivery must only refresh badge: %+v", mutedDelivery)
	}
	if _, err := pool.Exec(ctx, `
		UPDATE conversation_members SET muted_until=NULL
		WHERE conversation_id=$1 AND user_id=$2
	`, conversationID, recipientID); err != nil {
		t.Fatalf("unmute push conversation: %v", err)
	}

	if err := service.DeleteEndpoint(ctx, recipientPrincipal, ProviderUnifiedPush); err != nil {
		t.Fatalf("delete unified push endpoint: %v", err)
	}
	fcmEndpoint, err := service.RegisterEndpoint(ctx, recipientPrincipal, RegisterEndpointInput{
		Provider: ProviderFCM, Endpoint: "fcm-registration-token-" + suffix,
		AppID: "org.openimx.client", Environment: "PRODUCTION",
	})
	if err != nil {
		t.Fatalf("register fcm endpoint: %v", err)
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO push_jobs(recipient_user_id,event_type,resource_id,conversation_id,actor_user_id,dedupe_key,payload_json,status,available_at,created_at)
		VALUES($1,'MESSAGE_CREATED',$2,$3,$4,$5,'{}'::jsonb,'PENDING',$6,$6)
	`, recipientID, messageID, conversationID, senderID, "push-auth:"+suffix, queueTime); err != nil {
		t.Fatalf("seed provider auth failure job: %v", err)
	}
	authProvider := &captureProvider{err: errors.New("FCM OAuth HTTP 403: invalid_grant")}
	processed, err = service.DispatchJobs(ctx, Providers{FCM: authProvider}, 1)
	if err != nil {
		t.Fatalf("dispatch provider auth failure: %v", err)
	}
	if processed != 1 {
		t.Fatalf("provider auth processed=%d", processed)
	}
	var endpointStatus string
	var failureCount int
	if err := pool.QueryRow(ctx, `SELECT status,failure_count FROM device_push_endpoints WHERE id=$1`, fcmEndpoint.ID).Scan(&endpointStatus, &failureCount); err != nil {
		t.Fatal(err)
	}
	if endpointStatus != "ACTIVE" || failureCount != 0 {
		t.Fatalf("provider auth failure polluted endpoint status=%s failureCount=%d", endpointStatus, failureCount)
	}
	var authJobStatus string
	var authAttempts int
	if err := pool.QueryRow(ctx, `SELECT status,attempts FROM push_jobs WHERE dedupe_key=$1`, "push-auth:"+suffix).Scan(&authJobStatus, &authAttempts); err != nil {
		t.Fatal(err)
	}
	if authJobStatus != "PENDING" || authAttempts != 1 {
		t.Fatalf("provider auth job status=%s attempts=%d", authJobStatus, authAttempts)
	}

	if _, err := pool.Exec(ctx, `
		INSERT INTO push_jobs(recipient_user_id,event_type,resource_id,conversation_id,actor_user_id,dedupe_key,payload_json,status,available_at,created_at)
		VALUES($1,'MESSAGE_CREATED',$2,$3,$4,$5,'{}'::jsonb,'PENDING',$6,$6)
	`, recipientID, messageID, conversationID, senderID, "push-retry:"+suffix, queueTime); err != nil {
		t.Fatalf("seed retryable provider job: %v", err)
	}
	retryProvider := &captureProvider{err: fmt.Errorf("%w: FCM HTTP 503", ErrRetryable)}
	processed, err = service.DispatchJobs(ctx, Providers{FCM: retryProvider}, 1)
	if err != nil {
		t.Fatalf("dispatch retryable provider failure: %v", err)
	}
	if processed != 1 {
		t.Fatalf("retryable provider processed=%d", processed)
	}
	if err := pool.QueryRow(ctx, `SELECT status,failure_count FROM device_push_endpoints WHERE id=$1`, fcmEndpoint.ID).Scan(&endpointStatus, &failureCount); err != nil {
		t.Fatal(err)
	}
	if endpointStatus != "ACTIVE" || failureCount != 0 {
		t.Fatalf("retryable provider failure polluted endpoint status=%s failureCount=%d", endpointStatus, failureCount)
	}

	ownershipToken := strings.Repeat("ab", 32)
	if _, err := service.RegisterEndpoint(ctx, recipientPrincipal, RegisterEndpointInput{
		Provider: ProviderAPNS, Endpoint: ownershipToken, AppID: "org.openimx.client", Environment: "SANDBOX",
	}); err != nil {
		t.Fatalf("register ownership APNS endpoint: %v", err)
	}
	var reinstallDevice uuid.UUID
	if err := pool.QueryRow(ctx, `
		INSERT INTO devices(user_id,name,platform,app_version)
		VALUES($1,'Bob reinstalled iPhone','IOS','test') RETURNING id
	`, recipientID).Scan(&reinstallDevice); err != nil {
		t.Fatalf("insert reinstall device: %v", err)
	}
	reinstallPrincipal := account.Principal{UserID: recipientID, DeviceID: reinstallDevice}
	if _, err := service.RegisterEndpoint(ctx, reinstallPrincipal, RegisterEndpointInput{
		Provider: ProviderAPNS, Endpoint: ownershipToken, AppID: "org.openimx.client", Environment: "SANDBOX",
	}); err != nil {
		t.Fatalf("same-account reinstall should move APNS endpoint: %v", err)
	}
	var endpointDevice uuid.UUID
	if err := pool.QueryRow(ctx, `
		SELECT device_id FROM device_push_endpoints WHERE provider='APNS' AND endpoint=$1
	`, ownershipToken).Scan(&endpointDevice); err != nil {
		t.Fatalf("load moved reinstall endpoint: %v", err)
	}
	if endpointDevice != reinstallDevice {
		t.Fatalf("reinstall endpoint device=%s want=%s", endpointDevice, reinstallDevice)
	}

	senderPrincipal := account.Principal{UserID: senderID, DeviceID: senderDevice}
	if _, err := service.RegisterEndpoint(ctx, senderPrincipal, RegisterEndpointInput{
		Provider: ProviderAPNS, Endpoint: ownershipToken, AppID: "org.openimx.client", Environment: "SANDBOX",
	}); !errors.Is(err, ErrConflict) {
		t.Fatalf("active cross-account endpoint takeover err=%v want conflict", err)
	}
	if _, err := pool.Exec(ctx, `UPDATE devices SET revoked_at=$2 WHERE id=$1`, reinstallDevice, now); err != nil {
		t.Fatalf("revoke previous endpoint owner device: %v", err)
	}
	if _, err := service.RegisterEndpoint(ctx, senderPrincipal, RegisterEndpointInput{
		Provider: ProviderAPNS, Endpoint: ownershipToken, AppID: "org.openimx.client", Environment: "SANDBOX",
	}); err != nil {
		t.Fatalf("revoked endpoint owner should not block active account registration: %v", err)
	}

	if _, err := pool.Exec(ctx, `
		UPDATE device_push_endpoints
		SET status='INVALID',updated_at=$2,last_failure_at=$2,last_failure_code='UNREGISTERED'
		WHERE id=$1
	`, fcmEndpoint.ID, now.Add(-31*24*time.Hour)); err != nil {
		t.Fatalf("age invalid endpoint: %v", err)
	}
	removed, err := service.CleanupInvalidEndpoints(ctx, 10, 30*24*time.Hour)
	if err != nil {
		t.Fatalf("cleanup invalid endpoint: %v", err)
	}
	if removed != 1 {
		t.Fatalf("removed invalid endpoints=%d", removed)
	}
	var endpointCount int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM device_push_endpoints WHERE id=$1`, fcmEndpoint.ID).Scan(&endpointCount); err != nil {
		t.Fatal(err)
	}
	if endpointCount != 0 {
		t.Fatalf("invalid endpoint still present after retention cleanup")
	}
}

func insertPushTestUser(t *testing.T, ctx context.Context, pool *pgxpool.Pool, handle, displayName string) (uuid.UUID, uuid.UUID) {
	t.Helper()
	var userID uuid.UUID
	if err := pool.QueryRow(ctx, `
		INSERT INTO users(email_normalized,email_verified_at,handle_normalized,display_name,status)
		VALUES($1,now(),$2,$3,'ACTIVE') RETURNING id
	`, handle+"@push.example.test", handle, displayName).Scan(&userID); err != nil {
		t.Fatalf("insert push user: %v", err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO user_privacy_settings(user_id) VALUES($1)`, userID); err != nil {
		t.Fatalf("insert push privacy: %v", err)
	}
	var deviceID uuid.UUID
	if err := pool.QueryRow(ctx, `
		INSERT INTO devices(user_id,name,platform,app_version)
		VALUES($1,$2,'ANDROID','test') RETURNING id
	`, userID, displayName+" Android").Scan(&deviceID); err != nil {
		t.Fatalf("insert push device: %v", err)
	}
	return userID, deviceID
}
