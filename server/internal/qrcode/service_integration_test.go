package qrcode

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/auth/password"
	"example.com/selfhosted-im/server/internal/auth/session"
	"example.com/selfhosted-im/server/internal/groups"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestQRLoginAndGroupInviteWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_QR_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_QR_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatalf("connect postgres: %v", err)
	}
	defer pool.Close()

	now := time.Date(2026, 8, 10, 15, 30, 0, 0, time.UTC)
	suffix := strings.ReplaceAll(uuid.NewString(), "-", "")[:10]
	owner := insertQRUser(t, ctx, pool, "qo"+suffix, "QR Owner")
	seed := insertQRUser(t, ctx, pool, "qs"+suffix, "QR Seed")
	scanner := insertQRUser(t, ctx, pool, "qc"+suffix, "QR Scanner")
	thief := insertQRUser(t, ctx, pool, "qt"+suffix, "QR Thief")
	ownerDevice := insertQRDevice(t, ctx, pool, owner, "Owner Android", "ANDROID")
	scannerDevice := insertQRDevice(t, ctx, pool, scanner, "Scanner Android", "ANDROID")
	thiefDevice := insertQRDevice(t, ctx, pool, thief, "Thief Android", "ANDROID")
	insertQRContactPair(t, ctx, pool, owner, seed)

	sessionManager, err := session.NewManager(session.Config{
		Secret: strings.Repeat("q", 64),
		Now:    func() time.Time { return now },
	})
	if err != nil {
		t.Fatalf("new session manager: %v", err)
	}
	accountService, err := account.NewService(account.Config{
		Pool:             pool,
		Hasher:           password.NewDefaultHasher(),
		Sessions:         sessionManager,
		RegistrationMode: "closed",
		Now:              func() time.Time { return now },
	})
	if err != nil {
		t.Fatalf("new account service: %v", err)
	}
	groupService, err := groups.NewService(groups.Config{Pool: pool, Now: func() time.Time { return now }})
	if err != nil {
		t.Fatalf("new group service: %v", err)
	}
	service, err := NewService(Config{
		Pool: pool, PublicBaseURL: "https://chat.example.invalid", Now: func() time.Time { return now },
		Auth: accountService, Groups: groupService,
	})
	if err != nil {
		t.Fatalf("new qr service: %v", err)
	}

	ownerPrincipal := account.Principal{UserID: owner, DeviceID: ownerDevice}
	scannerPrincipal := account.Principal{UserID: scanner, DeviceID: scannerDevice}
	thiefPrincipal := account.Principal{UserID: thief, DeviceID: thiefDevice}

	userPayload, err := service.UserPayload(scanner)
	if err != nil || !strings.Contains(userPayload.Value, "dd://qr/v1/user?") || !strings.Contains(userPayload.Value, urlQueryEscape(scanner.String())) {
		t.Fatalf("user payload=%+v err=%v", userPayload, err)
	}
	if !strings.Contains(userPayload.Value, urlQueryEscape("https://chat.example.invalid")) {
		t.Fatalf("user payload must bind target instance: %s", userPayload.Value)
	}

	login, err := service.CreateLogin(ctx, CreateLoginInput{Device: DeviceInput{
		Name: "Desktop QR", Platform: "WINDOWS", AppVersion: "1.0.0",
	}})
	if err != nil {
		t.Fatalf("create qr login: %v", err)
	}
	if login.Status != "PENDING" || login.Nonce == "" || !strings.Contains(login.Payload, "dd://qr/v1/login?") {
		t.Fatalf("unexpected login create result: %+v", login)
	}
	decodedNonce, decodeErr := base64.RawURLEncoding.DecodeString(login.Nonce)
	if decodeErr != nil || len(decodedNonce) != 32 {
		t.Fatalf("login nonce must be 32 random bytes: len=%d err=%v", len(decodedNonce), decodeErr)
	}
	nonceHash := sha256.Sum256([]byte(login.Nonce))
	var storedHash []byte
	var targetOrigin string
	if err := pool.QueryRow(ctx, `SELECT nonce_hash,target_origin FROM qr_login_sessions WHERE nonce_hash=$1`, nonceHash[:]).Scan(&storedHash, &targetOrigin); err != nil {
		t.Fatalf("load qr login row: %v", err)
	}
	if string(storedHash) != string(nonceHash[:]) || targetOrigin != "https://chat.example.invalid" {
		t.Fatalf("stored hash/origin mismatch")
	}
	var rawNonceStored bool
	if err := pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM qr_login_sessions WHERE encode(nonce_hash,'base64')=$1)`, login.Nonce).Scan(&rawNonceStored); err != nil {
		t.Fatalf("check raw nonce storage: %v", err)
	}
	if rawNonceStored {
		t.Fatal("raw qr nonce must never be stored")
	}

	pending, err := service.PollLogin(ctx, login.Nonce)
	if err != nil || pending.Status != "PENDING" || pending.Nonce != "" {
		t.Fatalf("poll pending=%+v err=%v", pending, err)
	}
	if _, err := service.ScanLogin(ctx, scannerPrincipal, login.Nonce); err != nil {
		t.Fatalf("scan login: %v", err)
	}
	if _, err := service.ConfirmLogin(ctx, thiefPrincipal, login.Nonce, true); !errors.Is(err, ErrForbidden) {
		t.Fatalf("different user/device confirm err=%v want forbidden", err)
	}
	confirmed, err := service.ConfirmLogin(ctx, scannerPrincipal, login.Nonce, true)
	if err != nil || confirmed.Status != "CONFIRMED" {
		t.Fatalf("confirm login=%+v err=%v", confirmed, err)
	}
	beforeDevices := countQRDevices(t, ctx, pool, scanner)
	consumed, err := service.ConsumeLogin(ctx, login.Nonce)
	if err != nil {
		t.Fatalf("consume login: %v", err)
	}
	if consumed.Session.User.ID != scanner.String() || consumed.Session.Device.Platform != "WINDOWS" || consumed.Session.Tokens.AccessToken == "" || consumed.Session.Tokens.RefreshToken == "" {
		t.Fatalf("unexpected consumed session: %+v", consumed.Session)
	}
	if got := countQRDevices(t, ctx, pool, scanner); got != beforeDevices+1 {
		t.Fatalf("device count after consume=%d want=%d", got, beforeDevices+1)
	}
	if _, err := service.ConsumeLogin(ctx, login.Nonce); !errors.Is(err, ErrConsumed) {
		t.Fatalf("second consume err=%v want consumed", err)
	}
	if got := countQRDevices(t, ctx, pool, scanner); got != beforeDevices+1 {
		t.Fatalf("second consume created another device: %d", got)
	}

	rejected, err := service.CreateLogin(ctx, CreateLoginInput{Device: DeviceInput{Name: "Rejected Desktop", Platform: "WEB"}})
	if err != nil {
		t.Fatalf("create rejected login: %v", err)
	}
	if _, err := service.ScanLogin(ctx, scannerPrincipal, rejected.Nonce); err != nil {
		t.Fatalf("scan rejected flow: %v", err)
	}
	if state, err := service.ConfirmLogin(ctx, scannerPrincipal, rejected.Nonce, false); err != nil || state.Status != "REJECTED" {
		t.Fatalf("reject state=%+v err=%v", state, err)
	}
	if _, err := service.ConsumeLogin(ctx, rejected.Nonce); !errors.Is(err, ErrRejected) {
		t.Fatalf("consume rejected err=%v want rejected", err)
	}

	expiring, err := service.CreateLogin(ctx, CreateLoginInput{Device: DeviceInput{Name: "Expiring Desktop", Platform: "WINDOWS"}})
	if err != nil {
		t.Fatalf("create expiring login: %v", err)
	}
	now = now.Add(3 * time.Minute)
	if state, err := service.PollLogin(ctx, expiring.Nonce); err != nil || state.Status != "EXPIRED" {
		t.Fatalf("expired poll=%+v err=%v", state, err)
	}
	if _, err := service.ConsumeLogin(ctx, expiring.Nonce); !errors.Is(err, ErrExpired) {
		t.Fatalf("consume expired err=%v want expired", err)
	}
	now = now.Add(-3 * time.Minute)

	group, err := groupService.Create(ctx, ownerPrincipal, groups.CreateGroupInput{
		Name: "QR Group " + suffix, MemberIDs: []string{seed.String()},
	})
	if err != nil {
		t.Fatalf("create group: %v", err)
	}
	groupID := uuid.MustParse(group.ID)
	maxUses := 1
	invite, err := service.CreateGroupInvite(ctx, ownerPrincipal, groupID, CreateGroupInviteInput{MaxUses: &maxUses})
	if err != nil {
		t.Fatalf("create group qr invite: %v", err)
	}
	groupNonce := nonceFromPayload(t, invite.Payload)
	joined, recipients, err := service.RedeemGroupInvite(ctx, scannerPrincipal, groupNonce)
	if err != nil || joined.Group.ID != group.ID || joined.Group.MyRole != "MEMBER" {
		t.Fatalf("redeem group qr=%+v recipients=%v err=%v", joined, recipients, err)
	}
	if len(recipients) != 3 {
		t.Fatalf("group qr recipients=%d want 3", len(recipients))
	}
	var useCount int
	if err := pool.QueryRow(ctx, `SELECT use_count FROM group_qr_invites WHERE id=$1`, uuid.MustParse(invite.ID)).Scan(&useCount); err != nil || useCount != 1 {
		t.Fatalf("group qr useCount=%d err=%v", useCount, err)
	}
	if _, _, err := service.RedeemGroupInvite(ctx, thiefPrincipal, groupNonce); !errors.Is(err, ErrExpired) {
		t.Fatalf("max-use group qr err=%v want expired", err)
	}

	secondInvite, err := service.CreateGroupInvite(ctx, ownerPrincipal, groupID, CreateGroupInviteInput{})
	if err != nil {
		t.Fatalf("create revocable group qr: %v", err)
	}
	if err := service.RevokeGroupInvite(ctx, ownerPrincipal, uuid.MustParse(secondInvite.ID)); err != nil {
		t.Fatalf("revoke group qr: %v", err)
	}
	if _, _, err := service.RedeemGroupInvite(ctx, thiefPrincipal, nonceFromPayload(t, secondInvite.Payload)); !errors.Is(err, ErrExpired) {
		t.Fatalf("revoked group qr err=%v want expired", err)
	}

	blockedInvite, err := service.CreateGroupInvite(ctx, ownerPrincipal, groupID, CreateGroupInviteInput{})
	if err != nil {
		t.Fatalf("create blocked group qr: %v", err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO blocks(owner_user_id,blocked_user_id) VALUES($1,$2) ON CONFLICT DO NOTHING`, owner, thief); err != nil {
		t.Fatalf("block thief: %v", err)
	}
	if _, _, err := service.RedeemGroupInvite(ctx, thiefPrincipal, nonceFromPayload(t, blockedInvite.Payload)); !errors.Is(err, ErrForbidden) {
		t.Fatalf("blocked qr join err=%v want forbidden", err)
	}

	var auditCount int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM auth_audit_events WHERE user_id=$1 AND event_type='QR_LOGIN_SUCCEEDED'`, scanner).Scan(&auditCount); err != nil || auditCount != 1 {
		t.Fatalf("qr audit count=%d err=%v", auditCount, err)
	}
}

func insertQRUser(t *testing.T, ctx context.Context, pool *pgxpool.Pool, handle, displayName string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := pool.Exec(ctx, `
		INSERT INTO users(id,email_normalized,email_verified_at,handle_normalized,display_name,status,created_at,updated_at)
		VALUES($1,$2,now(),$3,$4,'ACTIVE',now(),now())
	`, id, fmt.Sprintf("%s@example.invalid", handle), handle, displayName); err != nil {
		t.Fatalf("insert qr user: %v", err)
	}
	return id
}

func insertQRDevice(t *testing.T, ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID, name, platform string) uuid.UUID {
	t.Helper()
	var id uuid.UUID
	if err := pool.QueryRow(ctx, `
		INSERT INTO devices(user_id,name,platform,app_version,created_at,last_seen_at)
		VALUES($1,$2,$3,'test',now(),now()) RETURNING id
	`, userID, name, platform).Scan(&id); err != nil {
		t.Fatalf("insert qr device: %v", err)
	}
	return id
}

func insertQRContactPair(t *testing.T, ctx context.Context, pool *pgxpool.Pool, a, b uuid.UUID) {
	t.Helper()
	if _, err := pool.Exec(ctx, `
		INSERT INTO contacts(owner_user_id,contact_user_id,remark,is_starred,created_at,updated_at)
		VALUES($1,$2,'',false,now(),now()),($2,$1,'',false,now(),now())
		ON CONFLICT(owner_user_id,contact_user_id) DO NOTHING
	`, a, b); err != nil {
		t.Fatalf("insert qr contacts: %v", err)
	}
}

func countQRDevices(t *testing.T, ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID) int {
	t.Helper()
	var count int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM devices WHERE user_id=$1`, userID).Scan(&count); err != nil {
		t.Fatalf("count qr devices: %v", err)
	}
	return count
}

func nonceFromPayload(t *testing.T, payload string) string {
	t.Helper()
	const marker = "nonce="
	index := strings.Index(payload, marker)
	if index < 0 {
		t.Fatalf("payload missing nonce: %s", payload)
	}
	raw := payload[index+len(marker):]
	if amp := strings.IndexByte(raw, '&'); amp >= 0 {
		raw = raw[:amp]
	}
	return strings.ReplaceAll(raw, "%3D", "=")
}

func urlQueryEscape(value string) string {
	replacer := strings.NewReplacer(":", "%3A", "/", "%2F")
	return replacer.Replace(value)
}
