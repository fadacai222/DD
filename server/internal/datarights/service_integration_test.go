package datarights

import (
	"compress/gzip"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/auth/password"
	"example.com/selfhosted-im/server/internal/auth/session"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

type integrationArtifactStore struct {
	mu      sync.Mutex
	objects map[string][]byte
	deleted []string
}

func (store *integrationArtifactStore) Put(_ context.Context, key, _ string, data []byte) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	if store.objects == nil {
		store.objects = make(map[string][]byte)
	}
	store.objects[key] = append([]byte(nil), data...)
	return nil
}

func (store *integrationArtifactStore) PresignGet(key string, ttl time.Duration) (string, time.Time, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	if _, ok := store.objects[key]; !ok {
		return "", time.Time{}, errors.New("artifact missing")
	}
	expires := time.Now().UTC().Add(ttl)
	return "https://private.invalid/download/" + url.PathEscape(key) + "?sig=test-only", expires, nil
}

func (store *integrationArtifactStore) Delete(_ context.Context, key string) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	delete(store.objects, key)
	store.deleted = append(store.deleted, key)
	return nil
}

func TestDataRightsLifecycleWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_DATA_RIGHTS_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_DATA_RIGHTS_TEST_DATABASE_URL is not set")
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
	if len(suffix) > 10 {
		suffix = suffix[len(suffix)-10:]
	}
	hasher, err := password.NewHasher(password.Params{MemoryKiB: 8 * 1024, Iterations: 1, Parallelism: 1, SaltLength: 16, KeyLength: 32})
	if err != nil {
		t.Fatal(err)
	}
	passwordValue := "correct horse battery staple U12"
	user1, device1 := insertDataRightsTestUser(t, ctx, pool, hasher, "u1"+suffix, "Export Alice", passwordValue)
	user2, device2 := insertDataRightsTestUser(t, ctx, pool, hasher, "u2"+suffix, "Other Bob", passwordValue)
	defer func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cleanupCancel()
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM users WHERE id=ANY($1::uuid[])`, []uuid.UUID{user1, user2})
	}()

	now := time.Date(2026, 8, 12, 0, 0, 0, 0, time.UTC)
	store := &integrationArtifactStore{objects: make(map[string][]byte)}
	service, err := NewService(Config{
		Pool: pool, Hasher: hasher, Store: store, Now: func() time.Time { return now },
		CoolingOff: 5 * time.Minute, ExportCooldown: 24 * time.Hour, ExportTTL: 7 * 24 * time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	principal1 := account.Principal{UserID: user1, DeviceID: device1}
	principal2 := account.Principal{UserID: user2, DeviceID: device2}

	conversationID, groupID, privateMediaID, privateObjectKey := seedDataRightsBusinessData(t, ctx, pool, user1, device1, user2, now, suffix)
	_ = conversationID

	firstExport, err := service.RequestExport(ctx, principal1, "export-"+suffix)
	if err != nil {
		t.Fatalf("request export: %v", err)
	}
	if firstExport.Status != ExportQueued {
		t.Fatalf("export status=%s", firstExport.Status)
	}
	duplicate, err := service.RequestExport(ctx, principal1, "export-"+suffix)
	if err != nil || duplicate.ID != firstExport.ID {
		t.Fatalf("idempotent export=%+v err=%v", duplicate, err)
	}
	coalesced, err := service.RequestExport(ctx, principal1, "export-other-"+suffix)
	if err != nil || coalesced.ID != firstExport.ID {
		t.Fatalf("cooldown export=%+v err=%v", coalesced, err)
	}
	firstID := uuid.MustParse(firstExport.ID)
	if _, err := service.GetExport(ctx, principal2, firstID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-user export status error=%v", err)
	}
	if _, err := service.CreateExportDownload(ctx, principal1, firstID); !errors.Is(err, ErrNotReady) {
		t.Fatalf("download before ready error=%v", err)
	}
	processed, err := service.ProcessExportJobs(ctx, 10)
	if err != nil || processed != 1 {
		t.Fatalf("process export jobs processed=%d err=%v", processed, err)
	}
	completed, err := service.GetExport(ctx, principal1, firstID)
	if err != nil || completed.Status != ExportCompleted || completed.ExpiresAt == nil || completed.SHA256 == "" {
		t.Fatalf("completed export=%+v err=%v", completed, err)
	}
	download, err := service.CreateExportDownload(ctx, principal1, firstID)
	if err != nil || !strings.HasPrefix(download.DownloadURL, "https://private.invalid/") || download.ExpiresAt.IsZero() {
		t.Fatalf("download=%+v err=%v", download, err)
	}
	if _, err := service.CreateExportDownload(ctx, principal2, firstID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-user download error=%v", err)
	}
	artifact := findArtifactByRequestID(t, store, firstExport.ID)
	assertExportArtifactScope(t, artifact)
	if strings.Contains(string(gunzipBytes(t, artifact)), "push-secret-endpoint-"+suffix) {
		t.Fatal("export leaked raw push endpoint capability")
	}

	// Simulate a worker/database crash after the durable claim. An expired lease must be reclaimed.
	now = now.Add(25 * time.Hour)
	recoveryExport, err := service.RequestExport(ctx, principal1, "recovery-"+suffix)
	if err != nil {
		t.Fatalf("request recovery export: %v", err)
	}
	recoveryID := uuid.MustParse(recoveryExport.ID)
	if _, err := pool.Exec(ctx, `UPDATE data_export_requests SET status='PROCESSING',started_at=$2,lease_expires_at=$3 WHERE id=$1`, recoveryID, now.Add(-2*time.Minute), now.Add(-time.Minute)); err != nil {
		t.Fatalf("simulate expired export lease: %v", err)
	}
	processed, err = service.ProcessExportJobs(ctx, 1)
	if err != nil || processed != 1 {
		t.Fatalf("recover expired export lease processed=%d err=%v", processed, err)
	}
	recovered, err := service.GetExport(ctx, principal1, recoveryID)
	if err != nil || recovered.Status != ExportCompleted {
		t.Fatalf("recovered export=%+v err=%v", recovered, err)
	}

	cancelRequest, err := service.RequestDeletion(ctx, principal1, RequestDeletionInput{CurrentPassword: passwordValue}, "delete-cancel-"+suffix)
	if err != nil || cancelRequest.Status != DeletionCoolingOff {
		t.Fatalf("request deletion for cancel=%+v err=%v", cancelRequest, err)
	}
	if _, err := service.RequestDeletion(ctx, principal1, RequestDeletionInput{CurrentPassword: "wrong password value"}, "delete-wrong-"+suffix); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("wrong secondary auth error=%v", err)
	}
	cancelled, err := service.CancelDeletion(ctx, principal1, uuid.MustParse(cancelRequest.ID))
	if err != nil || cancelled.Status != DeletionCancelled {
		t.Fatalf("cancel deletion=%+v err=%v", cancelled, err)
	}

	deleteRequest, err := service.RequestDeletion(ctx, principal1, RequestDeletionInput{CurrentPassword: passwordValue}, "delete-final-"+suffix)
	if err != nil || deleteRequest.Status != DeletionCoolingOff {
		t.Fatalf("request final deletion=%+v err=%v", deleteRequest, err)
	}
	deleteID := uuid.MustParse(deleteRequest.ID)
	if _, err := service.GetDeletion(ctx, principal2, deleteID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-user deletion status error=%v", err)
	}
	processed, err = service.ProcessDeletionJobs(ctx, 1)
	if err != nil || processed != 0 {
		t.Fatalf("cooling-off job executed early processed=%d err=%v", processed, err)
	}

	manager, err := session.NewManager(session.Config{
		Secret: strings.Repeat("u12-test-secret-", 3), AccessTTL: time.Hour, Now: func() time.Time { return now },
	})
	if err != nil {
		t.Fatal(err)
	}
	access, err := manager.NewAccessToken(user1, device1)
	if err != nil {
		t.Fatal(err)
	}
	authService, err := account.NewService(account.Config{Pool: pool, Hasher: hasher, Sessions: manager, RegistrationMode: "closed", Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := authService.AuthenticateAccessToken(ctx, access.Raw); err != nil {
		t.Fatalf("access token should be valid before deletion: %v", err)
	}

	now = now.Add(10 * time.Minute)
	processed, err = service.ProcessDeletionJobs(ctx, 1)
	if err != nil || processed != 1 {
		t.Fatalf("process deletion jobs processed=%d err=%v", processed, err)
	}
	var userStatus, email, handle, displayName string
	if err := pool.QueryRow(ctx, `SELECT status,email_normalized,handle_normalized,display_name FROM users WHERE id=$1`, user1).Scan(&userStatus, &email, &handle, &displayName); err != nil {
		t.Fatal(err)
	}
	if userStatus != "DELETED" || !strings.HasPrefix(email, "deleted-") || !strings.HasPrefix(handle, "deleted_") || displayName != "Deleted Account" {
		t.Fatalf("anonymized user status=%s email=%s handle=%s display=%s", userStatus, email, handle, displayName)
	}
	if _, err := authService.AuthenticateAccessToken(ctx, access.Raw); !errors.Is(err, account.ErrUnauthorized) {
		t.Fatalf("deleted account access token error=%v", err)
	}
	var activeDevices, refreshTokens, pushEndpoints, moments, passwords int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM devices WHERE user_id=$1 AND revoked_at IS NULL`, user1).Scan(&activeDevices); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM refresh_tokens WHERE user_id=$1`, user1).Scan(&refreshTokens); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM device_push_endpoints e JOIN devices d ON d.id=e.device_id WHERE d.user_id=$1`, user1).Scan(&pushEndpoints); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM moments WHERE author_user_id=$1`, user1).Scan(&moments); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM auth_passwords WHERE user_id=$1`, user1).Scan(&passwords); err != nil {
		t.Fatal(err)
	}
	if activeDevices != 0 || refreshTokens != 0 || pushEndpoints != 0 || moments != 0 || passwords != 0 {
		t.Fatalf("deletion residue activeDevices=%d refresh=%d push=%d moments=%d passwords=%d", activeDevices, refreshTokens, pushEndpoints, moments, passwords)
	}
	var liveExports int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM data_export_requests WHERE user_id=$1 AND status<>'EXPIRED'`, user1).Scan(&liveExports); err != nil {
		t.Fatal(err)
	}
	if liveExports != 0 {
		t.Fatalf("account deletion left %d live data exports", liveExports)
	}
	store.mu.Lock()
	for key := range store.objects {
		if strings.Contains(key, firstExport.ID) || strings.Contains(key, recoveryExport.ID) {
			store.mu.Unlock()
			t.Fatalf("account deletion left export artifact %s", key)
		}
	}
	store.mu.Unlock()
	var successorRole, deletedMemberStatus string
	if err := pool.QueryRow(ctx, `SELECT role FROM conversation_members WHERE conversation_id=$1 AND user_id=$2`, groupID, user2).Scan(&successorRole); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT status FROM conversation_members WHERE conversation_id=$1 AND user_id=$2`, groupID, user1).Scan(&deletedMemberStatus); err != nil {
		t.Fatal(err)
	}
	if successorRole != "OWNER" || deletedMemberStatus != "REMOVED" {
		t.Fatalf("group ownership successor=%s deletedMember=%s", successorRole, deletedMemberStatus)
	}
	var messageCount int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM messages WHERE sender_user_id=$1`, user1).Scan(&messageCount); err != nil {
		t.Fatal(err)
	}
	if messageCount == 0 {
		t.Fatal("shared messages should be retained and attributed to anonymized Deleted Account identity")
	}
	var privateMediaRows int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM media_objects WHERE id=$1`, privateMediaID).Scan(&privateMediaRows); err != nil {
		t.Fatal(err)
	}
	if privateMediaRows != 0 {
		t.Fatalf("private media metadata rows=%d want=0", privateMediaRows)
	}
	store.mu.Lock()
	deletedObject := false
	for _, key := range store.deleted {
		if key == privateObjectKey {
			deletedObject = true
		}
	}
	store.mu.Unlock()
	if !deletedObject {
		t.Fatalf("private object %s was not physically deleted", privateObjectKey)
	}
	var legalAudit int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM data_rights_audit_events WHERE request_id=$1 AND retention_class='LEGAL_AUDIT'`, deleteID).Scan(&legalAudit); err != nil {
		t.Fatal(err)
	}
	if legalAudit < 3 {
		t.Fatalf("legal audit events=%d", legalAudit)
	}
}

func insertDataRightsTestUser(t *testing.T, ctx context.Context, pool *pgxpool.Pool, hasher *password.Hasher, handle, displayName, plaintextPassword string) (uuid.UUID, uuid.UUID) {
	t.Helper()
	passwordHash, err := hasher.Hash(plaintextPassword)
	if err != nil {
		t.Fatal(err)
	}
	userID := uuid.New()
	if _, err := pool.Exec(ctx, `INSERT INTO users(id,email_normalized,email_verified_at,handle_normalized,display_name,status) VALUES($1,$2,now(),$3,$4,'ACTIVE')`, userID, handle+"@u12.example.test", handle, displayName); err != nil {
		t.Fatalf("insert user: %v", err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO user_privacy_settings(user_id) VALUES($1)`, userID); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO auth_passwords(user_id,password_hash) VALUES($1,$2)`, userID, passwordHash); err != nil {
		t.Fatal(err)
	}
	deviceID := uuid.New()
	if _, err := pool.Exec(ctx, `INSERT INTO devices(id,user_id,name,platform,app_version) VALUES($1,$2,$3,'WINDOWS','u12-test')`, deviceID, userID, displayName+" PC"); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO user_notification_preferences(user_id,push_enabled,preview_mode) VALUES($1,true,'FULL')`, userID); err != nil {
		t.Fatal(err)
	}
	return userID, deviceID
}

