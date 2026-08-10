package account

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/emailcode"
	"example.com/selfhosted-im/server/internal/auth/password"
	"example.com/selfhosted-im/server/internal/auth/registration"
	"example.com/selfhosted-im/server/internal/auth/session"
	"example.com/selfhosted-im/server/internal/platform/maildelivery"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestAccountLifecycleWithPostgresAndMailpit(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_AUTH_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_AUTH_TEST_DATABASE_URL is not set")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("ping postgres: %v", err)
	}

	suffix := strings.ToLower(fmt.Sprintf("%x", time.Now().UnixNano()))
	if len(suffix) > 12 {
		suffix = suffix[len(suffix)-12:]
	}
	email := "auth-" + suffix + "@example.test"
	newEmail := "auth-new-" + suffix + "@example.test"
	handle := "u" + suffix
	newHandle := "v" + suffix
	passwordValue := "correct horse battery staple 2026"

	defer func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM auth_login_attempts WHERE email_normalized IN ($1,$2)`, email, newEmail)
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM users WHERE email_normalized IN ($1,$2) OR handle_normalized IN ($3,$4)`, email, newEmail, handle, newHandle)
		_, _ = pool.Exec(cleanupCtx, `DELETE FROM email_codes WHERE email_normalized IN ($1,$2)`, email, newEmail)
	}()

	codec, err := emailcode.NewCodec([]byte(strings.Repeat("p", 32)))
	if err != nil {
		t.Fatal(err)
	}
	hasher, err := password.NewHasher(password.Params{
		MemoryKiB: 8 * 1024, Iterations: 1, Parallelism: 1, SaltLength: 16, KeyLength: 32,
	})
	if err != nil {
		t.Fatal(err)
	}
	sessions, err := session.NewManager(session.Config{Secret: strings.Repeat("s", 32)})
	if err != nil {
		t.Fatal(err)
	}
	smtpHost := strings.TrimSpace(os.Getenv("DD_AUTH_TEST_SMTP_HOST"))
	if smtpHost == "" {
		smtpHost = "127.0.0.1"
	}
	smtpPort := 11025
	if rawPort := strings.TrimSpace(os.Getenv("DD_AUTH_TEST_SMTP_PORT")); rawPort != "" {
		if parsed, parseErr := strconv.Atoi(rawPort); parseErr == nil && parsed > 0 && parsed <= 65535 {
			smtpPort = parsed
		}
	}
	smtpMailer, err := maildelivery.NewSMTPMailer(maildelivery.SMTPConfig{
		Host: smtpHost, Port: smtpPort, From: "noreply@dd.local", RequireTLS: false,
	})
	if err != nil {
		t.Fatal(err)
	}
	mailer := &capturingMailer{delegate: smtpMailer}
	service, err := NewService(Config{
		Pool: pool, Codec: codec, Hasher: hasher, Sessions: sessions, Mailer: mailer, RegistrationMode: "open",
	})
	if err != nil {
		t.Fatal(err)
	}

	if err := service.SendRegistrationCode(ctx, email, "127.0.0.1:45678"); err != nil {
		t.Fatalf("send registration code: %v", err)
	}
	code := mailer.Code()
	if len(code) != 6 {
		t.Fatalf("captured code = %q", code)
	}

	registered, err := service.Register(ctx, registration.RegisterInput{
		Email: email, Code: code, Password: passwordValue, Handle: handle, DisplayName: "Integration Alice",
		Device: registration.DeviceInput{Name: "DD Integration Windows", Platform: "windows", AppVersion: "0.5.0-test"},
	})
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	if registered.User.Email != email || registered.User.Handle != handle || registered.Device.Platform != "WINDOWS" {
		t.Fatalf("registered session = %#v", registered)
	}
	if registered.Tokens.AccessToken == "" || registered.Tokens.RefreshToken == "" {
		t.Fatal("registration did not issue tokens")
	}

	for table, query := range map[string]string{
		"users":          `SELECT count(*) FROM users WHERE id = $1`,
		"privacy":        `SELECT count(*) FROM user_privacy_settings WHERE user_id = $1`,
		"password":       `SELECT count(*) FROM auth_passwords WHERE user_id = $1`,
		"initial device": `SELECT count(*) FROM devices WHERE user_id = $1`,
		"refresh token":  `SELECT count(*) FROM refresh_tokens WHERE user_id = $1`,
	} {
		var count int
		if err := pool.QueryRow(ctx, query, registered.User.ID).Scan(&count); err != nil || count < 1 {
			t.Fatalf("%s count=%d err=%v", table, count, err)
		}
	}

	if _, err := service.Register(ctx, registration.RegisterInput{
		Email: email, Code: code, Password: passwordValue, Handle: handle + "x", DisplayName: "Replay",
		Device: registration.DeviceInput{Name: "Replay", Platform: "WEB"},
	}); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("reusing consumed verification code error = %v", err)
	}

	if _, err := service.Login(ctx, LoginInput{
		Email: email, Password: "definitely-wrong-password",
		Device: registration.DeviceInput{Name: "Wrong Login", Platform: "WEB"},
	}); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("wrong password error = %v", err)
	}

	loggedIn, err := service.Login(ctx, LoginInput{
		Email: email, Password: passwordValue,
		Device: registration.DeviceInput{Name: "DD Integration Web", Platform: "WEB", AppVersion: "0.5.0-test"},
	})
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	if loggedIn.Device.Platform != "WEB" {
		t.Fatalf("login device = %#v", loggedIn.Device)
	}

	rotated, err := service.Refresh(ctx, loggedIn.Tokens.RefreshToken)
	if err != nil {
		t.Fatalf("first refresh: %v", err)
	}
	if rotated.Tokens.RefreshToken == loggedIn.Tokens.RefreshToken {
		t.Fatal("refresh token was not rotated")
	}
	if _, err := service.Refresh(ctx, loggedIn.Tokens.RefreshToken); !errors.Is(err, ErrRefreshReuse) {
		t.Fatalf("old refresh replay error = %v", err)
	}
	if _, err := service.Refresh(ctx, rotated.Tokens.RefreshToken); !errors.Is(err, ErrInvalidRefreshToken) {
		t.Fatalf("rotated token after family revocation error = %v", err)
	}

	var activeInFamily int
	if err := pool.QueryRow(ctx, `
		SELECT count(*)
		FROM refresh_tokens
		WHERE user_id = $1 AND family_id = (
			SELECT family_id FROM refresh_tokens WHERE token_hash = $2 LIMIT 1
		) AND revoked_at IS NULL
	`, loggedIn.User.ID, mustRefreshHash(t, loggedIn.Tokens.RefreshToken)).Scan(&activeInFamily); err != nil {
		t.Fatalf("check revoked refresh family: %v", err)
	}
	if activeInFamily != 0 {
		t.Fatalf("active refresh tokens after replay = %d", activeInFamily)
	}

	principal, err := service.AuthenticateAccessToken(ctx, registered.Tokens.AccessToken)
	if err != nil {
		t.Fatalf("authenticate registered access token: %v", err)
	}
	me, err := service.GetMe(ctx, principal)
	if err != nil || me.Profile.DisplayName != "Integration Alice" {
		t.Fatalf("get me = %#v err=%v", me, err)
	}
	updated, err := service.UpdateMe(ctx, principal, UpdateMeInput{
		Handle:      newHandle,
		DisplayName: "Integration Alice Updated",
		Bio:         "P2 profile integration",
		Privacy: PrivacySettings{
			AllowEmailSearch: true, AllowStrangerMessages: true, ShowOnlineStatus: false,
			ReadReceiptsEnabled: false, NotificationPreviewEnabled: false,
		},
	})
	if err != nil || updated.Profile.DisplayName != "Integration Alice Updated" || updated.Profile.Handle != newHandle || !updated.Privacy.AllowEmailSearch {
		t.Fatalf("update me = %#v err=%v", updated, err)
	}
	devices, err := service.ListDevices(ctx, principal)
	if err != nil || len(devices) < 2 {
		t.Fatalf("devices = %#v err=%v", devices, err)
	}
	loginDeviceID, err := uuid.Parse(loggedIn.Device.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.RevokeDevice(ctx, principal, loginDeviceID); err != nil {
		t.Fatalf("revoke remote device: %v", err)
	}
	if _, err := service.AuthenticateAccessToken(ctx, loggedIn.Tokens.AccessToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("revoked device access token error = %v", err)
	}
	cleared, err := service.ClearRevokedDevices(ctx, principal)
	if err != nil || cleared < 1 {
		t.Fatalf("clear revoked device history count=%d err=%v", cleared, err)
	}
	visibleDevices, err := service.ListDevices(ctx, principal)
	if err != nil {
		t.Fatalf("list devices after cleanup: %v", err)
	}
	for _, device := range visibleDevices {
		if device.RevokedAt != nil {
			t.Fatalf("revoked device remained visible after cleanup: %#v", device)
		}
	}
	if clearedAgain, err := service.ClearRevokedDevices(ctx, principal); err != nil || clearedAgain != 0 {
		t.Fatalf("idempotent clear count=%d err=%v", clearedAgain, err)
	}
	var preservedDeviceCount int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM devices WHERE id=$1`, loginDeviceID).Scan(&preservedDeviceCount); err != nil || preservedDeviceCount != 1 {
		t.Fatalf("revoked audit device must be preserved count=%d err=%v", preservedDeviceCount, err)
	}

	if err := service.SendPasswordResetCode(ctx, email); err != nil {
		t.Fatalf("send password reset code: %v", err)
	}
	resetCode := mailer.Code()
	newPassword := "new correct horse battery staple 2026"
	if err := service.ResetPassword(ctx, ResetPasswordInput{Email: email, Code: resetCode, NewPassword: newPassword}); err != nil {
		t.Fatalf("reset password: %v", err)
	}
	if _, err := service.AuthenticateAccessToken(ctx, registered.Tokens.AccessToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("old access after password reset error = %v", err)
	}
	if _, err := service.Login(ctx, LoginInput{Email: email, Password: passwordValue, Device: registration.DeviceInput{Name: "Old Password", Platform: "WEB"}}); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("old password login error = %v", err)
	}
	newLogin, err := service.Login(ctx, LoginInput{Email: email, Password: newPassword, Device: registration.DeviceInput{Name: "New Password", Platform: "WEB"}})
	if err != nil || newLogin.Tokens.RefreshToken == "" {
		t.Fatalf("new password login = %#v err=%v", newLogin, err)
	}

	for i := 0; i < 8; i++ { // Two failures already happened above.
		_, _ = service.Login(ctx, LoginInput{Email: email, Password: "wrong-again", Device: registration.DeviceInput{Name: "Rate Test", Platform: "WEB"}})
	}
	if _, err := service.Login(ctx, LoginInput{Email: email, Password: newPassword, Device: registration.DeviceInput{Name: "Rate Limited", Platform: "WEB"}}); !errors.Is(err, ErrLoginRateLimited) {
		t.Fatalf("login rate limit error = %v", err)
	}

	newPrincipal, err := service.AuthenticateAccessToken(ctx, newLogin.Tokens.AccessToken)
	if err != nil {
		t.Fatalf("authenticate before email change: %v", err)
	}
	if err := service.SendEmailChangeCode(ctx, newPrincipal, newEmail); err != nil {
		t.Fatalf("send email change code: %v", err)
	}
	changed, err := service.ChangeEmail(ctx, newPrincipal, ChangeEmailInput{Email: newEmail, Code: mailer.Code()})
	if err != nil || changed.Profile.Email != newEmail || changed.Profile.Handle != newHandle {
		t.Fatalf("change email = %#v err=%v", changed, err)
	}
}

type capturingMailer struct {
	delegate Mailer
	mu       sync.Mutex
	code     string
}

func (mailer *capturingMailer) SendVerificationCode(ctx context.Context, to, purpose, code string) error {
	if err := mailer.delegate.SendVerificationCode(ctx, to, purpose, code); err != nil {
		return err
	}
	mailer.mu.Lock()
	mailer.code = code
	mailer.mu.Unlock()
	return nil
}

func (mailer *capturingMailer) Code() string {
	mailer.mu.Lock()
	defer mailer.mu.Unlock()
	return mailer.code
}

func mustRefreshHash(t *testing.T, raw string) []byte {
	t.Helper()
	hash, err := session.HashRefreshToken(raw)
	if err != nil {
		t.Fatal(err)
	}
	return hash
}
