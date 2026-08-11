package admin

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/password"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestAdminAuthGovernanceLifecycleWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_ADMIN_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_ADMIN_TEST_DATABASE_URL is not set")
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

	now := time.Date(2026, 8, 12, 7, 0, 0, 0, time.UTC)
	hasher, err := password.NewHasher(password.Params{MemoryKiB: 8 * 1024, Iterations: 1, Parallelism: 1, SaltLength: 16, KeyLength: 32})
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewService(Config{
		Pool: pool, Hasher: hasher, Secret: strings.Repeat("a", 32), Now: func() time.Time { return now },
		SessionTTL: 2 * time.Hour, IdleTTL: 10 * time.Minute, ChallengeTTL: 5 * time.Minute,
	})
	if err != nil {
		t.Fatal(err)
	}

	suffix := strings.ToLower(fmt.Sprintf("%x", time.Now().UnixNano()))
	if len(suffix) > 10 {
		suffix = suffix[len(suffix)-10:]
	}
	emails := []string{"super-" + suffix + "@example.test", "mod-" + suffix + "@example.test", "support-" + suffix + "@example.test", "rate-" + suffix + "@example.test"}
	passwordValue := "correct horse admin staple 2026"
	userIDs := []uuid.UUID{uuid.New(), uuid.New()}
	defer cleanupAdminIntegration(t, pool, emails, userIDs)

	if _, err := service.BootstrapAdmin(ctx, emails[0], passwordValue, RoleSuperAdmin); err != nil {
		t.Fatalf("bootstrap super admin: %v", err)
	}
	if _, err := service.BootstrapAdmin(ctx, emails[1], passwordValue, RoleModerator); err != nil {
		t.Fatalf("bootstrap moderator: %v", err)
	}
	if _, err := service.BootstrapAdmin(ctx, emails[2], passwordValue, RoleSupportReadOnly); err != nil {
		t.Fatalf("bootstrap support: %v", err)
	}
	if _, err := service.BootstrapAdmin(ctx, emails[3], passwordValue, RoleSupportReadOnly); err != nil {
		t.Fatalf("bootstrap rate-limit admin: %v", err)
	}

	client := ClientContext{RemoteAddress: "127.0.0.1:42000", UserAgent: "DD admin integration"}
	if _, err := service.Login(ctx, emails[0], "wrong-password", client); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("wrong password error=%v", err)
	}
	login, err := service.Login(ctx, emails[0], passwordValue, client)
	if err != nil {
		t.Fatalf("correct password login: %v", err)
	}
	if !login.MFARequired || !login.EnrollmentRequired || login.ChallengeToken == "" {
		t.Fatalf("initial login must require MFA enrollment: %#v", login)
	}
	enrollment, err := service.BeginMFAEnrollment(ctx, login.ChallengeToken)
	if err != nil {
		t.Fatalf("begin MFA enrollment: %v", err)
	}
	if enrollment.Secret == "" || !strings.HasPrefix(enrollment.OTPAuthURI, "otpauth://totp/") {
		t.Fatalf("invalid MFA enrollment: %#v", enrollment)
	}
	if _, _, err := service.VerifyMFAEnrollment(ctx, login.ChallengeToken, "000000", client); !errors.Is(err, ErrInvalidMFA) {
		t.Fatalf("invalid enrollment MFA error=%v", err)
	}
	code, err := totpAtCounter(enrollment.Secret, now.Unix()/totpPeriodSeconds)
	if err != nil {
		t.Fatal(err)
	}
	superIssued, recoveryCodes, err := service.VerifyMFAEnrollment(ctx, login.ChallengeToken, code, client)
	if err != nil {
		t.Fatalf("verify MFA enrollment: %v", err)
	}
	if len(recoveryCodes) != recoveryCodeCount || superIssued.Token == "" || superIssued.Admin.Role != RoleSuperAdmin {
		t.Fatalf("MFA enrollment session=%#v recovery=%d", superIssued, len(recoveryCodes))
	}
	if _, err := service.VerifyMFA(ctx, login.ChallengeToken, code, "", client); !errors.Is(err, ErrChallengeExpired) {
		t.Fatalf("consumed challenge reuse error=%v", err)
	}
	superPrincipal, _, err := service.AuthenticateSession(ctx, superIssued.Token)
	if err != nil {
		t.Fatalf("authenticate super session: %v", err)
	}

	recoveryLogin, err := service.Login(ctx, emails[0], passwordValue, client)
	if err != nil {
		t.Fatalf("recovery login challenge: %v", err)
	}
	recoveryIssued, err := service.VerifyMFA(ctx, recoveryLogin.ChallengeToken, "", recoveryCodes[0], client)
	if err != nil {
		t.Fatalf("recovery-code login: %v", err)
	}
	if _, _, err := service.AuthenticateSession(ctx, recoveryIssued.Token); err != nil {
		t.Fatalf("authenticate recovery-code session: %v", err)
	}
	reusedRecoveryLogin, err := service.Login(ctx, emails[0], passwordValue, client)
	if err != nil {
		t.Fatalf("reused recovery challenge: %v", err)
	}
	if _, err := service.VerifyMFA(ctx, reusedRecoveryLogin.ChallengeToken, "", recoveryCodes[0], client); !errors.Is(err, ErrInvalidMFA) {
		t.Fatalf("reused recovery code error=%v", err)
	}

	moderatorPrincipal := enrollAdminSession(t, ctx, service, emails[1], passwordValue, &now, client)
	supportPrincipal := enrollAdminSession(t, ctx, service, emails[2], passwordValue, &now, client)

	for index := 0; index < adminLoginFailureLimit; index++ {
		_, _ = service.Login(ctx, emails[3], "wrong-password", ClientContext{RemoteAddress: "127.0.0.2:43000", UserAgent: "rate-limit"})
	}
	if _, err := service.Login(ctx, emails[3], passwordValue, ClientContext{RemoteAddress: "127.0.0.2:43000", UserAgent: "rate-limit"}); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("admin login rate-limit error=%v", err)
	}

	for index, userID := range userIDs {
		handle := fmt.Sprintf("a%s%d", suffix, index)
		if len(handle) > 32 {
			handle = handle[:32]
		}
		_, err := pool.Exec(ctx, `
			INSERT INTO users(id,email_normalized,email_verified_at,handle_normalized,display_name,status,created_at,updated_at)
			VALUES($1,$2,$3,$4,$5,'ACTIVE',$3,$3)
		`, userID, fmt.Sprintf("report-%s-%d@example.test", suffix, index), now, handle, fmt.Sprintf("Report User %d", index))
		if err != nil {
			t.Fatalf("seed report user: %v", err)
		}
	}

	report, err := service.CreateReport(ctx, userIDs[0], CreateReportInput{TargetUserID: userIDs[1].String(), Category: ReportCategoryScam, Reason: "Suspicious payment solicitation"})
	if err != nil {
		t.Fatalf("create report: %v", err)
	}
	if report.Status != ReportStatusPending {
		t.Fatalf("created report status=%s", report.Status)
	}
	if _, err := service.CreateReport(ctx, userIDs[0], CreateReportInput{TargetUserID: userIDs[1].String(), Category: ReportCategorySpam, Reason: "Duplicate open report"}); !errors.Is(err, ErrConflict) {
		t.Fatalf("duplicate open report error=%v", err)
	}
	reportID := uuid.MustParse(report.ID)
	inReview, err := service.UpdateReport(ctx, moderatorPrincipal, reportID, UpdateReportInput{Status: ReportStatusInReview, Reason: "Moderator accepted triage"}, client)
	if err != nil || inReview.Status != ReportStatusInReview {
		t.Fatalf("moderator triage report=%#v err=%v", inReview, err)
	}
	if _, err := service.UpdateReport(ctx, supportPrincipal, reportID, UpdateReportInput{Status: ReportStatusResolved, Reason: "Support cannot resolve"}, client); !errors.Is(err, ErrForbidden) {
		t.Fatalf("read-only report mutation error=%v", err)
	}
	resolved, err := service.UpdateReport(ctx, moderatorPrincipal, reportID, UpdateReportInput{Status: ReportStatusResolved, Reason: "Evidence reviewed"}, client)
	if err != nil || resolved.Status != ReportStatusResolved || resolved.ResolvedAt == nil {
		t.Fatalf("resolve report=%#v err=%v", resolved, err)
	}

	if _, _, err := service.ModerateUser(ctx, moderatorPrincipal, userIDs[1], "SUSPEND", "Moderator cannot suspend accounts", client); !errors.Is(err, ErrForbidden) {
		t.Fatalf("moderator privilege escalation error=%v", err)
	}
	suspended, suspension, err := service.ModerateUser(ctx, superPrincipal, userIDs[1], "SUSPEND", "Confirmed abuse investigation", client)
	if err != nil || suspended.Status != "SUSPENDED" || suspension.NewStatus != "SUSPENDED" {
		t.Fatalf("suspend lifecycle user=%#v action=%#v err=%v", suspended, suspension, err)
	}
	unsuspended, _, err := service.ModerateUser(ctx, superPrincipal, userIDs[1], "UNSUSPEND", "Investigation cleared account", client)
	if err != nil || unsuspended.Status != "ACTIVE" {
		t.Fatalf("unsuspend lifecycle user=%#v err=%v", unsuspended, err)
	}

	audit, err := service.ListAuditEvents(ctx, superPrincipal, 100)
	if err != nil {
		t.Fatalf("list audit: %v", err)
	}
	if !containsAuditAction(audit, "REPORT_STATUS_CHANGED") || !containsAuditAction(audit, "REPORT_STATUS_CHANGE_DENIED") ||
		!containsAuditAction(audit, "USER_MODERATION_DENIED") || !containsAuditAction(audit, "USER_SUSPEND") || !containsAuditAction(audit, "USER_UNSUSPEND") {
		t.Fatalf("audit persistence missing required actions: %#v", audit)
	}
	if _, err := service.ListAuditEvents(ctx, moderatorPrincipal, 10); !errors.Is(err, ErrForbidden) {
		t.Fatalf("moderator audit access error=%v", err)
	}

	now = now.Add(31 * time.Second)
	secondLogin, err := service.Login(ctx, emails[0], passwordValue, client)
	if err != nil || secondLogin.EnrollmentRequired {
		t.Fatalf("second login=%#v err=%v", secondLogin, err)
	}
	secondCode, err := totpAtCounter(enrollment.Secret, now.Unix()/totpPeriodSeconds)
	if err != nil {
		t.Fatal(err)
	}
	secondIssued, err := service.VerifyMFA(ctx, secondLogin.ChallengeToken, secondCode, "", client)
	if err != nil {
		t.Fatalf("second MFA session: %v", err)
	}
	secondPrincipal, _, err := service.AuthenticateSession(ctx, secondIssued.Token)
	if err != nil {
		t.Fatalf("authenticate second session: %v", err)
	}
	if err := service.RevokeSession(ctx, secondPrincipal, secondPrincipal.SessionID, "TEST_REVOKE", client); err != nil {
		t.Fatalf("revoke session: %v", err)
	}
	if _, _, err := service.AuthenticateSession(ctx, secondIssued.Token); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("revoked session auth error=%v", err)
	}

	now = now.Add(31 * time.Second)
	expiryLogin, err := service.Login(ctx, emails[2], passwordValue, client)
	if err != nil {
		t.Fatalf("expiry login: %v", err)
	}
	var supportSecret []byte
	if err := pool.QueryRow(ctx, `SELECT totp_secret_ciphertext FROM admin_accounts WHERE email_normalized=$1`, emails[2]).Scan(&supportSecret); err != nil {
		t.Fatal(err)
	}
	plainSupportSecret, err := service.box.decrypt(supportSecret)
	if err != nil {
		t.Fatal(err)
	}
	expiryCode, err := totpAtCounter(string(plainSupportSecret), now.Unix()/totpPeriodSeconds)
	if err != nil {
		t.Fatal(err)
	}
	expiryIssued, err := service.VerifyMFA(ctx, expiryLogin.ChallengeToken, expiryCode, "", client)
	if err != nil {
		t.Fatalf("expiry MFA verify: %v", err)
	}
	now = now.Add(11 * time.Minute)
	if _, _, err := service.AuthenticateSession(ctx, expiryIssued.Token); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("idle-expired session auth error=%v", err)
	}
}