func seedDataRightsBusinessData(t *testing.T, ctx context.Context, pool *pgxpool.Pool, user1, device1, user2 uuid.UUID, now time.Time, suffix string) (uuid.UUID, uuid.UUID, uuid.UUID, string) {
	t.Helper()
	conversationID := uuid.New()
	pair := user1.String() + ":" + user2.String()
	if _, err := pool.Exec(ctx, `INSERT INTO conversations(id,type,direct_pair_key,created_at,updated_at,last_sequence) VALUES($1,'DIRECT',$2,$3,$3,1)`, conversationID, pair, now); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO conversation_members(conversation_id,user_id,role,status,joined_at) VALUES($1,$2,'MEMBER','ACTIVE',$4),($1,$3,'MEMBER','ACTIVE',$4)`, conversationID, user1, user2, now); err != nil {
		t.Fatal(err)
	}
	messageID := uuid.New()
	if _, err := pool.Exec(ctx, `INSERT INTO messages(id,conversation_id,sequence,sender_user_id,sender_device_id,client_message_id,type,content_json,created_at) VALUES($1,$2,1,$3,$4,$5,'TEXT',$6::jsonb,$7)`, messageID, conversationID, user1, device1, "u12-msg-"+suffix, `{"text":"retained shared message"}`, now); err != nil {
		t.Fatal(err)
	}

	groupID := uuid.New()
	if _, err := pool.Exec(ctx, `INSERT INTO conversations(id,type,created_at,updated_at) VALUES($1,'GROUP',$2,$2)`, groupID, now); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO conversation_members(conversation_id,user_id,role,status,joined_at) VALUES($1,$2,'OWNER','ACTIVE',$4),($1,$3,'MEMBER','ACTIVE',$4)`, groupID, user1, user2, now); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO groups(conversation_id,name,created_by_user_id,status,created_at,updated_at) VALUES($1,'U12 Group',$2,'ACTIVE',$3,$3)`, groupID, user1, now); err != nil {
		t.Fatal(err)
	}

	privateMediaID := uuid.New()
	privateObjectKey := "moment-image/u12/private-" + suffix
	digest := sha256.Sum256([]byte("u12-private-media"))
	if _, err := pool.Exec(ctx, `INSERT INTO media_objects(id,owner_user_id,storage_key,original_name,mime_type,size_bytes,sha256,purpose,status,encryption_mode,created_at,ready_at) VALUES($1,$2,$3,'private.jpg','image/jpeg',123,$4,'MOMENT_IMAGE','READY','NONE',$5,$5)`, privateMediaID, user1, privateObjectKey, fmt.Sprintf("%x", digest[:]), now); err != nil {
		t.Fatal(err)
	}
	momentID := uuid.New()
	if _, err := pool.Exec(ctx, `INSERT INTO moments(id,author_user_id,text,visibility,status,created_at) VALUES($1,$2,'private moment','PRIVATE','ACTIVE',$3)`, momentID, user1, now); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO moment_media(moment_id,media_id,sort_order) VALUES($1,$2,0)`, momentID, privateMediaID); err != nil {
		t.Fatal(err)
	}

	endpointHash := sha256.Sum256([]byte("push-secret-endpoint-" + suffix))
	if _, err := pool.Exec(ctx, `INSERT INTO device_push_endpoints(device_id,provider,endpoint,endpoint_hash,app_id,environment,status) VALUES($1,'UNIFIEDPUSH',$2,$3,'dd.test','PRODUCTION','ACTIVE')`, device1, "https://push.example.test/push-secret-endpoint-"+suffix, endpointHash[:]); err != nil {
		t.Fatal(err)
	}
	refreshHash := sha256.Sum256([]byte("refresh-token-" + suffix))
	if _, err := pool.Exec(ctx, `INSERT INTO refresh_tokens(user_id,device_id,family_id,token_hash,issued_at,expires_at) VALUES($1,$2,$3,$4,$5,$6)`, user1, device1, uuid.New(), refreshHash[:], now, now.Add(30*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO calls(caller_user_id,callee_user_id,caller_device_id,conversation_id,room_name,kind,status,created_at,ring_expires_at) VALUES($1,$2,$3,$4,$5,'audio','ringing',$6,$7)`, user1, user2, device1, conversationID, "u12-call-"+suffix, now, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	return conversationID, groupID, privateMediaID, privateObjectKey
}

func findArtifactByRequestID(t *testing.T, store *integrationArtifactStore, requestID string) []byte {
	t.Helper()
	store.mu.Lock()
	defer store.mu.Unlock()
	for key, data := range store.objects {
		if strings.Contains(key, requestID) {
			return append([]byte(nil), data...)
		}
	}
	t.Fatalf("artifact for request %s not found", requestID)
	return nil
}

func gunzipBytes(t *testing.T, data []byte) []byte {
	t.Helper()
	reader, err := gzip.NewReader(strings.NewReader(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	decoded, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	return decoded
}

func assertExportArtifactScope(t *testing.T, compressed []byte) {
	t.Helper()
	body := string(gunzipBytes(t, compressed))
	for _, required := range []string{"profile", "contacts", "groups", "messages", "moments", "stickers", "devices", "notificationPreferences", "pushEndpoints"} {
		if !strings.Contains(body, `"`+required+`"`) {
			t.Fatalf("export artifact missing %s: %s", required, body)
		}
	}
}