func enrollAdminSession(t *testing.T, ctx context.Context, service *Service, email, passwordValue string, now *time.Time, client ClientContext) Principal {
	t.Helper()
	login, err := service.Login(ctx, email, passwordValue, client)
	if err != nil {
		t.Fatalf("login %s: %v", email, err)
	}
	enrollment, err := service.BeginMFAEnrollment(ctx, login.ChallengeToken)
	if err != nil {
		t.Fatalf("enroll %s: %v", email, err)
	}
	code, err := totpAtCounter(enrollment.Secret, now.UTC().Unix()/totpPeriodSeconds)
	if err != nil {
		t.Fatal(err)
	}
	issued, _, err := service.VerifyMFAEnrollment(ctx, login.ChallengeToken, code, client)
	if err != nil {
		t.Fatalf("verify enrollment %s: %v", email, err)
	}
	principal, _, err := service.AuthenticateSession(ctx, issued.Token)
	if err != nil {
		t.Fatalf("authenticate %s: %v", email, err)
	}
	return principal
}

func containsAuditAction(items []AuditEvent, action string) bool {
	for _, item := range items {
		if item.Action == action {
			return true
		}
	}
	return false
}

func cleanupAdminIntegration(t *testing.T, pool *pgxpool.Pool, emails []string, userIDs []uuid.UUID) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, _ = pool.Exec(ctx, `DELETE FROM user_reports WHERE reporter_user_id=ANY($1::uuid[]) OR target_user_id=ANY($1::uuid[])`, userIDs)
	_, _ = pool.Exec(ctx, `DELETE FROM user_moderation_actions WHERE target_user_id=ANY($1::uuid[])`, userIDs)
	_, _ = pool.Exec(ctx, `DELETE FROM users WHERE id=ANY($1::uuid[])`, userIDs)
	_, _ = pool.Exec(ctx, `DELETE FROM admin_login_failures WHERE email_normalized=ANY($1::text[])`, emails)
	_, _ = pool.Exec(ctx, `DELETE FROM admin_accounts WHERE email_normalized=ANY($1::text[])`, emails)
}
